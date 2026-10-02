module c3d::render;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::maths;
import c3d::scene;
import c3d::spatial;
import c3d::shader;
import gpu;
import std::math;

struct LodHistoryValue @private {
    ulong scene;
    Entity owner;
    ulong identity;
    uint bounds_revision;
    uint level;
    bool valid;
}

struct LodHistoryEntry @private {
    LodHistoryValue committed;
    LodHistoryValue pending;
    bool dirty;
    gpu::GpuAllocation allocation;
    gpu::GpuAddress address;
    uint capacity;
    uint committed_slot;
    ulong instance_epoch;
    ulong pending_epoch;
    ulong last_seen;
    SwayGpu sway;
    SwayGpu pending_sway;
}

struct LodSelection @private {
    ulong scene_identity;
    Node* node;
    LodGroupState* state;
    GpuInstances* instances;
    Aabb world_bounds;
    uint level;
    bool reject_history;
    LodHistoryEntry* history;
    gpu::GpuAddress current;
    gpu::GpuAddress previous;
    bool history_valid;
    bool fallback;
    CullArena arena;
    LodCullBin[] bins;
    uint bin_count;
    Camera camera;
    Vec3 camera_position;
    float bias;
    gpu::GpuAddress[] parts;
    bool main_visible;
}

fn float lod_screen_size(
    Camera camera,
    Vec3 camera_position,
    Sphere bounds,
    float bias,
) @private {
    if (bounds.radius == 0) return 0;
    float size = camera::projected_size(
        camera: camera,
        camera_position: camera_position,
        bounds: bounds,
        output_height: 1,
    );
    if (size == 0 || !math::is_finite(size)) return size;
    return math::exp2(math::log2(size) + bias);
}

fn LodSelection select_lod_group(
    LodHistoryEntry* history,
    Scene* scene,
    AssetStore* assets,
    Node* node,
    LodGroupState* state,
    Camera camera,
    Vec3 camera_position,
    float bias,
) @private {
    LodGroup group = { .state = state };
    Aabb world = spatial::lod_world_bounds(assets, node, &group);
    LodHistoryValue previous = history.committed;
    bool valid = previous.valid && previous.scene == scene.identity
      && c3d::same_id(previous.owner, node.id) && previous.identity == state.identity
      && previous.bounds_revision == state.bounds_revision;
    float[scene::MAX_LOD_LEVELS] thresholds;
    foreach (index, level : state.desc.levels) thresholds[index] = level.min_screen_size;
    uint level = scene::select_lod_level(
        screen_size: lod_screen_size(
            camera: camera,
            camera_position: camera_position,
            bounds: maths::aabb_sphere(world),
            bias: bias,
        ),
        min_screen_sizes: thresholds[:state.desc.levels.len],
        previous: previous.level,
        history_valid: valid,
    );
    history.pending = {
        .scene = scene.identity,
        .owner = node.id,
        .identity = state.identity,
        .bounds_revision = state.bounds_revision,
        .level = level,
        .valid = true,
    };
    history.dirty = true;
    return {
        .scene_identity = scene.identity,
        .node = node,
        .state = state,
        .world_bounds = world,
        .level = level,
        .reject_history = !valid || level != previous.level,
    };
}

fn LodSelection[]? prepare_lod_view(
    Renderer* renderer,
    ViewRecord* record,
    Scene* scene,
    Camera camera,
    CameraMatrices* matrices,
) @private {
    if (scene.count(LodGroup) && record.lod_history.len != scene.nodes.len) {
        retire_lod_history(renderer, record.lod_history);
        record.lod_history = alloc::new_array(renderer.allocator, LodHistoryEntry, scene.nodes.len);
    }
    foreach (&entry : record.lod_history) {
        if (entry.allocation.is_valid() && renderer.frame_index - entry.last_seen > INSTANCE_ABSENCE_FRAMES) {
            renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = entry.allocation });
            *entry = {};
        }
    }
    if (!scene.count(LodGroup)) return {};
    LodSelection[] selections = alloc::new_array(tmem, LodSelection, scene.nodes.len);
    scene.@each(LodGroup; Entity entity, LodGroup* group) {
        Node* node = scene.node(entity);
        if (node.visible_effective && group.state.count) {
            if (!spatial::lod_group_is_live(renderer.assets, group)) {
                renderer.stats.dangling_refs++;
            } else {
                LodHistoryEntry* history = &record.lod_history[entity.index];
                if (group.state.mode == LodMode.INSTANCED) {
                    selections[entity.index] = {
                        .scene_identity = scene.identity,
                        .node = node,
                        .state = group.state,
                        .world_bounds = spatial::lod_world_bounds(renderer.assets, node, group),
                        .history = &record.lod_history[entity.index],
                        .camera = camera,
                        .camera_position = matrices.position,
                        .bias = record.desc.lod_bias,
                    };
                    prepare_lod_instances(renderer, &selections[entity.index])!;
                } else {
                    if (history.allocation.is_valid()) {
                        renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = history.allocation });
                        *history = {};
                    }
                    selections[entity.index] = select_lod_group(
                        history: history,
                        scene: scene,
                        assets: renderer.assets,
                        node: node,
                        state: group.state,
                        camera: camera,
                        camera_position: matrices.position,
                        bias: record.desc.lod_bias,
                    );
                    selections[entity.index].history = &record.lod_history[entity.index];
                    renderer.stats.lod_objects_selected[selections[entity.index].level]++;
                }
                record.lod_history[entity.index].pending_sway = pack_sway(group.state.effects.sway, renderer.info.time);
                selections[entity.index].parts = alloc::new_array(tmem, gpu::GpuAddress, group.state.desc.parts.len);
            }
        }
    };
    return selections;
}

fn void publish_lod_history(LodHistoryEntry[] history) @private {
    foreach (&entry : history) {
        if (!entry.dirty) continue;
        entry.committed = entry.pending;
        entry.instance_epoch = entry.pending_epoch;
        if (entry.allocation.is_valid()) entry.committed_slot ^= 1;
        entry.sway = entry.pending_sway;
        entry.dirty = false;
    }
}

fn void discard_lod_history(LodHistoryEntry[] history) @private {
    foreach (&entry : history) entry.dirty = false;
}

fn void reset_lod_history(LodHistoryEntry[] history) @private {
    foreach (&entry : history) {
        entry.committed.valid = false;
        entry.dirty = false;
    }
}

fn Mat4 candidate_world(MeshCandidate* candidate) @private {
    if (!candidate.lod) return candidate.node.world;
    return candidate.node.world.mul(candidate.lod.state.desc.parts[candidate.lod_part].local);
}

fn bool candidate_instanced(MeshCandidate* candidate) @private {
    return candidate.batch || candidate.billboards || (candidate.lod && candidate.lod.state.mode == LodMode.INSTANCED);
}

fn void retire_lod_history(Renderer* renderer, LodHistoryEntry[] history) @private {
    foreach (&entry : history) {
        if (entry.allocation.is_valid()) renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = entry.allocation });
    }
    alloc::free(renderer.allocator, history.ptr);
}

fn void free_lod_history(Renderer* renderer, LodHistoryEntry[] history) @private {
    foreach (&entry : history) {
        if (entry.allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &entry.allocation);
    }
    alloc::free(renderer.allocator, history.ptr);
}

fn gpu::GpuAddress? resolve_lod_part(Renderer* renderer, MeshCandidate* candidate) @private {
    if (!candidate.lod) return (gpu::GpuAddress)0;
    LodSelection* selection = candidate.lod;
    gpu::GpuAddress* address = &selection.parts[candidate.lod_part];
    if (*address != (gpu::GpuAddress)0) return *address;
    Mat4 local = selection.state.desc.parts[candidate.lod_part].local;
    Mat3 normal = maths::normal_matrix(local);
    LodPartGpu part = {
        .local = bitcast(local, Mat4f),
        .normal_0 = { normal.m00, normal.m10, normal.m20, 0 },
        .normal_1 = { normal.m01, normal.m11, normal.m21, 0 },
        .normal_2 = { normal.m02, normal.m12, normal.m22, 0 },
        .current = selection.current,
        .previous = selection.previous,
        .reject_history = selection.reject_history ? 1 : 0,
        .seed = instance_seed({}),
    };
    *address = upload_bytes(renderer, &part, LodPartGpu::size)!;
    return *address;
}
