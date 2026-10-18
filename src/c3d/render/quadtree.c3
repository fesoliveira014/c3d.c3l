module c3d::render;

import c3d;
import c3d::camera;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import c3d::spatial @public;
import gpu;
import std::math;

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
    Camera                camera;
    Vec3                  camera_position;
    float                 height_pixels;
}

fn bool quadtree_nodes_stale(GpuInstances* slot, InstancedMesh* batch) @private {
    return slot.quadtree_revision != batch.quadtree.revision || slot.quadtree_count != batch.count;
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
        gpu::AllocationDesc desc = {
            .size         = batch.transforms.len * QuadtreeNodeGpu::size,
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
        slot.quadtree_capacity = (uint)batch.transforms.len;
    }

    usz bytes = (usz)batch.count * QuadtreeNodeGpu::size;
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = frame.upload.take(&renderer.device, bytes, STREAM_ALIGNMENT)!;
    QuadtreeNodeGpu[] nodes = ((QuadtreeNodeGpu*)staging.bytes.ptr)[:batch.count];
    foreach (instance, &node : nodes) *node = { .parent = quadtree.parents[instance], .children = 0 };
    foreach (parent : quadtree.parents) {
        if (parent != scene::QUADTREE_ROOT) nodes[parent].children++;
    }

    gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, slot.quadtree_allocation)!;
    renderer.pending_copies.push({ .src = staging.span, .dst = destination.checked_subspan(0, bytes)! });
    renderer.pending_instance_uploads.push(index);

    slot.quadtree_revision = quadtree.revision;
    slot.quadtree_count = batch.count;
    renderer.stats.uploads++;
    renderer.stats.upload_bytes += (uint)bytes;
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
        .valid    = true,
    };
    history.dirty = true;

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
                .height_pixels   = (float)record.hdr_color.height,
            };
            prepare_quadtree_selection(renderer, &selections[count], scene.identity)!;
            count++;
        }
    };
    return selections[:count];
}

fn void? record_quadtree_selection(Renderer* renderer, QuadtreeSelection[] selections) @private {
    if (!selections.len) return;

    acquire_instance_culling(renderer)!;
    Frame* frame = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    @profile_pass(renderer, Pass.INSTANCE_CULL) {
        gpu::Barrier prepared = { .before = { .transfer, .compute, .vertex_shader }, .after = { .compute } };
        gpu::cmd_barrier(&renderer.commands, &prepared)!;
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.instance_cull_pipeline)!;
        foreach (&selection : selections) {
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
            };
            uint groups = (batch.count + shader::INSTANCE_CULL_GROUP_SIZE - 1) / shader::INSTANCE_CULL_GROUP_SIZE;
            gpu::cmd_dispatch(&renderer.commands, block.address, { groups, 1, 1 })!;
            renderer.stats.cull_dispatches++;
        }
        gpu::Barrier selected = { .before = { .compute }, .after = { .compute, .vertex_shader } };
        gpu::cmd_barrier(&renderer.commands, &selected)!;
    }!;
}

fn CullRange? prepare_unselected_range(Renderer* renderer, CullItem* item) @private {
    MeshCandidate empty = *item.candidate;
    empty.instance_count = 0;
    return prepare_cull_range(renderer, &empty, item.geometry);
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
