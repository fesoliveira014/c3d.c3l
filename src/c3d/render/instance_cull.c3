module c3d::render;

import c3d;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

<*
 Per-frame cull memory when RendererDesc.instance_cull_bytes is 0.
*>
const usz INSTANCE_CULL_ARENA_BYTES = 16 << 20; // per slot on the device; instances x culling passes; 100k: 6 x 400 KB culled, 1.45 MB sorted

const usz CULL_ARGS_STRIDE @private = 32; // one indirect command at STREAM_ALIGNMENT
const usz CULL_COUNTER_BYTES @private = 64; // one batch counter and six selected/visible LOD counters, aligned for copies
$assert scene::MAX_LOD_CHOICES == shader::LOD_LEVEL_COUNT;

struct CullArena @private {
    gpu::GpuAllocation allocation;
    gpu::GpuSpan       span;
    gpu::GpuAddress    address;
    usz                head;
    usz                capacity;
}

struct CullReadback @private {
    gpu::MappedGpuSpan mapped;
    uint               tested;
    bool               pending;
    uint               lod_tested;
    uint               lod_fallbacks;
    ulong              frame_index;
}

struct BatchAddresses @private {
    gpu::GpuAddress skin;
    gpu::GpuAddress morph;
    gpu::GpuAddress instance_data;
    gpu::GpuAddress instance_indices;
}

struct CullItem @private {
    MeshCandidate*  candidate;
    GpuGeometry*    geometry;
    gpu::GpuAddress records;
    Frustum*        frustum;
    CullRange*      range;
    Aabb            bound;
    bool            bounded;
    bool            sorted;
    Vec4            depth_axis;
    gpu::GpuAddress args_address;
    gpu::GpuAddress keys_address;
    gpu::GpuAddress effects;
    gpu::GpuAddress lod_count;
    bool main_view;
    bool lod_reuse;
}

<*
 CPU twin of the cull shader's box test.
 @param [&in] frustum : "Normalized inward-facing planes."
 @param local_bounds : "Instance-local bound."
 @param model : "Instance world matrix."
 @param margin : "World distance a corner may lie outside a plane; the sway amplitude."
*>
fn bool instance_visible(
    Frustum* frustum,
    Aabb local_bounds,
    Mat4 model,
    float margin = 0,
) {
    Vec3[8] corners;
    foreach (uint corner, &world : corners) {
        Vec3 local = {
            corner & 1 ? local_bounds.max.x : local_bounds.min.x,
            corner & 2 ? local_bounds.max.y : local_bounds.min.y,
            corner & 4 ? local_bounds.max.z : local_bounds.min.z,
        };
        *world = maths::transform_point(model, local);
    }
    foreach (&plane : frustum.planes[:frustum.plane_count]) {
        bool outside = true;
        foreach (world : corners) {
            if (plane.normal.dot(world) + plane.d >= -margin) {
                outside = false;
                break;
            }
        }
        if (outside) return false;
    }
    return true;
}

fn Aabb? cull_bound(MeshCandidate* candidate, GpuGeometry* geometry) @private {
    if (candidate.lod) return candidate.lod.state.object_bounds;
    if (candidate.billboards) return candidate.world_bounds;
    if (candidate.crowd) return candidate.crowd.pose_bounds;
    if (candidate.batch.has_bounds_override) return NO_INSTANCE_BOUND~;
    return geometry.bounds;
}

fn void write_cull_planes(InstanceCullRoot* root, Frustum* frustum) @private {
    foreach (index, &plane : root.planes) {
        if (index >= frustum.plane_count) {
            *plane = { 0, 0, 0, 1 };
            continue;
        }
        Plane source = frustum.planes[index];
        *plane = { source.normal.x, source.normal.y, source.normal.z, source.d };
    }
}

fn usz? arena_place(CullArena* arena, usz bytes) @private {
    usz offset = align_up(arena.head, STREAM_ALIGNMENT);
    if (offset + bytes > arena.capacity) return c3d::CAPACITY_EXCEEDED~;
    arena.head = offset + bytes;
    return offset;
}

fn uint instance_offset(CullRange* range) @private => range.culled || range.indexed ? 0 : range.first;

fn gpu::GpuAddress offset_by_instances(gpu::GpuAddress base, uint instances, usz stride) @private {
    if (base == (gpu::GpuAddress)0) return base;
    return (gpu::GpuAddress)((ulong)base + (ulong)instances * stride);
}

fn BatchAddresses batch_addresses(
    MeshCandidate* candidate,
    CullRange* range,
    gpu::GpuAddress skin,
    gpu::GpuAddress morph,
    gpu::GpuAddress records,
) @private {
    uint offset = instance_offset(range);
    BatchAddresses addresses = {
        .skin             = skin,
        .morph            = morph,
        .instance_indices = range.culled || range.indexed ? range.visible : (gpu::GpuAddress)0,
    };
    if (candidate.batch || candidate.lod) addresses.instance_data = offset_by_instances(records, offset, InstanceGpu::size);
    if (candidate.billboards) addresses.instance_data = offset_by_instances(records, offset, BillboardGpu::size);
    if (candidate.crowd) {
        addresses.skin = offset_by_instances(skin, offset, (usz)candidate.crowd.joint_count * Mat4f::size);
        addresses.morph = offset_by_instances(morph, offset, MorphWeightsGpu::size);
    }
    return addresses;
}

fn void? acquire_instance_culling(Renderer* renderer) @private {
    if (renderer.cull_arenas[0].allocation.is_valid()) return;
    defer catch free_instance_culling(renderer);
    foreach (&arena : renderer.cull_arenas) {
        gpu::AllocationDesc arena_desc = {
            .size         = renderer.instance_cull_bytes,
            .alignment    = STREAM_ALIGNMENT,
            .memory_class = gpu::MemoryClass.GPU_PRIVATE,
            .access       = { .graphics },
            .debug_name   = "instance_cull",
        };
        arena.allocation = gpu::allocate_memory(&renderer.device, &arena_desc)!;
        arena.span = gpu::get_allocation_span(&renderer.device, arena.allocation)!;
        arena.address = gpu::get_span_address(&renderer.device, arena.span)!;
        arena.capacity = renderer.instance_cull_bytes;
        arena.head = CULL_COUNTER_BYTES;
    }
    foreach (&readback : renderer.cull_readbacks) {
        gpu::AllocationDesc readback_desc = {
            .size         = CULL_COUNTER_BYTES,
            .alignment    = STREAM_ALIGNMENT,
            .memory_class = gpu::MemoryClass.CPU_READ,
            .access       = { .graphics },
            .debug_name   = "instance_cull_readback",
        };
        readback.mapped = gpu::allocate_mapped_memory(&renderer.device, &readback_desc)!;
    }
    acquire_environment_pipeline(renderer, &renderer.instance_cull_pipeline, INSTANCE_CULL)!;
}

fn void reset_instance_culling(Renderer* renderer, uint slot_index) @private {
    renderer.cull_arenas[slot_index].head = CULL_COUNTER_BYTES;
    renderer.cull_counter_cleared = false;
    renderer.cull_tested = 0;
    renderer.cull_lod_tested = 0;
    renderer.cull_lod_fallbacks = 0;
}

fn CullItem[] batch_cull_items(
    AssetStore* assets,
    DrawItem[][] groups,
    Frustum* frustum,
    Vec4 depth_axis,
) @private {
    usz count;
    foreach (group : groups) foreach (&item : group) {
        if (candidate_instanced(item.candidate)) count++;
    }
    CullItem[] culls = alloc::new_array(tmem, CullItem, (sz)count);
    usz filled;
    foreach (group : groups) foreach (&item : group) {
        if (!candidate_instanced(item.candidate)) continue;
        culls[filled++] = {
            .candidate  = item.candidate,
            .geometry   = item.geometry,
            .records    = item.instance_data,
            .frustum    = frustum,
            .range      = &item.range,
            .sorted     = !item.candidate.impostor && assets.material(item.material.asset).data.common.alpha_mode == AlphaMode.BLEND,
            .depth_axis = depth_axis,
            .effects    = item.effects,
            .main_view = true,
        };
    }
    return culls;
}

fn CullItem[] shadow_cull_items(ShadowDraw[] draws, CullRange[] ranges, Frustum* frustum) @private {
    usz count;
    foreach (&draw : draws) {
        if (candidate_instanced(draw.candidate)) count++;
    }
    CullItem[] culls = alloc::new_array(tmem, CullItem, (sz)count);
    usz filled;
    foreach (index, &draw : draws) {
        if (!candidate_instanced(draw.candidate)) continue;
        culls[filled++] = {
            .candidate = draw.candidate,
            .geometry  = draw.geometry,
            .records   = draw.instance_data,
            .frustum   = frustum,
            .range     = &ranges[index],
            .effects   = draw.effects,
        };
    }
    return culls;
}

fn void? prepare_cull_stage(Renderer* renderer, CullItem[] items, bool culling) @private {
    uint slot_index = (uint)(renderer.frame_index % FRAMES_IN_FLIGHT);
    uint eligible;
    foreach (&item : items) {
        if (item.candidate.lod) {
            prepare_lod_cull(renderer, item, culling)!;
            continue;
        }
        Aabb? bound = cull_bound(item.candidate, item.geometry);
        item.bounded = culling && @ok(bound);
        item.bound = bound ?? item.geometry.bounds;
        if (item.bounded || item.sorted) eligible++;
    }
    CullArena* arena = &renderer.cull_arenas[slot_index];
    usz? args_offset = c3d::CAPACITY_EXCEEDED~;
    gpu::MappedGpuSpan staging;
    if (eligible) {
        acquire_instance_culling(renderer)!;
        args_offset = arena_place(arena, eligible * CULL_ARGS_STRIDE);
        if (try args_offset) {
            Frame* slot = &renderer.frames[slot_index];
            staging = slot.upload.take(&renderer.device, eligible * CULL_ARGS_STRIDE, STREAM_ALIGNMENT)!;
        }
    }
    uint args_index;
    uint culled;
    uint sorted;
    foreach (&item : items) {
        if (item.candidate.lod) continue;
        if (item.bounded || item.sorted) {
            uint slot = args_index++;
            if (try block = args_offset) {
                usz? list_offset = item.sorted
                  ? arena_place_sorted(arena, item.candidate.instance_count)
                  : arena_place(arena, (usz)item.candidate.instance_count * uint::size);
                if (try visible_offset = list_offset) {
                    usz args_at = block + slot * CULL_ARGS_STRIDE;
                    usz bytes = indirect_args_bytes(&item.geometry.layout);
                    char[] staged_args = staging.bytes[slot * CULL_ARGS_STRIDE:CULL_ARGS_STRIDE];
                    write_indirect_args(staged_args, &item.geometry.layout, 0);
                    *item.range = {
                        .args    = arena.span.checked_subspan(args_at, bytes)!,
                        .count   = item.candidate.instance_count,
                        .first   = item.candidate.instance_first,
                        .visible = (gpu::GpuAddress)((ulong)arena.address + visible_offset),
                        .culled  = true,
                    };
                    item.args_address = (gpu::GpuAddress)((ulong)arena.address + args_at);
                    if (item.sorted) {
                        usz keys_at = visible_offset + sorted_list_bytes(item.candidate.instance_count);
                        item.keys_address = (gpu::GpuAddress)((ulong)arena.address + keys_at);
                        sorted++;
                    }
                    culled++;
                    continue;
                }
            }
            if (item.sorted) {
                renderer.stats.sort_overflows++;
            } else {
                renderer.stats.cull_overflows++;
            }
        }
        *item.range = prepare_cull_range(renderer, item.candidate, item.geometry)!;
    }
    if (!culled) return;
    if (sorted) {
        acquire_compute_pipeline(
            renderer:   renderer,
            pipeline:   &renderer.instance_sort_pipeline,
            shader:     INSTANCE_SORT,
            debug_name: "instance_sort",
        )!;
    }
    clear_cull_counters(renderer)!;
    renderer.pending_copies.push({
        .src = staging.span,
        .dst = arena.span.checked_subspan(args_offset!!, eligible * CULL_ARGS_STRIDE)!,
    });
}

fn void? record_instance_cull(Renderer* renderer, CullItem[] items) @private {
    uint culled;
    bool sorted;
    bool finalize;
    foreach (&item : items) {
        if (item.range.culled) culled++;
        if (item.keys_address != (gpu::GpuAddress)0) sorted = true;
        finalize |= item.lod_count != (gpu::GpuAddress)0;
    }
    if (!culled) return;
    uint slot_index = (uint)(renderer.frame_index % FRAMES_IN_FLIGHT);
    Frame* slot = &renderer.frames[slot_index];
    gpu::GpuAddress counter = renderer.cull_arenas[slot_index].address;
    Frustum open_frustum;
    @profile_pass(renderer, Pass.INSTANCE_CULL) {
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.instance_cull_pipeline)!;
        foreach (&item : items) {
            CullRange* range = item.range;
            if (!range.culled || item.lod_reuse || item.lod_count != (gpu::GpuAddress)0) continue;
            gpu::MappedGpuSpan root_span = slot.upload.take(
                &renderer.device,
                InstanceCullRoot::size,
                STREAM_ALIGNMENT,
            )!;
            InstanceCullRoot* root = (InstanceCullRoot*)root_span.bytes.ptr;
            *root = {
                .instances        = item.records,
                .bounds_instances = resolve_crowd_bounds(renderer, item.candidate)!,
                .visible          = range.visible,
                .args             = item.args_address,
                .counter          = counter,
                .bounds_min       = { item.bound.min.x, item.bound.min.y, item.bound.min.z, 0 },
                .bounds_max       = { item.bound.max.x, item.bound.max.y, item.bound.max.z, 0 },
                .first            = range.first,
                .count            = range.count,
                .keys             = item.keys_address,
                .instance_effects = item.effects,
                .kind             = item.candidate.billboards
                    ? shader::INSTANCE_KIND_BILLBOARD : shader::INSTANCE_KIND_MESH,
                .depth_axis       = item.depth_axis,
            };
            if (item.candidate.lod) {
                root.lod_mode = shader::LOD_CULL;
                root.lod_current = item.candidate.lod.current;
                root.lod_metadata = item.candidate.lod.instances.lod_metadata;
                root.lod_level = item.candidate.lod_level;
                root.lod_parity = item.candidate.mirrored ? 1 : 0;

                if (item.candidate.animated_lod) {
                    root.lod_animated = 1;
                    root.bounds_instances = resolve_animated_lod_parts(renderer, item.candidate)!;
                }

                bool count_object = !item.candidate.animated_lod || item.candidate.lod_part
                  == item.candidate.lod.state.desc.levels[item.candidate.lod_level].first_part;
                root.lod_count_visible = item.main_view && count_object ? 1 : 0;
            }
            write_cull_planes(root, item.bounded ? item.frustum : &open_frustum);
            uint groups = (range.count + shader::INSTANCE_CULL_GROUP_SIZE - 1) / shader::INSTANCE_CULL_GROUP_SIZE;
            gpu::cmd_dispatch(&renderer.commands, root_span.address, { groups, 1, 1 })!;
            renderer.stats.cull_dispatches++;
            renderer.cull_tested += range.count;
        }
        if (finalize) {
            gpu::Barrier counted = { .before = { .compute }, .after = { .compute } };
            gpu::cmd_barrier(&renderer.commands, &counted)!;
        }
        foreach (&item : items) {
            if (item.lod_count == (gpu::GpuAddress)0) continue;
            gpu::MappedGpuSpan block = slot.upload.take(&renderer.device, InstanceCullRoot::size, STREAM_ALIGNMENT)!;
            *(InstanceCullRoot*)block.bytes.ptr = {
                .lod_mode = shader::LOD_FINALIZE,
                .lod_source_args = item.lod_count,
                .args = item.args_address,
            };
            gpu::cmd_dispatch(&renderer.commands, block.address, { 1, 1, 1 })!;
            renderer.stats.cull_dispatches++;
        }
        gpu::Barrier culled_stage = { .before = { .compute }, .after = { .vertex_shader, .indirect } };
        culled_stage.after.compute = sorted;
        gpu::cmd_barrier(&renderer.commands, &culled_stage)!;
    }!;
}

fn void? record_cull_readback(Renderer* renderer, uint slot_index, ulong frame_index) @private {
    if (!renderer.cull_counter_cleared) return;
    CullReadback* readback = &renderer.cull_readbacks[slot_index];
    gpu::Barrier counted = { .before = { .compute }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &counted)!;
    gpu::BufferCopyDesc copy = {
        .src = renderer.cull_arenas[slot_index].span.checked_subspan(0, CULL_COUNTER_BYTES)!,
        .dst = readback.mapped.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier completed = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &completed)!;
    readback.tested = renderer.cull_tested;
    readback.lod_tested = renderer.cull_lod_tested;
    readback.lod_fallbacks = renderer.cull_lod_fallbacks;
    readback.frame_index = frame_index;
    readback.pending = true;
}

fn void? read_cull_stats(Renderer* renderer, uint slot_index) @private {
    CullReadback* readback = &renderer.cull_readbacks[slot_index];
    if (!readback.pending) return;
    gpu::invalidate_mapped_span(&renderer.device, readback.mapped.span)!;
    pair_cull_stats(readback, &renderer.stats);
}

fn void pair_cull_stats(CullReadback* readback, Stats* stats) @private {
    stats.instances_visible = *(uint*)readback.mapped.bytes.ptr;
    stats.instances_tested = readback.tested;
    stats.lod_instances_tested = readback.lod_tested;
    stats.lod_fallbacks = readback.lod_fallbacks;
    stats.lod_frame_index = readback.frame_index;
    stats.lod_counts_valid = true;
    foreach (index, &count : stats.lod_visible) *count = ((uint*)readback.mapped.bytes.ptr)[1 + index];
    foreach (index, &count : stats.lod_selected) *count = ((uint*)readback.mapped.bytes.ptr)[1 + scene::MAX_LOD_CHOICES + index];
    readback.pending = false;
}

fn void free_instance_culling(Renderer* renderer) @private {
    if (renderer.instance_cull_pipeline.is_valid()) {
        (void)gpu::destroy_pipeline(&renderer.device, renderer.instance_cull_pipeline);
        renderer.instance_cull_pipeline = {};
    }
    if (renderer.instance_sort_pipeline.is_valid()) {
        (void)gpu::destroy_pipeline(&renderer.device, renderer.instance_sort_pipeline);
        renderer.instance_sort_pipeline = {};
    }
    foreach (&arena : renderer.cull_arenas) {
        if (arena.allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &arena.allocation);
        *arena = {};
    }
    foreach (&readback : renderer.cull_readbacks) {
        gpu::GpuAllocation allocation = readback.mapped.span.allocation();
        if (allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &allocation);
        *readback = {};
    }
}
