module c3d::render;

import c3d;
import c3d::camera;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import c3d::spatial @public;
import gpu;
import std::math;

const uint QUADTREE_VIEW_PASSES @private = 2; // view and depth prepass; one more per shadow layer
$assert QuadtreeMetric.SPHERE_PIXELS.ordinal == shader::QUADTREE_METRIC_SPHERE_PIXELS;
$assert QuadtreeMetric.BOX_RANGES.ordinal == shader::QUADTREE_METRIC_BOX_RANGES;
$assert scene::MAX_QUADTREE_DEPTH + 1 == 9; // QuadtreeGpu.levels in c3d.abi

<*
 Camera that selects a pass's quadtree levels: position relative to the frame origin, and the pixel scale in w.
*>
struct SelectionCamera {
    Vec4 current;
    Vec4 previous; // the same one rendering earlier; equals current after a camera cut
    bool orthographic; // a shadow layer's own projection is the light's, so its frame cannot show this
}

struct QuadtreeOffsets @private {
    usz leaves;
    usz depths;
    usz params;
    usz size;
}

struct QuadtreeHistoryValue @private {
    ulong  scene;
    Entity owner;
    uint   revision;
    uint   count;
    bool   valid;
}

struct QuadtreeHistoryEntry @private {
    QuadtreeHistoryValue committed;
    QuadtreeHistoryValue pending;
    bool                 dirty;
    gpu::GpuAllocation   allocation;
    gpu::GpuAddress      address;
    uint                 capacity;
    uint                 committed_slot;
    ulong                last_seen;
    uint                 next;
    bool                 listed;
}

struct QuadtreeHistory @private {
    QuadtreeHistoryEntry[] entries;
    uint                   first;
}

struct QuadtreeSelection @private {
    Node*                 node;
    InstancedMesh*        batch;
    GpuInstances*         instances;
    QuadtreeHistoryEntry* history;
    gpu::GpuAddress       current;
    gpu::GpuAddress       previous;
    bool                  history_valid;
    bool                  fallback;
    CullArena             arena;
    Camera                camera;
    Vec3                  camera_position;
    float                 height_pixels;
    float                 pixel_scale;
}

fn SelectionCamera selection_camera_of(Camera* camera, Vec3 position, float height_pixels) @private {
    float pixel_scale = camera.projection == Projection.ORTHOGRAPHIC
      ? height_pixels / camera.ortho_height
      : height_pixels / (2 * math::tan(camera.fov_y * 0.5f));
    Vec4 own = { position.x, position.y, position.z, pixel_scale };
    return { .current = own, .previous = own, .orthographic = camera.projection == Projection.ORTHOGRAPHIC };
}

fn bool quadtree_nodes_stale(GpuInstances* slot, InstancedMesh* batch) @private {
    return slot.quadtree_revision != batch.quadtree.revision || slot.quadtree_count != batch.count;
}

fn bool quadtree_parameters_stale(GpuInstances* slot, InstancedMesh* batch) @private {
    InstanceQuadtree* quadtree = &batch.quadtree;
    return slot.quadtree_parameter_revision != quadtree.parameter_revision
      || slot.quadtree_split_pixels != quadtree.split_pixels || slot.quadtree_hysteresis != quadtree.hysteresis;
}

fn bool quadtree_stale(GpuInstances* slot, InstancedMesh* batch) @private {
    return quadtree_nodes_stale(slot, batch) || quadtree_parameters_stale(slot, batch);
}

// mirrored as quadtree_world_scale in quadtree_morph.glsl
fn float quadtree_world_scale(Mat4 world) @private {
    Vec3 column_x = { world.m00, world.m10, world.m20 };
    Vec3 column_y = { world.m01, world.m11, world.m21 };
    Vec3 column_z = { world.m02, world.m12, world.m22 };
    return math::max(column_x.length(), math::max(column_y.length(), column_z.length()));
}

fn QuadtreeOffsets quadtree_offsets(usz capacity) @private {
    usz nodes_bytes = align_up(capacity * QuadtreeNodeGpu::size, STREAM_ALIGNMENT);
    usz list_bytes = align_up(capacity * uint::size, STREAM_ALIGNMENT);
    return {
        .leaves = nodes_bytes,
        .depths = nodes_bytes + list_bytes,
        .params = nodes_bytes + 2 * list_bytes,
        .size   = nodes_bytes + 2 * list_bytes + QuadtreeGpu::size,
    };
}

fn QuadtreeGpu pack_quadtree_parameters(InstanceQuadtree* quadtree) @private {
    QuadtreeGpu block = {
        .metric       = (uint)quadtree.metric.ordinal,
        .split_pixels = quadtree.split_pixels,
        .hysteresis   = quadtree.hysteresis,
        .morph_band   = quadtree.morph_band,
        .depth_count  = quadtree.depth_count,
    };

    foreach (depth, level : quadtree.levels[:quadtree.depth_count]) {
        block.levels[depth] = { .extent = level.extent, .diagonal = level.diagonal };
    }

    return block;
}

fn QuadtreeSelection* find_quadtree_selection(QuadtreeSelection[] selections, Node* node) @private {
    foreach (&selection : selections) {
        if (selection.node == node) return selection;
    }
    return null;
}

fn void? resolve_quadtree_nodes(Renderer* renderer, uint index, InstancedMesh* batch) @private {
    GpuInstances* slot = &renderer.instances.slots[index];
    InstanceQuadtree* quadtree = &batch.quadtree;

    if (slot.quadtree_capacity < batch.transforms.len) {
        QuadtreeOffsets offsets = quadtree_offsets(batch.transforms.len);
        gpu::AllocationDesc desc = {
            .size         = offsets.size,
            .alignment    = STREAM_ALIGNMENT,
            .memory_class = gpu::MemoryClass.GPU_PRIVATE,
            .access       = { .graphics },
            .debug_name   = "quadtree_nodes",
        };
        gpu::GpuAllocation allocation = gpu::allocate_memory(&renderer.device, &desc)!;
        defer catch (void)gpu::free_allocation(&renderer.device, &allocation);
        gpu::GpuAddress address = gpu::get_span_address(
            &renderer.device,
            gpu::get_allocation_span(&renderer.device, allocation)!,
        )!;
        if (slot.quadtree_allocation.is_valid()) {
            renderer.pending_upload_retire.push({
                .kind       = RetiredKind.ALLOCATION,
                .allocation = slot.quadtree_allocation,
            });
        }
        slot.quadtree_allocation = allocation;
        slot.quadtree_nodes = address;
        slot.quadtree_leaves = (gpu::GpuAddress)((ulong)address + offsets.leaves);
        slot.quadtree_depths = (gpu::GpuAddress)((ulong)address + offsets.depths);
        slot.quadtree_params = (gpu::GpuAddress)((ulong)address + offsets.params);
        slot.quadtree_capacity = (uint)batch.transforms.len;
    }

    // A smaller batch can land on a slot that survived from a larger one, whose addresses keep their layout.
    QuadtreeOffsets offsets = quadtree_offsets(slot.quadtree_capacity);
    usz nodes_bytes = (usz)batch.count * QuadtreeNodeGpu::size;
    usz leaves_bytes = (usz)quadtree.leaf_count * uint::size;
    usz depths_bytes = (usz)batch.count * uint::size;
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = frame.upload.take(
        &renderer.device,
        nodes_bytes + leaves_bytes + depths_bytes,
        STREAM_ALIGNMENT,
    )!;
    QuadtreeNodeGpu[] nodes = ((QuadtreeNodeGpu*)staging.bytes.ptr)[:batch.count];
    uint[] leaves = ((uint*)(staging.bytes.ptr + nodes_bytes))[:quadtree.leaf_count];
    uint[] depths = ((uint*)(staging.bytes.ptr + nodes_bytes + leaves_bytes))[:batch.count];
    foreach (instance, &node : nodes) *node = { .parent = quadtree.parents[instance], .children = 0 };
    foreach (parent : quadtree.parents) {
        if (parent != scene::QUADTREE_ROOT) nodes[parent].children++;
    }
    uint leaf_next;
    foreach (uint instance, leaf : quadtree.leaves) {
        if (leaf) leaves[leaf_next++] = instance;
    }
    foreach (uint instance, &depth : depths) *depth = quadtree.depth_of(instance);

    gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, slot.quadtree_allocation)!;
    renderer.pending_copies.push({
        .src = staging.span.checked_subspan(0, nodes_bytes)!,
        .dst = destination.checked_subspan(0, nodes_bytes)!,
    });
    renderer.pending_copies.push({
        .src = staging.span.checked_subspan(nodes_bytes, leaves_bytes)!,
        .dst = destination.checked_subspan(offsets.leaves, leaves_bytes)!,
    });
    renderer.pending_copies.push({
        .src = staging.span.checked_subspan(nodes_bytes + leaves_bytes, depths_bytes)!,
        .dst = destination.checked_subspan(offsets.depths, depths_bytes)!,
    });
    renderer.pending_instance_uploads.push(index);

    slot.quadtree_revision = quadtree.revision;
    slot.quadtree_count = batch.count;
    renderer.stats.uploads++;
    renderer.stats.upload_bytes += (uint)(nodes_bytes + leaves_bytes + depths_bytes);
    upload_quadtree_parameters(renderer, index, batch)!;
}

fn void? upload_quadtree_parameters(Renderer* renderer, uint index, InstancedMesh* batch) @private {
    GpuInstances* slot = &renderer.instances.slots[index];
    InstanceQuadtree* quadtree = &batch.quadtree;

    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = frame.upload.take(&renderer.device, QuadtreeGpu::size, STREAM_ALIGNMENT)!;
    *(QuadtreeGpu*)staging.bytes.ptr = pack_quadtree_parameters(quadtree);

    gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, slot.quadtree_allocation)!;
    renderer.pending_copies.push({
        .src = staging.span,
        .dst = destination.checked_subspan(quadtree_offsets(slot.quadtree_capacity).params, QuadtreeGpu::size)!,
    });
    renderer.pending_overwrite = true;
    renderer.pending_instance_uploads.push(index);

    slot.quadtree_parameter_revision = quadtree.parameter_revision;
    slot.quadtree_split_pixels = quadtree.split_pixels;
    slot.quadtree_hysteresis = quadtree.hysteresis;
    renderer.stats.upload_bytes += QuadtreeGpu::size;
}

fn void? reserve_quadtree_cull(Renderer* renderer, QuadtreeSelection* selection) @private {
    acquire_instance_culling(renderer)!;
    CullArena* shared = &renderer.cull_arenas[renderer.frame_index % FRAMES_IN_FLIGHT];
    CullArena reserved = *shared;
    uint count = selection.batch.count;
    bool blended = renderer.assets.material(selection.batch.material).data.common.alpha_mode == AlphaMode.BLEND;
    uint passes = QUADTREE_VIEW_PASSES + renderer.max_shadow_layers;

    for (uint pass = 0; pass < passes; pass++) {
        arena_place(&reserved, CULL_ARGS_STRIDE)!;
        if (pass == 0 && blended) {
            if (count > MAX_SORTED_INSTANCES) return c3d::CAPACITY_EXCEEDED~;

            arena_place(&reserved, align_up(
                sorted_list_bytes(count) + (usz)sort_capacity(count) * ulong::size,
                STREAM_ALIGNMENT,
            ))!;
        } else {
            arena_place(&reserved, align_up((usz)count * uint::size, STREAM_ALIGNMENT))!;
        }
    }

    selection.arena = *shared;
    selection.arena.capacity = reserved.head;
    shared.head = reserved.head;
}

fn void? prepare_quadtree_selection(
    Renderer* renderer,
    QuadtreeSelection* selection,
    ulong scene_identity,
) @private {
    InstancedMesh* batch = selection.batch;
    MeshCandidate resolved = { .node = selection.node, .batch = batch, .scene_identity = scene_identity };
    resolve_instances(renderer, &resolved)!;

    InstanceKey key = {
        .scene = scene_identity,
        .node  = selection.node.id,
        .kind  = shader::INSTANCE_KIND_MESH,
    };
    selection.instances = &renderer.instances.slots[renderer.instances.lookup.get(key)!!];

    if (catch excuse = reserve_quadtree_cull(renderer, selection)) {
        if (excuse != c3d::CAPACITY_EXCEEDED) return excuse~;

        selection.fallback = true;
        renderer.stats.quadtree_fallbacks++;
    }

    QuadtreeHistoryEntry* history = selection.history;
    QuadtreeHistoryValue previous = history.committed;
    selection.history_valid = previous.valid && previous.scene == scene_identity
      && c3d::same_id(previous.owner, selection.node.id) && previous.revision == batch.quadtree.revision
      && previous.count == batch.count;
    history.pending = {
        .scene    = scene_identity,
        .owner    = selection.node.id,
        .revision = batch.quadtree.revision,
        .count    = batch.count,
        .valid    = !selection.fallback,
    };
    history.dirty = true;
    if (selection.fallback) return;

    if (history.capacity < batch.transforms.len) {
        usz capacity = batch.transforms.len;
        gpu::AllocationDesc desc = {
            .size         = 2 * capacity * uint::size,
            .alignment    = STREAM_ALIGNMENT,
            .memory_class = gpu::MemoryClass.GPU_PRIVATE,
            .access       = { .graphics },
            .debug_name   = "quadtree_history",
        };
        gpu::GpuAllocation allocation = gpu::allocate_memory(&renderer.device, &desc)!;
        defer catch (void)gpu::free_allocation(&renderer.device, &allocation);
        gpu::GpuAddress address = gpu::get_span_address(
            &renderer.device,
            gpu::get_allocation_span(&renderer.device, allocation)!,
        )!;
        if (history.allocation.is_valid()) {
            renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = history.allocation });
        }
        history.allocation = allocation;
        history.address = address;
        history.capacity = (uint)capacity;
        selection.history_valid = false;
    }

    selection.current = offset_by_instances(history.address, (history.committed_slot ^ 1) * history.capacity, uint::size);
    selection.previous = offset_by_instances(history.address, history.committed_slot * history.capacity, uint::size);
}

fn QuadtreeSelection[]? prepare_quadtree_view(
    Renderer* renderer,
    ViewRecord* record,
    Scene* scene,
    Camera camera,
    CameraMatrices* matrices,
    float pixel_scale,
) @private {
    QuadtreeHistory* histories = &record.quadtree_history;
    uint batches;
    bool with_lod_group;
    scene.@each(InstancedMesh; Entity entity, InstancedMesh* batch) {
        if (batch.quadtree.parents.len) {
            batches++;
            with_lod_group |= scene.has(scene.node(entity), LodGroup);
        }
    };
    if (with_lod_group) return c3d::UNSUPPORTED~;

    if (batches && histories.entries.len != scene.nodes.len) {
        retire_quadtree_history(renderer, histories);
        histories.entries = alloc::new_array(renderer.allocator, QuadtreeHistoryEntry, scene.nodes.len);
    }

    uint* cursor = &histories.first;
    while (*cursor) {
        QuadtreeHistoryEntry* entry = &histories.entries[*cursor - 1];
        if (renderer.frame_index - entry.last_seen > INSTANCE_ABSENCE_FRAMES) {
            if (entry.allocation.is_valid()) {
                renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = entry.allocation });
            }
            *cursor = entry.next;
            *entry = {};
        } else {
            cursor = &entry.next;
        }
    }

    if (!batches) return {};

    float height_pixels = (float)record.hdr_color.height;
    QuadtreeSelection[] selections = alloc::new_array(tmem, QuadtreeSelection, batches);
    usz count;
    scene.@each(InstancedMesh; Entity entity, InstancedMesh* batch) {
        Node* node = scene.node(entity);
        if (batch.quadtree.parents.len && batch.count && node.visible_effective
          && !spatial::animated_lod_owns_node(scene, node) && batch_is_drawable(renderer.assets, batch)) {
            QuadtreeHistoryEntry* history = &histories.entries[entity.index];
            if (!history.listed) {
                history.next = histories.first;
                history.listed = true;
                histories.first = entity.index + 1;
            }
            history.last_seen = renderer.frame_index;
            selections[count] = {
                .node            = node,
                .batch           = batch,
                .history         = history,
                .camera          = camera,
                .camera_position = matrices.position,
                .height_pixels   = height_pixels,
                .pixel_scale     = pixel_scale,
            };
            prepare_quadtree_selection(renderer, &selections[count], scene.identity)!;
            count++;
        }
    };

    return selections[:count];
}

fn void? record_quadtree_selection(Renderer* renderer, QuadtreeSelection[] selections) @private {
    bool selecting;
    foreach (selection : selections) selecting |= !selection.fallback;
    if (!selecting) return;

    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    @profile_pass(renderer, Pass.INSTANCE_CULL) {
        gpu::Barrier prepared = { .before = { .transfer, .compute, .vertex_shader }, .after = { .compute } };
        gpu::cmd_barrier(&renderer.commands, &prepared)!;
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.instance_cull_pipeline)!;
        foreach (&selection : selections) {
            if (selection.fallback) continue;

            InstancedMesh* batch = selection.batch;
            Camera* camera = &selection.camera;
            Aabb bounds = renderer.assets.geometry(batch.geometry).data.bounds;
            gpu::MappedGpuSpan block = frame.upload.take(&renderer.device, InstanceCullRoot::size, STREAM_ALIGNMENT)!;
            *(InstanceCullRoot*)block.bytes.ptr = {
                .instances              = selection.instances.records,
                .bounds_min             = { bounds.min.x, bounds.min.y, bounds.min.z, 0 },
                .bounds_max             = { bounds.max.x, bounds.max.y, bounds.max.z, 0 },
                .count                  = batch.count,
                .lod_current            = selection.current,
                .lod_previous           = selection.previous,
                .lod_camera_bias        = {
                    selection.camera_position.x, selection.camera_position.y, selection.camera_position.z, 0,
                },
                .lod_projection         = {
                    camera.projection == Projection.PERSPECTIVE ? 1.0f / math::tan(camera.fov_y * 0.5f) : 0,
                    camera.ortho_height,
                    camera.projection == Projection.ORTHOGRAPHIC ? 1 : 0,
                    0,
                },
                .lod_mode               = shader::QUADTREE_SELECT,
                .quadtree_nodes         = selection.instances.quadtree_nodes,
                .quadtree_history_valid = selection.history_valid ? 1 : 0,
                .quadtree_split_pixels  = batch.quadtree.split_pixels,
                .quadtree_hysteresis    = batch.quadtree.hysteresis,
                .quadtree_height_pixels = selection.height_pixels,
                .quadtree_pixel_scale   = selection.pixel_scale,
                .quadtree_world_scale   = quadtree_world_scale(selection.node.world),
                .quadtree_params        = batch.quadtree.metric == QuadtreeMetric.BOX_RANGES
                  ? selection.instances.quadtree_params : (gpu::GpuAddress)0,
                .quadtree_depths        = selection.instances.quadtree_depths,
                .node_world             = bitcast(maths::rebase(selection.node.world, renderer.frame_origin), Mat4f),
            };
            uint groups = (batch.count + shader::INSTANCE_CULL_GROUP_SIZE - 1) / shader::INSTANCE_CULL_GROUP_SIZE;
            gpu::cmd_dispatch(&renderer.commands, block.address, { groups, 1, 1 })!;
            renderer.stats.cull_dispatches++;
        }
        gpu::Barrier selected = { .before = { .compute }, .after = { .compute, .vertex_shader } };
        gpu::cmd_barrier(&renderer.commands, &selected)!;
    }!;
}

fn void? prepare_quadtree_cull(Renderer* renderer, CullItem* item, bool culling) @private {
    MeshCandidate* candidate = item.candidate;
    QuadtreeSelection* selection = candidate.quadtree;
    Aabb? bound = cull_bound(candidate, item.geometry);
    item.bounded = culling && @ok(bound);
    item.bound = bound ?? item.geometry.bounds;

    if (selection.fallback) {
        MeshCandidate leaves = *candidate;
        leaves.instance_count = selection.batch.quadtree.leaf_count;
        *item.range = prepare_cull_range(renderer, &leaves, item.geometry)!;
        item.range.visible = selection.instances.quadtree_leaves;
        item.range.indexed = true;
        item.sorted = false;
        return;
    }

    usz args_at = arena_place(&selection.arena, CULL_ARGS_STRIDE)!;
    usz visible_at = item.sorted
      ? arena_place_sorted(&selection.arena, candidate.instance_count)!
      : arena_place(&selection.arena, (usz)candidate.instance_count * uint::size)!;
    usz bytes = indirect_args_bytes(&item.geometry.layout);
    item.args_address = (gpu::GpuAddress)((ulong)selection.arena.address + args_at);
    *item.range = {
        .args    = selection.arena.span.checked_subspan(args_at, bytes)!,
        .count   = candidate.instance_count,
        .first   = candidate.instance_first,
        .visible = (gpu::GpuAddress)((ulong)selection.arena.address + visible_at),
        .culled  = true,
    };
    if (item.sorted) {
        item.keys_address = (gpu::GpuAddress)((ulong)item.range.visible + sorted_list_bytes(candidate.instance_count));
        acquire_compute_pipeline(
            renderer:   renderer,
            pipeline:   &renderer.instance_sort_pipeline,
            shader:     INSTANCE_SORT,
            debug_name: "instance_sort",
        )!;
    }

    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = frame.upload.take(&renderer.device, bytes, STREAM_ALIGNMENT)!;
    write_indirect_args(staging.bytes, &item.geometry.layout, 0);
    renderer.pending_copies.push({ .src = staging.span, .dst = item.range.args });
    clear_cull_counters(renderer)!;
}

fn void publish_quadtree_history(QuadtreeHistory* history) @private {
    for (uint cursor = history.first; cursor; cursor = history.entries[cursor - 1].next) {
        QuadtreeHistoryEntry* entry = &history.entries[cursor - 1];
        if (!entry.dirty) continue;

        entry.committed = entry.pending;
        if (entry.allocation.is_valid()) entry.committed_slot ^= 1;
        entry.dirty = false;
    }
}

fn void discard_quadtree_history(QuadtreeHistory* history) @private {
    for (uint cursor = history.first; cursor; cursor = history.entries[cursor - 1].next) {
        history.entries[cursor - 1].dirty = false;
    }
}

fn void reset_quadtree_history(QuadtreeHistory* history) @private {
    for (uint cursor = history.first; cursor; cursor = history.entries[cursor - 1].next) {
        QuadtreeHistoryEntry* entry = &history.entries[cursor - 1];
        entry.committed.valid = false;
        entry.dirty = false;
    }
}

fn void retire_quadtree_history(Renderer* renderer, QuadtreeHistory* history) @private {
    for (uint cursor = history.first; cursor; cursor = history.entries[cursor - 1].next) {
        QuadtreeHistoryEntry* entry = &history.entries[cursor - 1];
        if (entry.allocation.is_valid()) {
            renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = entry.allocation });
        }
    }
    alloc::free(renderer.allocator, history.entries.ptr);
    *history = {};
}

fn void free_quadtree_history(Renderer* renderer, QuadtreeHistory* history) @private {
    for (uint cursor = history.first; cursor; cursor = history.entries[cursor - 1].next) {
        QuadtreeHistoryEntry* entry = &history.entries[cursor - 1];
        if (entry.allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &entry.allocation);
    }
    alloc::free(renderer.allocator, history.entries.ptr);
    *history = {};
}
