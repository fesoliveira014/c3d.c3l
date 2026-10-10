module c3d::anim;

import c3d;
import c3d::asset;
import c3d::scene;
import c3d::maths;
import std::math;

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
}

<* Restartable space configuration referring to ordered action ordinals. *>
struct CrowdSpaceAuthoring {
    uint[] actions;
    float[] positions;
    float parameter;
    float weight;
    float speed;
    bool playing;
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
        foreach (action : instance.actions) alloc::free(allocator, action.mask.ptr);
        foreach (space : instance.spaces) {
            alloc::free(allocator, space.actions.ptr);
            alloc::free(allocator, space.positions.ptr);
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

    foreach (space : source.spaces) {
        foreach (ordinal : space.actions) {
            float duration = assets.clips.try_get(source.actions[ordinal].clip)!.data.duration;
            if (!math::is_finite(duration) || duration <= 0) return c3d::INVALID_ARGUMENT~;
        }
    }

    CrowdPlaybackSlot* slot = &state.slots[index];
    slot.root_node = source.root_node;
    CrowdPlayer player = state.player(state.instance_id(index)!)!;
    AnimationActionId[MAX_ACTIONS] ids;

    foreach (ordinal, action : source.actions) {
        JointMask mask = { .nodes = action.mask };
        ids[ordinal] = player.play(assets, action.clip, {
            .layer = action.layer,
            .additive = action.additive,
            .mask = &mask,
            .root_motion = action.root_motion,
            .root_yaw = action.root_yaw,
        })!;
        Action* restored = player.action(ids[ordinal]);
        restored.speed = action.speed;
        restored.weight = action.weight;
        restored.fade_target = action.weight == 0 ? 1 : action.weight;
        restored.loop = action.loop;
        restored.playing = action.playing;
    }

    foreach (ordinal, space : source.spaces) {
        BlendSpace1D restored = {
            .count = (uint)space.actions.len,
            .parameter = space.parameter,
            .weight = space.weight,
            .fade_target = space.weight == 0 ? 1 : space.weight,
            .speed = space.speed,
            .playing = space.playing,
        };
        foreach (member, action_ordinal : space.actions) {
            AnimationActionId id = ids[action_ordinal];
            restored.actions[member] = id;
            restored.positions[member] = space.positions[member];
            Action* action = player.action(id);
            action.blend_space = (uint)ordinal + 1;
            action.weight = 0;
            action.playing = false;
        }

        slot.spaces[ordinal] = restored;
    }

    if (source.base_action != uint::max) {
        slot.base_action = ids[source.base_action];
        player.action(slot.base_action).time = base_start;
    }
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
        capture_crowd_instance(allocator, &playback.slots[index], instance)!;
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
        destination.actions[index].mask = alloc::new_array_try(allocator, bool, action.mask.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        destination.actions[index].mask[..] = action.mask[..];
    }

    foreach (index, space : source.spaces) {
        destination.spaces[index] = space;
        destination.spaces[index].actions = {};
        destination.spaces[index].positions = {};
        destination.spaces[index].actions = alloc::new_array_try(allocator, uint, space.actions.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        destination.spaces[index].positions = alloc::new_array_try(allocator, float, space.positions.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        destination.spaces[index].actions[..] = space.actions[..];
        destination.spaces[index].positions[..] = space.positions[..];
    }
}

fn void? check_crowd_instance(
    CrowdInstanceAuthoring source,
    usz node_count,
    usz action_capacity,
) @local {
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
          || action.mask.len != node_count) return c3d::INVALID_ARGUMENT~;
    }

    bool[MAX_ACTIONS] grouped;
    foreach (space : source.spaces) {
        if (!math::is_finite(space.parameter) || !math::is_finite(space.speed)
          || !math::is_finite(space.weight) || space.weight < 0
          || space.actions.len < 2 || space.actions.len > MAX_BLEND_SPACE_ACTIONS
          || space.positions.len != space.actions.len) return c3d::INVALID_ARGUMENT~;

        foreach (index, action : space.actions) {
            if (action >= source.actions.len || grouped[action] || action == source.base_action) {
                return c3d::INVALID_ARGUMENT~;
            }
            grouped[action] = true;
            if (!math::is_finite(space.positions[index])
              || (index && space.positions[index] <= space.positions[index - 1])) {
                return c3d::INVALID_ARGUMENT~;
            }
        }
    }
}

fn void? capture_crowd_instance(
    Allocator allocator,
    CrowdPlaybackSlot* slot,
    CrowdInstanceAuthoring* destination,
) @local {
    *destination = {
        .configured = true,
        .root_node = slot.root_node,
        .base_action = uint::max,
    };
    destination.actions = alloc::new_array_try(allocator, CrowdActionAuthoring, slot.action_count)
      ?? c3d::CAPACITY_EXCEEDED~!;
    bool[MAX_BLEND_SPACES] retained_spaces;
    uint space_count;
    foreach (index, space : slot.spaces) {
        retained_spaces[index] = space.count != 0 && !(space.fade_rate > 0 && space.fade_target == 0);
        if (retained_spaces[index]) space_count++;
    }

    destination.spaces = alloc::new_array_try(allocator, CrowdSpaceAuthoring, space_count)
      ?? c3d::CAPACITY_EXCEEDED~!;
    uint[MAX_ACTIONS] mapping;
    mapping[..] = uint::max;
    uint action_count;

    foreach (index, id : slot.order[:slot.action_count]) {
        Action* action = slot.actions.get(id);
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
        };
        captured.mask = alloc::new_array_try(allocator, bool, action.mask.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        captured.mask[..] = action.mask[..];
        if (c3d::same_id(slot.base_action, id)) destination.base_action = action_count;
        action_count++;
    }

    uint space_index;
    foreach (index, space : slot.spaces) {
        if (!retained_spaces[index]) continue;

        CrowdSpaceAuthoring* captured = &destination.spaces[space_index++];
        *captured = {
            .parameter = space.parameter,
            .weight = space.fade_rate > 0 ? space.fade_target : space.weight,
            .speed = space.speed,
            .playing = space.playing,
        };
        captured.actions = alloc::new_array_try(allocator, uint, space.count)
          ?? c3d::CAPACITY_EXCEEDED~!;
        captured.positions = alloc::new_array_try(allocator, float, space.count)
          ?? c3d::CAPACITY_EXCEEDED~!;

        foreach (member, id : space.actions[:space.count]) {
            bool found;
            foreach (ordered, candidate : slot.order[:slot.action_count]) {
                if (c3d::same_id(candidate, id)) {
                    if (mapping[ordered] == uint::max) return c3d::INVALID_ARGUMENT~;
                    captured.actions[member] = mapping[ordered];
                    found = true;
                    break;
                }
            }

            if (!found) return c3d::INVALID_ARGUMENT~;
            captured.positions[member] = space.positions[member];
        }
    }

    destination.actions = destination.actions[:action_count];
}
