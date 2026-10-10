module c3d::serial;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::describe;
import c3d::scene;
import std::math;

const ulong ACTION_AUTHORING_LAYOUT @local = 0xaafb7d37846979a1;
const ulong SPACE_AUTHORING_LAYOUT @local = 0x89bbbea9c64ba2b7;
const ulong ANIMATOR_AUTHORING_LAYOUT @local = 0xa4a3c2515a5669b4;
const ulong ANIMATOR_AUTHORING_V2_LAYOUT @local = 0x11312a6330c08681;
const ulong ANIMATOR_AUTHORING_V3_LAYOUT @local = 0x40ad0981ac365801;

struct ActionAuthoring @private {
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

struct SpaceAuthoring @private {
    uint[] actions;
    float[] positions;
    float parameter;
    float weight;
    float speed;
    bool playing;
}

struct AnimatorAuthoring @private {
    uint root_node;
    ActionAuthoring[] actions;
    SpaceAuthoring[] spaces;
}

struct AnimatorAuthoringV2 @private {
    uint root_node;
    CrowdActionAuthoringV2[] actions;
    CrowdSpaceAuthoring[] spaces;
}

struct AnimatorAuthoringV3 @private {
    uint root_node;
    CrowdActionAuthoring[] actions;
    CrowdSpaceAuthoring[] spaces;
    bool inertia_enabled;
}

BinaryCompatibility[2] animator_binary_compatibility @local = {
    { .version = 1, .read = &read_animator_v1 },
    { .version = 2, .read = &read_animator_v2 },
};
uint[2] animator_text_default_versions @local = { 1, 2 };

fn void? register_animator_codec() @private {
    describe::register_reflected(ActionAuthoring)!;
    describe::register_reflected(SpaceAuthoring)!;
    describe::register_reflected(AnimatorAuthoring)!;
    register_core_value(ActionAuthoring, ACTION_AUTHORING_LAYOUT, &defaults_action)!;
    register_core_value(SpaceAuthoring, SPACE_AUTHORING_LAYOUT, &defaults_space)!;
    register_core_value(AnimatorAuthoring, ANIMATOR_AUTHORING_LAYOUT, &defaults_animator)!;

    register_animation_authoring_values()!;
    describe::register_reflected(AnimatorAuthoringV2)!;
    register_described_type(
        $Type: AnimatorAuthoringV2,
        version: 2,
        layout: ANIMATOR_AUTHORING_V2_LAYOUT,
        defaults: &defaults_animator_v2,
    )!;

    describe::register_reflected(AnimatorAuthoringV3)!;
    register_described_type(
        $Type: AnimatorAuthoringV3,
        version: 3,
        layout: ANIMATOR_AUTHORING_V3_LAYOUT,
        defaults: &defaults_animator_v3,
    )!;

    register_described_owner(Animator, AnimatorAuthoringV3, {
        .name = "c3d.Animator",
        .phase = OWNER,
        .collect = &collect_animator,
        .project = &project_animator,
        .validate = &validate_animator,
        .attach = &attach_animator,
        .binary_compatibility = animator_binary_compatibility[..],
        .text_default_versions = animator_text_default_versions[..],
    })!;
}

fn void defaults_action(void* value) @local {
    *(ActionAuthoring*)value = { .speed = 1, .weight = 1, .loop = true, .playing = true };
}

fn void defaults_space(void* value) @local {
    *(SpaceAuthoring*)value = { .speed = 1, .weight = 1, .playing = true };
}

fn void defaults_animator(void* value) @local {
    *(AnimatorAuthoring*)value = { .root_node = INDEX_NONE };
}

fn void defaults_animator_v2(void* value) @local {
    *(AnimatorAuthoringV2*)value = { .root_node = INDEX_NONE };
}

fn void defaults_animator_v3(void* value) @local {
    *(AnimatorAuthoringV3*)value = { .root_node = INDEX_NONE };
}

fn void? collect_animator(void* component, WriteContext* context) @local {
    ModelInstance* instance = context.scene.get(context.node, ModelInstance);
    if (!instance) return c3d::INVALID_ARGUMENT~;

    foreach (usz index, pose : instance.base_pose) {
        Node* node = instance.present_node(index);
        if (node) context.set_local(node, pose)!;
    }
}

fn void? project_animator(void* component, void* value, WriteContext* context) @local {
    Animator* animator = component;
    PlaybackView playback = animator.playback();
    CrowdInstanceAuthoring captured = anim::capture_playback_authoring(tmem, &playback)!;
    *(AnimatorAuthoringV3*)value = {
        .root_node = captured.root_node,
        .actions = captured.actions,
        .spaces = captured.spaces,
        .inertia_enabled = animator.inertial_storage != null,
    };
    check_animator_scalars((AnimatorAuthoringV3*)value)!;
}

fn void? validate_animator(void* value, ReadContext* context) @local {
    AnimatorAuthoringV3* source = value;
    check_animator_scalars(source)!;

    ModelAuthoring* model = context.authored(ModelInstance, ModelAuthoring, context.node.id)!;
    if (!model) return c3d::INVALID_ARGUMENT~;

    anim::check_crowd_instance(
        source: {
            .configured = true,
            .root_node = source.root_node,
            .base_action = uint::max,
            .actions = source.actions,
            .spaces = source.spaces,
        },
        node_count: model.nodes.len,
        action_capacity: anim::MAX_ACTIONS,
    )!;

    foreach (action : source.actions) {
        AnimationClip* clip = &context.assets.clips.try_get(action.clip)!.data;
        if (action.layer >= anim::MAX_ANIMATION_LAYERS
            || (action.root_yaw && action.root_motion == KEEP)
            || (action.additive && action.root_motion != KEEP)
            || (action.root_motion != KEEP && source.root_node >= model.nodes.len)) return c3d::INVALID_ARGUMENT~;

        foreach (target : clip.targets) if (target >= model.nodes.len) return c3d::INVALID_ARGUMENT~;

        foreach (track : clip.tracks) {
            if (track.path != MORPH_WEIGHTS) continue;

            uint target = clip.targets[track.target];
            bool mesh_target;
            foreach (mesh_node : model.mesh_nodes) mesh_target |= mesh_node == target;
            if (!mesh_target) return c3d::INVALID_ARGUMENT~;

            Entity node = model.nodes[target];
            if (!node.generation) continue;
            Mesh* mesh = context.authored(Mesh, Mesh, node)!;
            if (mesh && mesh.morph_weights.len != track.stride()) return c3d::INVALID_ARGUMENT~;
        }
    }

    foreach (space : source.spaces) {
        foreach (action : space.actions) {
            float duration = context.assets.clip(source.actions[action].clip).data.duration;
            if (!math::is_finite(duration) || duration <= 0) return c3d::INVALID_ARGUMENT~;
        }
    }
}

fn void? check_animator_scalars(AnimatorAuthoringV3* source) @local {
    foreach (action : source.actions) {
        if (!math::is_finite(action.speed) || !math::is_finite(action.weight) || action.weight < 0) {
            return c3d::INVALID_ARGUMENT~;
        }

        foreach (weight : action.weighted_mask) {
            if (!math::is_finite(weight) || weight < 0 || weight > 1) return c3d::INVALID_ARGUMENT~;
        }
    }

    foreach (space : source.spaces) {
        if (!math::is_finite(space.speed) || !math::is_finite(space.weight) || space.weight < 0
          || (space.kind == ONE_DIMENSIONAL && !math::is_finite(space.parameter))
          || (space.kind == TWO_DIMENSIONAL
            && (!math::is_finite(space.parameter_2d.x) || !math::is_finite(space.parameter_2d.y)))) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
}

fn void? attach_animator(void* value, ReadContext* context) @local {
    AnimatorAuthoringV3* source = value;
    Animator* animator = anim::add_animator(
        context.scene, context.node, { .inertia_enabled = source.inertia_enabled });
    defer catch context.scene.remove_component(context.node, Animator);

    animator.root_node = source.root_node;
    PlaybackView playback = animator.playback();
    anim::refresh_destination(animator);

    (void)anim::restore_playback_authoring(
        playback: &playback,
        assets: context.assets,
        source: {
            .configured = true,
            .root_node = source.root_node,
            .base_action = uint::max,
            .actions = source.actions,
            .spaces = source.spaces,
        },
        destination: animator.pose_storage.destination,
        motion_basis: anim::animator_motion_basis(animator),
    )!;
}

fn AnimatorAuthoringV3? migrate_animation_authoring(AnimatorAuthoring source) @private {
    AnimatorAuthoringV3 converted = {
        .root_node = source.root_node,
        .actions = alloc::new_array_try(tmem, CrowdActionAuthoring, source.actions.len)
          ?? c3d::CAPACITY_EXCEEDED~!,
        .spaces = alloc::new_array_try(tmem, CrowdSpaceAuthoring, source.spaces.len)
          ?? c3d::CAPACITY_EXCEEDED~!,
    };

    foreach (index, action : source.actions) {
        converted.actions[index] = {
            .clip = action.clip,
            .speed = action.speed,
            .weight = action.weight,
            .layer = action.layer,
            .additive = action.additive,
            .loop = action.loop,
            .playing = action.playing,
            .mask = action.mask,
            .root_motion = action.root_motion,
            .root_yaw = action.root_yaw,
        };
    }

    foreach (index, space : source.spaces) {
        converted.spaces[index] = {
            .actions = space.actions,
            .positions = space.positions,
            .parameter = space.parameter,
            .weight = space.weight,
            .speed = space.speed,
            .playing = space.playing,
        };
    }

    return converted;
}

fn void? read_animator_v1(Reader* reader, ReadContext* context) @local {
    AnimatorAuthoring legacy;
    Acquisitions owned = { .allocator = context.allocator };
    defer owned.release();

    read_described_value(
        type: described_type(AnimatorAuthoring)!,
        reader: reader,
        context: context,
        owned: &owned,
        value: &legacy,
    )!;

    AnimatorAuthoringV3 converted = migrate_animation_authoring(legacy)!;
    validate_animator(&converted, context)!;
    attach_animator(&converted, context)!;
}

fn AnimatorAuthoringV3? migrate_animation_authoring_v2(AnimatorAuthoringV2 source) @private {
    AnimatorAuthoringV3 converted = {
        .root_node = source.root_node,
        .actions = alloc::new_array_try(tmem, CrowdActionAuthoring, source.actions.len)
          ?? c3d::CAPACITY_EXCEEDED~!,
        .spaces = source.spaces,
    };

    foreach (index, action : source.actions) {
        converted.actions[index] = {
            .clip = action.clip,
            .speed = action.speed,
            .weight = action.weight,
            .layer = action.layer,
            .additive = action.additive,
            .loop = action.loop,
            .playing = action.playing,
            .mask = action.mask,
            .root_motion = action.root_motion,
            .root_yaw = action.root_yaw,
            .weighted_mask = action.weighted_mask,
            .additive_scale = action.additive_scale,
        };
    }

    return converted;
}

fn void? read_animator_v2(Reader* reader, ReadContext* context) @local {
    AnimatorAuthoringV2 legacy;
    Acquisitions owned = { .allocator = context.allocator };
    defer owned.release();

    read_described_value(
        type: described_type(AnimatorAuthoringV2)!,
        reader: reader,
        context: context,
        owned: &owned,
        value: &legacy,
    )!;

    AnimatorAuthoringV3 converted = migrate_animation_authoring_v2(legacy)!;
    validate_animator(&converted, context)!;
    attach_animator(&converted, context)!;
}
