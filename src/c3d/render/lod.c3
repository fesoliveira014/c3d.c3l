module c3d::render;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::maths;
import c3d::material;
import c3d::model;
import c3d::scene;
import c3d::spatial;
import c3d::shader;
import c3d::render::post;
import gpu;
import std::math;

struct LodHistoryValue @private {
    ulong scene;
    Entity owner;
    ulong identity;
    uint bounds_revision;
    uint descriptor_revision;
    bool impostor;
    uint level;
    bool valid;
    Vec4 camera;
    Vec4 direction;
    Vec3 origin;
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
    uint next;
    bool listed;
}

struct LodHistory @private {
    LodHistoryEntry[] entries;
    uint first;
}

struct LodSelection @private {
    Scene* scene;
    ViewHistory* pose_history;
    gpu::GpuAddress previous_palette;
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
    uint[] part_unmirrored;
    bool main_visible;
    bool impostor;
    Vec3 previous_view_origin;
    bool view_history_valid;
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
    Vec3 origin = {},
) @private {
    LodGroup group = { .state = state };
    Aabb world = spatial::lod_world_bounds(
        assets: assets,
        node: node,
        group: &group,
        origin: origin,
        scene: scene,
    );
    LodHistoryValue previous = history.committed;
    bool valid = previous.valid && previous.scene == scene.identity
      && c3d::same_id(previous.owner, node.id) && previous.identity == state.identity
      && previous.bounds_revision == state.bounds_revision
      && previous.descriptor_revision == state.descriptor_revision;
    bool impostor = lod_impostor_live(assets, state);
    valid &= previous.impostor == impostor;
    float[scene::MAX_LOD_CHOICES] thresholds;
    uint choices = fill_lod_thresholds(state, impostor, thresholds[..]);
    uint level = scene::select_lod_level(
        screen_size: lod_screen_size(
            camera: camera,
            camera_position: camera_position,
            bounds: maths::aabb_sphere(world),
            bias: bias,
        ),
        min_screen_sizes: thresholds[:choices],
        previous: previous.level,
        history_valid: valid,
    );
    history.pending = {
        .scene = scene.identity,
        .owner = node.id,
        .identity = state.identity,
        .bounds_revision = state.bounds_revision,
        .descriptor_revision = state.descriptor_revision,
        .impostor = impostor,
        .level = level,
        .valid = true,
    };
    history.dirty = true;
    return {
        .scene = scene,
        .scene_identity = scene.identity,
        .node = node,
        .state = state,
        .world_bounds = world,
        .level = level,
        .reject_history = !valid || (!state.animated && level != previous.level),
        .impostor = impostor,
    };
}

fn LodSelection[]? prepare_lod_view(
    Renderer* renderer,
    ViewRecord* record,
    Scene* scene,
    Camera camera,
    CameraMatrices* matrices,
) @private {
    LodHistory* histories = &record.lod_history;
    if (scene.count(LodGroup) && histories.entries.len != scene.nodes.len) {
        retire_lod_history(renderer, histories);
        histories.entries = alloc::new_array(renderer.allocator, LodHistoryEntry, scene.nodes.len);
    }
    uint* cursor = &histories.first;
    while (*cursor) {
        LodHistoryEntry* entry = &histories.entries[*cursor - 1];
        if (renderer.frame_index - entry.last_seen > INSTANCE_ABSENCE_FRAMES) {
            if (entry.allocation.is_valid()) renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = entry.allocation });
            *cursor = entry.next;
            *entry = {};
        } else {
            cursor = &entry.next;
        }
    }
    if (!scene.count(LodGroup)) return {};
    LodSelection[] selections = alloc::new_array(tmem, LodSelection, scene.count(LodGroup));
    usz count;
    scene.@each(LodGroup; Entity entity, LodGroup* group) {
        Node* node = scene.node(entity);
        bool source_live = true;
        if (group.state.animated) {
            if (catch excuse = model::sync_animated_lod(renderer.assets, scene, node)) {
                renderer.stats.dangling_refs++;
                source_live = false;
            }
        }

        if (source_live && node.visible_effective && group.state.count) {
            if (!spatial::lod_group_is_live(renderer.assets, group)) {
                renderer.stats.dangling_refs++;
            } else {
                if (group.state.has_impostor && !lod_impostor_live(renderer.assets, group.state)) renderer.stats.impostor_fallbacks++;
                LodHistoryEntry* history = &histories.entries[entity.index];
                if (!history.listed) {
                    history.next = histories.first;
                    history.listed = true;
                    histories.first = entity.index + 1;
                }
                history.last_seen = renderer.frame_index;
                LodSelection* selection = &selections[count++];
                if (group.state.mode == LodMode.INSTANCED) {
                    *selection = {
                        .scene = scene,
                        .scene_identity = scene.identity,
                        .node = node,
                        .state = group.state,
                        .world_bounds = spatial::lod_world_bounds(
                            assets: renderer.assets,
                            node: node,
                            group: group,
                            origin: renderer.frame_origin,
                            scene: scene,
                        ),
                        .history = history,
                        .camera = camera,
                        .camera_position = matrices.position,
                        .bias = record.desc.lod_bias,
                        .impostor = lod_impostor_live(renderer.assets, group.state),
                    };
                    prepare_lod_instances(renderer, selection)!;
                } else {
                    if (history.allocation.is_valid()) {
                        renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = history.allocation });
                        history.allocation = {};
                        history.capacity = 0;
                        history.committed.valid = false;
                    }
                    *selection = select_lod_group(
                        history: history,
                        scene: scene,
                        assets: renderer.assets,
                        node: node,
                        state: group.state,
                        camera: camera,
                        camera_position: matrices.position,
                        bias: record.desc.lod_bias,
                        origin: renderer.frame_origin,
                    );
                    selection.history = history;
                    renderer.stats.lod_objects_selected[selection.level]++;
                }
                bool temporal = record.desc.post.anti_aliasing == AntiAliasing.TAA
                  || record.desc.post.motion_blur || record.desc.screen_space_gi.enabled;
                selection.view_history_valid = temporal && record.history.has_previous(scene, node);
                selection.previous_view_origin = temporal && record.history.valid
                  ? record.history.origin : renderer.frame_origin;
                history.pending.origin = renderer.frame_origin;
                history.pending_sway = pack_sway(
                    sway:        group.state.effects.sway,
                    time:        renderer.info.time,
                    origin:      renderer.frame_origin,
                    world_shift: scene.world_shift,
                );
                history.pending.camera = {
                    matrices.position.x, matrices.position.y, matrices.position.z,
                    camera.projection == Projection.ORTHOGRAPHIC ? 1 : 0,
                };
                history.pending.direction = {
                    matrices.view.m20, matrices.view.m21, matrices.view.m22, 0,
                };
                selection.pose_history = &record.history;
                selection.parts = alloc::new_array(tmem, gpu::GpuAddress, group.state.desc.parts.len + 1);
            }
        }
    };
    return selections[:count];
}

fn void publish_lod_history(LodHistory* history) @private {
    for (uint cursor = history.first; cursor; cursor = history.entries[cursor - 1].next) {
        LodHistoryEntry* entry = &history.entries[cursor - 1];
        if (!entry.dirty) continue;
        entry.committed = entry.pending;
        entry.instance_epoch = entry.pending_epoch;
        if (entry.allocation.is_valid()) entry.committed_slot ^= 1;
        entry.sway = entry.pending_sway;
        entry.dirty = false;
    }
}

fn void discard_lod_history(LodHistory* history) @private {
    for (uint cursor = history.first; cursor; cursor = history.entries[cursor - 1].next) {
        history.entries[cursor - 1].dirty = false;
    }
}

fn void reset_lod_history(LodHistory* history) @private {
    for (uint cursor = history.first; cursor; cursor = history.entries[cursor - 1].next) {
        LodHistoryEntry* entry = &history.entries[cursor - 1];
        entry.committed.valid = false;
        entry.dirty = false;
    }
}

fn Mat4 candidate_world(MeshCandidate* candidate) @private {
    if (!candidate.lod || candidate.impostor || candidate.animated_lod) return candidate.node.world;
    return candidate.node.world.mul(candidate.lod.state.desc.parts[candidate.lod_part].local);
}

fn bool candidate_instanced(MeshCandidate* candidate) @private {
    return candidate.batch || candidate.billboards || (candidate.lod && candidate.lod.state.mode == LodMode.INSTANCED);
}

fn void retire_lod_history(Renderer* renderer, LodHistory* history) @private {
    for (uint cursor = history.first; cursor; cursor = history.entries[cursor - 1].next) {
        LodHistoryEntry* entry = &history.entries[cursor - 1];
        if (entry.allocation.is_valid()) renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = entry.allocation });
    }
    alloc::free(renderer.allocator, history.entries.ptr);
    *history = {};
}

fn void free_lod_history(Renderer* renderer, LodHistory* history) @private {
    for (uint cursor = history.first; cursor; cursor = history.entries[cursor - 1].next) {
        LodHistoryEntry* entry = &history.entries[cursor - 1];
        if (entry.allocation.is_valid()) (void)gpu::free_allocation(&renderer.device, &entry.allocation);
    }
    alloc::free(renderer.allocator, history.entries.ptr);
    *history = {};
}

fn gpu::GpuAddress? resolve_lod_part(Renderer* renderer, MeshCandidate* candidate) @private {
    if (!candidate.lod) return (gpu::GpuAddress)0;
    LodSelection* selection = candidate.lod;
    gpu::GpuAddress* address = &selection.parts[candidate.lod_part];
    if (*address != (gpu::GpuAddress)0) return *address;
    Mat4 local = candidate.impostor || candidate.animated_lod ? matrix::IDENTITY4
      : selection.state.desc.parts[candidate.lod_part].local;
    Mat3 normal = maths::normal_matrix(local);
    Vec3 history_delta = selection.history.committed.origin - selection.previous_view_origin;
    Vec3 current_delta = renderer.frame_origin - selection.previous_view_origin;
    LodPartGpu part = {
        .local = bitcast(local, Mat4f),
        .normal_0 = { normal.m00, normal.m10, normal.m20, 0 },
        .normal_1 = { normal.m01, normal.m11, normal.m21, 0 },
        .normal_2 = { normal.m02, normal.m12, normal.m22, 0 },
        .current = selection.current,
        .previous = selection.previous,
        .reject_history = selection.reject_history || !selection.view_history_valid
          || (candidate.animated_lod && !selection.pose_history.previous_candidate_pose(
              scene: selection.scene,
              assets: renderer.assets,
              candidate: candidate,
          )) ? 1 : 0,
        .seed = instance_seed({}),
        .impostor = candidate.impostor ? resolve_impostor(renderer, selection)! : (gpu::GpuAddress)0,
        .history_origin_delta = { history_delta.x, history_delta.y, history_delta.z, 0 },
        .current_origin_delta = { current_delta.x, current_delta.y, current_delta.z, 0 },
        .part_instances = candidate.animated_lod ? resolve_animated_lod_parts(renderer, candidate)! : (gpu::GpuAddress)0,
        .history_levels = candidate.animated_lod ? animated_lod_history_levels(candidate) : 0,
    };
    *address = upload_bytes(renderer, &part, LodPartGpu::size)!;
    return *address;
}

fn bool lod_impostor_live(AssetStore* assets, LodGroupState* state) @private {
    if (!state.has_impostor || !assets.textures.is_live(state.impostor.atlas)) return false;
    material::TextureDesc* desc = &assets.texture(state.impostor.atlas).desc;
    uint width = state.impostor.frames_per_side * state.impostor.cell_size;
    return desc.format == material::PixelFormat.RGBA8_UNORM && desc.width == width && desc.height == width * 2
      && desc.layers == 1 && desc.depth <= 1 && !desc.is_cube && desc.mip_levels == 1 && !desc.generate_mips;
}

fn uint fill_lod_thresholds(LodGroupState* state, bool impostor, float[] thresholds) @private {
    uint count = (uint)state.desc.levels.len;
    foreach (index, level : state.desc.levels) thresholds[index] = level.min_screen_size;
    if (impostor) {
        thresholds[count - 1] = state.impostor_min_screen_size;
        thresholds[count++] = 0;
    }
    return count;
}

fn LodLevel selected_lod_level(LodSelection* selection, uint index) @private {
    if (index < selection.state.desc.levels.len) return selection.state.desc.levels[index];
    return { .first_part = (uint)selection.state.desc.parts.len, .part_count = 1 };
}
