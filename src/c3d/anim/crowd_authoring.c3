module c3d::anim;

import c3d;
import c3d::asset;
import c3d::scene;
import c3d::maths;
import std::math;

<* Authored group coordinate domain. *>
enum AnimationSpaceKind {
    ONE_DIMENSIONAL,
    TWO_DIMENSIONAL,
}

<* Restartable action configuration with copied template-node mask membership. *>
struct CrowdActionAuthoring {
    ClipId clip;
    float speed;
    float weight;
    uint layer;
    bool additive;
    bool loop;
    bool playing;
    bool[] mask;
    RootMotion root_motion;
    bool root_yaw;
    float[] weighted_mask;
    AdditiveScaleMode additive_scale;
}

<* Restartable space configuration referring to ordered action ordinals. *>
struct CrowdSpaceAuthoring {
    uint[] actions;
    float[] positions;
    float parameter;
    float weight;
    float speed;
    bool playing;
    AnimationSpaceKind kind;
    Vec2[] points;
    BlendTriangle[] triangles;
    Vec2 parameter_2d;
}

<*
 Explicit configuration preserves empty playback instead of replaying a seed.
 base_action names a standalone action ordinal, or uint::max for none.
*>
struct CrowdInstanceAuthoring {
    bool configured;
    uint root_node;
    uint base_action;
    CrowdActionAuthoring[] actions;
    CrowdSpaceAuthoring[] spaces;
}

<* Owns copied pending instance descriptions independently of a serializer. *>
struct CrowdAuthoringState {
    Allocator allocator;
    CrowdInstanceAuthoring[] instances;
}

<*
 Copy descriptions and every nested mask and space array.
 @param instances : "Borrowed only during this call."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn CrowdAuthoringState*? copy_crowd_authoring(Allocator allocator, CrowdInstanceAuthoring[] instances) {
    CrowdAuthoringState* state = alloc::new_try(allocator, CrowdAuthoringState)
      ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch destroy_crowd_authoring(state);

    state.allocator = allocator;
    state.instances = alloc::new_array_try(allocator, CrowdInstanceAuthoring, instances.len)
      ?? c3d::CAPACITY_EXCEEDED~!;

    foreach (index, source : instances) {
        copy_crowd_instance(allocator, source, &state.instances[index])!;
    }

    return state;
}

<* Free a copied or captured description and every nested array once.
 @param [&inout] state : "Owned description; released by this call."
*>
fn void destroy_crowd_authoring(CrowdAuthoringState* state) {
    Allocator allocator = state.allocator;
    foreach (instance : state.instances) {
        foreach (action : instance.actions) {
            alloc::free(allocator, action.mask.ptr);
            alloc::free(allocator, action.weighted_mask.ptr);
        }
        foreach (space : instance.spaces) {
            alloc::free(allocator, space.actions.ptr);
            alloc::free(allocator, space.positions.ptr);
            alloc::free(allocator, space.points.ptr);
            alloc::free(allocator, space.triangles.ptr);
        }

        alloc::free(allocator, instance.actions.ptr);
        alloc::free(allocator, instance.spaces.ptr);
    }

    alloc::free(allocator, state.instances.ptr);
    alloc::free(allocator, state);
}

<*
 Validate explicit configuration through ordinary playback admission.
 @param [&in] assets : "Owns every referenced compatible clip."
 @param [&in] template : "Validated model nodes, meshes and logical defaults."
 @param placement : "Instance scale used for root-motion admission."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require actions_per_instance > 0 && actions_per_instance <= MAX_ACTIONS
*>
fn void? validate_crowd_authoring(
    AssetStore* assets,
    ModelTemplate* template,
    CrowdInstanceAuthoring source,
    uint actions_per_instance,
    Transform placement = maths::TRANSFORM_IDENTITY,
    ModelId model = {},
) {
    check_crowd_instance(source, template.nodes.len, actions_per_instance)!;
    if (!source.configured) return;

    @pool() {
        Transform[1] placements = { placement };
        CrowdPlaybackState* state = create_crowd_playback(
            allocator: tmem,
            template: template,
            placements: placements[..],
            actions_per_instance: actions_per_instance,
            event_capacity: 0,
        )!;
        defer destroy_crowd_playback(state);

        state.count = 1;
        state.model = model;

        restore_crowd_authoring(
            state: state,
            index: 0,
            assets: assets,
            source: source,
            base_start: 0,
        )!;
    };
}

<*
 Restore explicit configuration into a newly allocated empty slot.
 @param [&inout] state : "Receives the configured slot."
 @param [&in] assets : "Owns every referenced compatible clip."
 @param base_start : "Captured authoring start of the retained base action."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require index < state.count, state.slots[index].action_count == 0
 @require source.configured
*>
fn void? restore_crowd_authoring(
    CrowdPlaybackState* state,
    uint index,
    AssetStore* assets,
    CrowdInstanceAuthoring source,
    float base_start,
) {
    check_crowd_instance(source, state.base_pose.len, state.slots[index].actions.items.len)!;
    if (!math::is_finite(base_start)) return c3d::INVALID_ARGUMENT~;

    CrowdPlaybackSlot* slot = &state.slots[index];
    slot.root_node = source.root_node;
    PlaybackView playback = crowd_playback_view(state, slot);
    AnimationActionId base = restore_playback_authoring(
        playback: &playback,
        assets: assets,
        source: source,
        destination: crowd_destination(state, index),
        motion_basis: crowd_motion_basis(state, index, source.root_node),
    )!;

    if (source.base_action != uint::max) {
        slot.base_action = base;
        slot.actions.get(base).time = base_start;
    }
}

fn AnimationActionId? restore_playback_authoring(
    PlaybackView* playback,
    AssetStore* assets,
    CrowdInstanceAuthoring source,
    PoseDestination destination,
    MotionBasis motion_basis,
) @private {
    check_crowd_instance(source, destination.base_pose.len, playback.actions.items.len)!;

    foreach (space : source.spaces) {
        foreach (ordinal : space.actions) {
            float duration = assets.clips.try_get(source.actions[ordinal].clip)!.data.duration;
            if (!math::is_finite(duration) || duration <= 0) return c3d::INVALID_ARGUMENT~;
        }
    }

    @pool() {
        WeightedJointMask weighted = { .model = playback.model };
        bool has_weighted;
        foreach (action : source.actions) has_weighted |= action.weighted_mask.len != 0;
        if (has_weighted) {
            ModelTemplate* template = &assets.models.try_get(playback.model)!.data;
            weighted.model_names = alloc::new_array_try(tmem, String, template.nodes.len)
              ?? c3d::CAPACITY_EXCEEDED~!;
            weighted.model_parents = alloc::new_array_try(tmem, int, template.nodes.len)
              ?? c3d::CAPACITY_EXCEEDED~!;

            foreach (index, node : template.nodes) {
                weighted.model_names[index] = node.name;
                weighted.model_parents[index] = node.parent;
            }
        }

        AnimationActionId[MAX_ACTIONS] ids;
        foreach (ordinal, action : source.actions) {
            JointMask boolean = { .nodes = action.mask };
            weighted.nodes = action.weighted_mask;
            PlayDesc desc = {
                .layer = action.layer,
                .additive = action.additive,
                .mask = action.weighted_mask.len ? null : &boolean,
                .weighted_mask = action.weighted_mask.len ? &weighted : null,
                .additive_scale = action.additive_scale,
                .root_motion = action.root_motion,
                .root_yaw = action.root_yaw,
            };
            ids[ordinal] = playback.play(
                assets: assets,
                clip: action.clip,
                desc: desc,
                destination: destination,
                motion_basis: motion_basis,
            )!;
            Action* restored = playback.action(ids[ordinal]);
            restored.speed = action.speed;
            restored.weight = action.weight;
            restored.fade_target = action.weight == 0 ? 1 : action.weight;
            restored.loop = action.loop;
            restored.playing = action.playing;
        }

        foreach (ordinal, space : source.spaces) {
            if (space.kind == TWO_DIMENSIONAL) {
                restore_authored_space_2d(playback, (uint)ordinal, space)!;
            } else {
                playback.blend_spaces[ordinal] = {
                    .count = (uint)space.actions.len,
                    .parameter = space.parameter,
                    .weight = space.weight,
                    .fade_target = space.weight == 0 ? 1 : space.weight,
                    .speed = space.speed,
                    .playing = space.playing,
                };
                playback.blend_spaces[ordinal].positions[:space.positions.len] = space.positions[..];
            }

            foreach (member, action_ordinal : space.actions) {
                AnimationActionId id = ids[action_ordinal];
                if (space.kind == TWO_DIMENSIONAL) {
                    playback.blend_spaces_2d[ordinal].actions[member] = id;
                } else {
                    playback.blend_spaces[ordinal].actions[member] = id;
                }

                Action* action = playback.action(id);
                action.blend_space = (uint)ordinal + 1;
                action.weight = 0;
                action.playing = false;
            }
        }

        return source.base_action == uint::max ? (AnimationActionId){} : ids[source.base_action];
    };
}

fn void? restore_authored_space_2d(PlaybackView* playback, uint ordinal, CrowdSpaceAuthoring source) @local {
    BlendSpace2D* destination = &playback.blend_spaces_2d[ordinal];
    BlendLayoutInfo layout = prepare_blend_layout(
        points: source.points,
        triangles: source.triangles,
        capacity: (uint)playback.actions.items.len,
        prepared_triangles: destination.triangles,
        prepared_hull: destination.hull,
    )!;

    destination.count = (uint)source.actions.len;
    destination.triangle_count = layout.triangle_count;
    destination.hull_count = layout.hull_count;
    destination.reversed = layout.reversed;
    destination.extent = layout.extent;
    destination.points[:source.points.len] = source.points[..];
    destination.parameter = source.parameter_2d;
    destination.weight = source.weight;
    destination.fade_target = source.weight == 0 ? 1 : source.weight;
    destination.speed = source.speed;
    destination.playing = source.playing;
}

<*
 Capture restartable configuration without changing live playback.
 @param [&in] playback : "Supplies live action order, masks and spaces."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn CrowdAuthoringState*? capture_crowd_authoring(Allocator allocator, CrowdPlaybackState* playback) {
    CrowdAuthoringState* state = alloc::new_try(allocator, CrowdAuthoringState)
      ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch destroy_crowd_authoring(state);

    state.allocator = allocator;
    state.instances = alloc::new_array_try(allocator, CrowdInstanceAuthoring, playback.count)
      ?? c3d::CAPACITY_EXCEEDED~!;

    foreach (index, &instance : state.instances) {
        PlaybackView view = crowd_playback_view(playback, &playback.slots[index]);
        *instance = capture_playback_authoring(allocator, &view, playback.slots[index].base_action)!;
    }

    return state;
}

fn void? copy_crowd_instance(
    Allocator allocator,
    CrowdInstanceAuthoring source,
    CrowdInstanceAuthoring* destination,
) @local {
    *destination = {
        .configured = source.configured,
        .root_node = source.root_node,
        .base_action = source.base_action,
    };

    destination.actions = alloc::new_array_try(allocator, CrowdActionAuthoring, source.actions.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    destination.spaces = alloc::new_array_try(allocator, CrowdSpaceAuthoring, source.spaces.len)
      ?? c3d::CAPACITY_EXCEEDED~!;

    foreach (index, action : source.actions) {
        destination.actions[index] = action;
        destination.actions[index].mask = {};
        destination.actions[index].weighted_mask = {};

        destination.actions[index].mask = alloc::new_array_try(allocator, bool, action.mask.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        destination.actions[index].mask[..] = action.mask[..];

        destination.actions[index].weighted_mask = alloc::new_array_try(allocator, float, action.weighted_mask.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        destination.actions[index].weighted_mask[..] = action.weighted_mask[..];
    }

    foreach (index, space : source.spaces) {
        destination.spaces[index] = space;
        destination.spaces[index].actions = {};
        destination.spaces[index].positions = {};
        destination.spaces[index].points = {};
        destination.spaces[index].triangles = {};

        destination.spaces[index].actions = alloc::new_array_try(allocator, uint, space.actions.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        destination.spaces[index].positions = alloc::new_array_try(allocator, float, space.positions.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        destination.spaces[index].actions[..] = space.actions[..];
        destination.spaces[index].positions[..] = space.positions[..];

        destination.spaces[index].points = alloc::new_array_try(allocator, Vec2, space.points.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        destination.spaces[index].triangles = alloc::new_array_try(allocator, BlendTriangle, space.triangles.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        destination.spaces[index].points[..] = space.points[..];
        destination.spaces[index].triangles[..] = space.triangles[..];
    }
}

fn void? check_crowd_instance(
    CrowdInstanceAuthoring source,
    usz node_count,
    usz action_capacity,
) @private {
    if (!source.configured) {
        if (source.actions.len || source.spaces.len) return c3d::INVALID_ARGUMENT~;
        return;
    }

    if (source.actions.len > action_capacity || source.spaces.len > MAX_BLEND_SPACES) {
        return c3d::CAPACITY_EXCEEDED~;
    }
    if ((source.root_node != NO_ROOT_NODE && source.root_node >= node_count)
      || (source.base_action != uint::max && source.base_action >= source.actions.len)) {
        return c3d::INVALID_ARGUMENT~;
    }

    foreach (action : source.actions) {
        if (!math::is_finite(action.speed) || !math::is_finite(action.weight) || action.weight < 0
          || (action.weighted_mask.len ? action.mask.len != 0 || action.weighted_mask.len != node_count
            : action.mask.len != node_count)) return c3d::INVALID_ARGUMENT~;

        foreach (weight : action.weighted_mask) {
            if (!math::is_finite(weight) || weight < 0 || weight > 1) return c3d::INVALID_ARGUMENT~;
        }
    }

    bool[MAX_ACTIONS] grouped;
    foreach (space : source.spaces) {
        if (!math::is_finite(space.speed) || !math::is_finite(space.weight) || space.weight < 0) {
            return c3d::INVALID_ARGUMENT~;
        }

        switch (space.kind) {
            case ONE_DIMENSIONAL:
                if (!math::is_finite(space.parameter) || space.actions.len < 2
                  || space.actions.len > MAX_BLEND_SPACE_ACTIONS || space.positions.len != space.actions.len
                  || space.points.len || space.triangles.len || space.parameter_2d != (Vec2){}) {
                    return c3d::INVALID_ARGUMENT~;
                }

                foreach (index, position : space.positions) {
                    if (!math::is_finite(position) || (index && position <= space.positions[index - 1])) {
                        return c3d::INVALID_ARGUMENT~;
                    }
                }
            case TWO_DIMENSIONAL:
                if (!math::is_finite(space.parameter_2d.x) || !math::is_finite(space.parameter_2d.y)
                  || space.actions.len > action_capacity || space.points.len != space.actions.len
                  || space.positions.len || space.parameter != 0) return c3d::INVALID_ARGUMENT~;

                BlendTriangleIndices[2 * MAX_ACTIONS - 5] triangles;
                BlendHullIndices[MAX_ACTIONS] hull;
                (void)prepare_blend_layout(
                    points: space.points,
                    triangles: space.triangles,
                    capacity: (uint)action_capacity,
                    prepared_triangles: triangles[..],
                    prepared_hull: hull[..],
                )!;
        }

        foreach (action : space.actions) {
            if (action >= source.actions.len || grouped[action] || action == source.base_action) {
                return c3d::INVALID_ARGUMENT~;
            }
            grouped[action] = true;
        }
    }
}

fn CrowdInstanceAuthoring? capture_playback_authoring(
    Allocator allocator,
    PlaybackView* playback,
    AnimationActionId base_action = {},
) @private {
    CrowdInstanceAuthoring result;
    defer catch free_authored_instance(allocator, &result);

    CrowdInstanceAuthoring* destination = &result;
    *destination = {
        .configured = true,
        .root_node = playback.root_node,
        .base_action = uint::max,
    };
    destination.actions = alloc::new_array_try(allocator, CrowdActionAuthoring, *playback.action_count)
      ?? c3d::CAPACITY_EXCEEDED~!;

    bool[MAX_BLEND_SPACES] retained_spaces;
    uint space_count;
    foreach (index, space : playback.blend_spaces) {
        BlendSpace2D* planar = &playback.blend_spaces_2d[index];
        retained_spaces[index] = (space.count != 0 && !(space.fade_rate > 0 && space.fade_target == 0))
          || (planar.count != 0 && !(planar.fade_rate > 0 && planar.fade_target == 0));
        if (retained_spaces[index]) space_count++;
    }

    destination.spaces = alloc::new_array_try(allocator, CrowdSpaceAuthoring, space_count)
      ?? c3d::CAPACITY_EXCEEDED~!;

    uint[MAX_ACTIONS] mapping;
    mapping[..] = uint::max;
    uint action_count;

    foreach (index, id : playback.order[:*playback.action_count]) {
        Action* action = playback.actions.get(id);
        if (action.blend_space) {
            if (!retained_spaces[action.blend_space - 1]) continue;
        } else if (action.fade_rate > 0 && action.fade_target == 0) {
            continue;
        }

        mapping[index] = action_count;
        CrowdActionAuthoring* captured = &destination.actions[action_count];

        *captured = {
            .clip = action.clip,
            .speed = action.speed,
            .weight = action.blend_space ? 0 : (action.fade_rate > 0 ? action.fade_target : action.weight),
            .layer = action.layer,
            .additive = action.additive,
            .loop = action.loop,
            .playing = action.blend_space ? false : action.playing,
            .root_motion = action.root_motion,
            .root_yaw = action.root_yaw,
            .additive_scale = action.additive_scale,
        };

        if (action.weighted_mask.len) {
            captured.weighted_mask = alloc::new_array_try(allocator, float, action.weighted_mask.len)
              ?? c3d::CAPACITY_EXCEEDED~!;
            captured.weighted_mask[..] = action.weighted_mask[..];
        } else {
            captured.mask = alloc::new_array_try(allocator, bool, action.mask.len)
              ?? c3d::CAPACITY_EXCEEDED~!;
            captured.mask[..] = action.mask[..];
        }

        if (c3d::same_id(base_action, id)) destination.base_action = action_count;

        action_count++;
    }

    uint space_index;
    foreach (index, space : playback.blend_spaces) {
        if (!retained_spaces[index]) continue;

        CrowdSpaceAuthoring* captured = &destination.spaces[space_index++];
        BlendSpace2D* planar = &playback.blend_spaces_2d[index];
        uint count = planar.count ? planar.count : space.count;
        *captured = {
            .parameter = planar.count ? 0 : space.parameter,
            .weight = planar.count
              ? (planar.fade_rate > 0 ? planar.fade_target : planar.weight)
              : (space.fade_rate > 0 ? space.fade_target : space.weight),
            .speed = planar.count ? planar.speed : space.speed,
            .playing = planar.count ? planar.playing : space.playing,
            .kind = planar.count ? TWO_DIMENSIONAL : ONE_DIMENSIONAL,
            .parameter_2d = planar.count ? planar.parameter : (Vec2){},
        };
        captured.actions = alloc::new_array_try(allocator, uint, count)
          ?? c3d::CAPACITY_EXCEEDED~!;

        if (planar.count) {
            captured.points = alloc::new_array_try(allocator, Vec2, count) ?? c3d::CAPACITY_EXCEEDED~!;
            captured.points[..] = planar.points[:count];
            captured.triangles = alloc::new_array_try(allocator, BlendTriangle, planar.triangle_count)
              ?? c3d::CAPACITY_EXCEEDED~!;

            foreach (triangle, &authored : captured.triangles) {
                BlendTriangleIndices stored = planar.triangles[triangle];
                bool reversed = (planar.reversed & (1u << triangle)) != 0;
                authored.indices = {
                    stored.indices[0],
                    stored.indices[reversed ? 2 : 1],
                    stored.indices[reversed ? 1 : 2],
                };
            }
        } else {
            captured.positions = alloc::new_array_try(allocator, float, count) ?? c3d::CAPACITY_EXCEEDED~!;
            captured.positions[..] = space.positions[:count];
        }

        for (uint member = 0; member < count; member++) {
            AnimationActionId id = planar.count ? planar.actions[member] : space.actions[member];
            bool found;
            foreach (ordered, candidate : playback.order[:*playback.action_count]) {
                if (c3d::same_id(candidate, id)) {
                    if (mapping[ordered] == uint::max) return c3d::INVALID_ARGUMENT~;
                    captured.actions[member] = mapping[ordered];
                    found = true;
                    break;
                }
            }

            if (!found) return c3d::INVALID_ARGUMENT~;
        }
    }

    destination.actions = destination.actions[:action_count];
    return result;
}

fn void free_authored_instance(Allocator allocator, CrowdInstanceAuthoring* instance) @local {
    foreach (action : instance.actions) {
        alloc::free(allocator, action.mask.ptr);
        alloc::free(allocator, action.weighted_mask.ptr);
    }

    foreach (space : instance.spaces) {
        alloc::free(allocator, space.actions.ptr);
        alloc::free(allocator, space.positions.ptr);
        alloc::free(allocator, space.points.ptr);
        alloc::free(allocator, space.triangles.ptr);
    }

    alloc::free(allocator, instance.actions.ptr);
    alloc::free(allocator, instance.spaces.ptr);
}
