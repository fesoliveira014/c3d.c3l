module c3d::render;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

struct LodCullBin @private {
    Frustum* frustum;
    uint level;
    bool mirrored;
    uint representation;
    gpu::GpuAddress visible;
    gpu::GpuAddress args;
    gpu::GpuAddress[] parts;
}

fn bool lod_level_blended(AssetStore* assets, LodGroupState* state, uint index) @private {
    if (index == state.desc.levels.len) return false;
    LodLevel level = state.desc.levels[index];
    foreach (part : state.desc.parts[level.first_part:level.part_count]) {
        if (assets.material(part.material).data.common.alpha_mode == AlphaMode.BLEND) return true;
    }
    return false;
}

fn void? reserve_lod_bins(Renderer* renderer, LodSelection* selection) @private {
    acquire_instance_culling(renderer)!;
    CullArena* shared = &renderer.cull_arenas[renderer.frame_index % FRAMES_IN_FLIGHT];
    CullArena reserved = *shared;
    LodGroupState* state = selection.state;
    uint passes = 1 + renderer.max_shadow_layers;
    uint choices = (uint)state.desc.levels.len + (selection.impostor ? 1 : 0);
    for (uint index = 0; index < choices; index++) {
        LodLevel level = selected_lod_level(selection, index);
        uint representations = state.animated ? level.part_count : 1;
        for (uint part = 0; part < representations; part++) {
            uint split = state.animated ? selection.part_unmirrored[level.first_part + part]
              : selection.instances.lod_unmirrored_count;
            for (uint pass = 0; pass < passes; pass++) {
                for (uint parity = 0; parity < 2; parity++) {
                    uint count = parity ? state.count - split : split;
                    if (!count) continue;

                    arena_place(&reserved, (usz)(state.animated ? 1 : level.part_count) * CULL_ARGS_STRIDE)!;
                    if (pass == 0 && lod_level_blended(renderer.assets, state, index)) {
                        if (count > MAX_SORTED_INSTANCES) return c3d::CAPACITY_EXCEEDED~;

                        arena_place(&reserved, align_up(
                            sorted_list_bytes(count) + (usz)sort_capacity(count) * ulong::size,
                            STREAM_ALIGNMENT,
                        ))!;
                    } else {
                        arena_place(&reserved, align_up((usz)count * uint::size, STREAM_ALIGNMENT))!;
                    }
                }
            }
        }
    }
    selection.arena = *shared;
    selection.arena.capacity = reserved.head;
    shared.head = reserved.head;
    usz representations = state.animated ? state.desc.parts.len : choices;
    selection.bins = alloc::new_array(tmem, LodCullBin, 2 * (sz)passes * (sz)representations);
}

fn void? prepare_lod_instances(Renderer* renderer, LodSelection* selection) @private {
    if (selection.state.animated) (void)selection.state.local_bounds(renderer.assets);

    resolve_lod_instances(renderer, selection)!;
    if (selection.state.animated) {
        selection.part_unmirrored = alloc::new_array(tmem, uint, selection.state.desc.parts.len);

        foreach (uint part, &split : selection.part_unmirrored) {
            MeshCandidate candidate = {
                .node = selection.node,
                .lod = selection,
                .lod_part = part,
                .scene_identity = selection.scene_identity,
            };
            (void)bind_animated_lod_candidate(selection, &candidate);

            for (uint source = 0; source < selection.state.count; source++) {
                Mat4 local = selection.state.transforms[source].to_mat4()
                  .mul(animated_lod_part_local(&candidate, source));
                if (local.determinant() >= 0) (*split)++;
            }
        }
    }

    if (catch excuse = reserve_lod_bins(renderer, selection)) {
        if (excuse != c3d::CAPACITY_EXCEEDED) return excuse~;
        selection.fallback = true;
        selection.reject_history = true;
        renderer.cull_lod_fallbacks++;
    }
    LodGroupState* state = selection.state;
    LodHistoryEntry* history = selection.history;
    LodHistoryValue previous = history.committed;
    selection.history_valid = previous.valid && previous.scene == selection.scene_identity
      && c3d::same_id(previous.owner, selection.node.id) && previous.identity == state.identity
      && previous.bounds_revision == state.bounds_revision && history.instance_epoch == state.instance_epoch
      && previous.descriptor_revision == state.descriptor_revision && previous.impostor == selection.impostor;
    history.pending = {
        .scene = selection.scene_identity,
        .owner = selection.node.id,
        .identity = state.identity,
        .bounds_revision = state.bounds_revision,
        .descriptor_revision = state.descriptor_revision,
        .impostor = selection.impostor,
        .valid = !selection.fallback,
    };
    history.pending_epoch = state.instance_epoch;
    history.last_seen = renderer.frame_index;
    history.dirty = true;
    renderer.cull_lod_tested += state.count;
    if (selection.fallback) return;
    if (history.capacity < state.transforms.len) {
        usz capacity = state.transforms.len;
        gpu::AllocationDesc desc = {
            .size = 2 * capacity * LodHistoryGpu::size,
            .alignment = STREAM_ALIGNMENT,
            .memory_class = gpu::MemoryClass.GPU_PRIVATE,
            .access = { .graphics },
            .debug_name = "lod_history",
        };
        gpu::GpuAllocation allocation = gpu::allocate_memory(&renderer.device, &desc)!;
        defer catch (void)gpu::free_allocation(&renderer.device, &allocation);
        gpu::GpuAddress address = gpu::get_span_address(&renderer.device, gpu::get_allocation_span(&renderer.device, allocation)!)!;
        if (history.allocation.is_valid()) renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = history.allocation });
        history.allocation = allocation;
        history.address = address;
        history.capacity = (uint)capacity;
        selection.history_valid = false;
    }
    selection.current = offset_by_instances(history.address, (history.committed_slot ^ 1) * history.capacity, LodHistoryGpu::size);
    selection.previous = offset_by_instances(history.address, history.committed_slot * history.capacity, LodHistoryGpu::size);
}

fn void? clear_cull_counters(Renderer* renderer) @private {
    if (renderer.cull_counter_cleared) return;
    CullArena* arena = &renderer.cull_arenas[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::cmd_fill_buffer(&renderer.commands, arena.span.checked_subspan(0, CULL_COUNTER_BYTES)!, 0)!;
    renderer.cull_counter_cleared = true;
}

fn void? record_lod_selection(Renderer* renderer, LodSelection[] selections) @private {
    bool present;
    foreach (selection : selections) present |= selection.instances != null;
    if (!present) return;
    @profile_pass(renderer, Pass.INSTANCE_CULL) {
        bool recorded;
        foreach (&selection : selections) {
            if (!selection.instances) continue;
            clear_cull_counters(renderer)!;
            if (!recorded) {
                gpu::Barrier reused = { .before = { .transfer, .compute, .vertex_shader }, .after = { .compute } };
                gpu::cmd_barrier(&renderer.commands, &reused)!;
                gpu::cmd_bind_pipeline(&renderer.commands, renderer.instance_cull_pipeline)!;
                recorded = true;
            }
            LodGroupState* state = selection.state;
            Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
            gpu::MappedGpuSpan block = frame.upload.take(&renderer.device, InstanceCullRoot::size, STREAM_ALIGNMENT)!;
            if (selection.fallback) {
                *(InstanceCullRoot*)block.bytes.ptr = {
                    .lod_mode = shader::LOD_FINALIZE,
                    .counter = renderer.cull_arenas[renderer.frame_index % FRAMES_IN_FLIGHT].address,
                    .count = state.count,
                    .lod_count_visible = selection.main_visible ? 1 : 0,
                };
                gpu::cmd_dispatch(&renderer.commands, block.address, { 1, 1, 1 })!;
                renderer.stats.cull_dispatches++;
                renderer.cull_tested += state.count;
                continue;
            }
            Vec3 reach = state.effects.sway.reach();
            *(InstanceCullRoot*)block.bytes.ptr = {
                .instances = selection.instances.records,
                .counter = renderer.cull_arenas[renderer.frame_index % FRAMES_IN_FLIGHT].address,
                .bounds_min = { state.object_bounds.min.x, state.object_bounds.min.y, state.object_bounds.min.z, 0 },
                .bounds_max = { state.object_bounds.max.x, state.object_bounds.max.y, state.object_bounds.max.z, 0 },
                .count = state.count,
                .lod_current = selection.current,
                .lod_previous = selection.previous,
                .lod_metadata = selection.instances.lod_metadata,
                .lod_camera_bias = { selection.camera_position.x, selection.camera_position.y, selection.camera_position.z, selection.bias },
                .lod_projection = { selection.camera.projection == Projection.PERSPECTIVE ? 1.0f / math::tan(selection.camera.fov_y * 0.5f) : 0,
                    selection.camera.ortho_height, selection.camera.projection == Projection.ORTHOGRAPHIC ? 1 : 0, scene::LOD_HYSTERESIS },
                .lod_reach = { reach.x, reach.y, reach.z, 0 },
                .lod_mode = shader::LOD_SELECT,
                .lod_animated = state.animated ? 1 : 0,
                .lod_history_valid = selection.history_valid ? 1 : 0,
                .lod_level_count = (uint)state.desc.levels.len + (selection.impostor ? 1 : 0),
            };
            InstanceCullRoot* root = (InstanceCullRoot*)block.bytes.ptr;
            fill_lod_thresholds(state, selection.impostor, ((float*)&root.lod_thresholds)[:scene::MAX_LOD_CHOICES]);
            uint groups = (state.count + shader::INSTANCE_CULL_GROUP_SIZE - 1) / shader::INSTANCE_CULL_GROUP_SIZE;
            gpu::cmd_dispatch(&renderer.commands, block.address, { groups, 1, 1 })!;
            renderer.stats.cull_dispatches++;
        }
        if (recorded) {
            gpu::Barrier selected = { .before = { .compute }, .after = { .compute, .vertex_shader } };
            gpu::cmd_barrier(&renderer.commands, &selected)!;
        }
    }!;
}

fn void? prepare_lod_cull(Renderer* renderer, CullItem* item, bool culling) @private {
    MeshCandidate* candidate = item.candidate;
    LodSelection* selection = candidate.lod;
    selection.main_visible |= item.main_view;
    if (selection.fallback) {
        *item.range = prepare_cull_range(renderer, candidate, item.geometry)!;
        item.range.visible = candidate.animated_lod ? resolve_animated_lod_indices(renderer, candidate)!
          : (candidate.mirrored ? selection.instances.lod_mirrored_indices : selection.instances.lod_unmirrored_indices);
        item.range.indexed = true;
        return;
    }
    item.bounded = culling;
    item.bound = selection.state.object_bounds;
    item.sorted = item.main_view && lod_level_blended(renderer.assets, selection.state, candidate.lod_level);
    LodCullBin* bin;
    foreach (&existing : selection.bins[:selection.bin_count]) {
        if (existing.frustum == item.frustum && existing.level == candidate.lod_level
          && existing.mirrored == candidate.mirrored
          && (!candidate.animated_lod || existing.representation == candidate.lod_part)) {
            bin = existing;
            break;
        }
    }
    LodLevel level = selected_lod_level(selection, candidate.lod_level);
    uint part_index = candidate.lod_part - level.first_part;
    if (bin && bin.parts[part_index] != (gpu::GpuAddress)0) {
        item.args_address = bin.parts[part_index];
        usz offset = (usz)((ulong)item.args_address - (ulong)selection.arena.address);
        *item.range = {
            .args = selection.arena.span.checked_subspan(offset, indirect_args_bytes(&item.geometry.layout))!,
            .count = selection.state.count,
            .visible = bin.visible,
            .culled = true,
        };
        item.lod_reuse = true;
        return;
    }
    usz args_at = arena_place(&selection.arena, CULL_ARGS_STRIDE)!;
    item.args_address = (gpu::GpuAddress)((ulong)selection.arena.address + args_at);
    if (!bin) {
        bin = &selection.bins[selection.bin_count++];
        usz visible_at = item.sorted ? arena_place_sorted(&selection.arena, candidate.instance_count)!
          : arena_place(&selection.arena, (usz)candidate.instance_count * uint::size)!;
        *bin = {
            .frustum = item.frustum,
            .level = candidate.lod_level,
            .mirrored = candidate.mirrored,
            .representation = candidate.lod_part,
            .visible = (gpu::GpuAddress)((ulong)selection.arena.address + visible_at),
            .args = item.args_address,
            .parts = alloc::new_array(tmem, gpu::GpuAddress, level.part_count),
        };
        if (item.sorted) {
            item.keys_address = (gpu::GpuAddress)((ulong)bin.visible + sorted_list_bytes(candidate.instance_count));
            acquire_compute_pipeline(
                renderer: renderer,
                pipeline: &renderer.instance_sort_pipeline,
                shader: INSTANCE_SORT,
                debug_name: "instance_sort",
            )!;
        }
    } else {
        item.lod_count = bin.args;
    }
    bin.parts[part_index] = item.args_address;
    usz bytes = indirect_args_bytes(&item.geometry.layout);
    *item.range = {
        .args = selection.arena.span.checked_subspan(args_at, bytes)!,
        .count = selection.state.count,
        .visible = bin.visible,
        .culled = true,
    };
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = frame.upload.take(&renderer.device, bytes, STREAM_ALIGNMENT)!;
    write_indirect_args(staging.bytes, &item.geometry.layout, 0);
    renderer.pending_copies.push({ .src = staging.span, .dst = item.range.args });
    clear_cull_counters(renderer)!;
}
