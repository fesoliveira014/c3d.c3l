module c3d::serial;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::describe;
import c3d::scene;
import std::math;

const ulong ACTION_AUTHORING_LAYOUT @local = 0xaafb7d37846979a1;
const ulong SPACE_AUTHORING_LAYOUT @local = 0x89bbbea9c64ba2b7;
const ulong ANIMATOR_AUTHORING_LAYOUT @local = 0xa4a3c2515a5669b4;

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

fn void? register_animator_codec() @private {
    describe::register_reflected(ActionAuthoring)!;
    describe::register_reflected(SpaceAuthoring)!;
    describe::register_reflected(AnimatorAuthoring)!;
    register_core_value(ActionAuthoring, ACTION_AUTHORING_LAYOUT, &defaults_action)!;
    register_core_value(SpaceAuthoring, SPACE_AUTHORING_LAYOUT, &defaults_space)!;
    register_core_value(AnimatorAuthoring, ANIMATOR_AUTHORING_LAYOUT, &defaults_animator)!;
    register_described_owner(Animator, AnimatorAuthoring, {
        .name = "c3d.Animator", .phase = OWNER,
        .collect = &collect_animator,
        .project = &project_animator,
        .validate = &validate_animator,
        .attach = &attach_animator,
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
    ActionAuthoring[] actions = alloc::new_array_try(tmem, ActionAuthoring, animator.action_count)
      ?? c3d::CAPACITY_EXCEEDED~!;
    SpaceAuthoring[] spaces = alloc::new_array_try(tmem, SpaceAuthoring, animator.blend_spaces.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    bool[anim::MAX_BLEND_SPACES] retained_spaces;
    foreach (index, space : animator.blend_spaces) {
        retained_spaces[index] = space.count != 0 && !(space.fade_rate > 0 && space.fade_target == 0);
    }
    uint[anim::MAX_ACTIONS] mapping;
    mapping[..] = INDEX_NONE;
    uint action_count;
    foreach (index, id : animator.order[:animator.action_count]) {
        Action* action = animator.action(id);
        if (action.blend_space) {
            if (!retained_spaces[action.blend_space - 1]) continue;
        } else if (action.fade_rate > 0 && action.fade_target == 0) {
            continue;
        }
        mapping[index] = action_count;
        actions[action_count++] = {
            .clip = action.clip, .speed = action.speed,
            .weight = action.blend_space ? 0 : (action.fade_rate > 0 ? action.fade_target : action.weight),
            .layer = action.layer, .additive = action.additive, .loop = action.loop,
            .playing = action.blend_space ? false : action.playing, .mask = action.mask,
            .root_motion = action.root_motion, .root_yaw = action.root_yaw,
        };
    }
    uint space_count;
    foreach (index, &space : animator.blend_spaces) {
        if (!retained_spaces[index]) continue;
        uint[] indices = alloc::new_array_try(tmem, uint, space.count) ?? c3d::CAPACITY_EXCEEDED~!;
        foreach (member, id : space.actions[:space.count]) {
            foreach (ordered, candidate : animator.order[:animator.action_count]) {
                if (c3d::same_id(candidate, id)) indices[member] = mapping[ordered];
            }
        }
        spaces[space_count++] = {
            .actions = indices, .positions = space.positions[:space.count], .parameter = space.parameter,
            .weight = space.fade_rate > 0 ? space.fade_target : space.weight,
            .speed = space.speed, .playing = space.playing,
        };
    }
    *(AnimatorAuthoring*)value = {
        .root_node = animator.root_node, .actions = actions[:action_count], .spaces = spaces[:space_count],
    };
}

fn void? validate_animator(void* value, ReadContext* context) @local {
    AnimatorAuthoring* source = value;
    ModelAuthoring* model = context.authored(ModelInstance, ModelAuthoring, context.node.id)!;
    if (!model) return c3d::INVALID_ARGUMENT~;
    if (source.actions.len > anim::MAX_ACTIONS || source.spaces.len > anim::MAX_BLEND_SPACES) {
        return c3d::CAPACITY_EXCEEDED~;
    }
    if (source.root_node != INDEX_NONE && source.root_node >= model.nodes.len) return c3d::INVALID_ARGUMENT~;
    foreach (action : source.actions) {
        AnimationClip* clip = &context.assets.clips.try_get(action.clip)!.data;
        if (action.mask.len != model.nodes.len || action.layer >= anim::MAX_ANIMATION_LAYERS
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
    bool[anim::MAX_ACTIONS] grouped;
    foreach (space : source.spaces) {
        if (space.actions.len < 2 || space.actions.len > anim::MAX_BLEND_SPACE_ACTIONS
            || space.positions.len != space.actions.len) return c3d::INVALID_ARGUMENT~;
        foreach (index, action : space.actions) {
            if (action >= source.actions.len || grouped[action]) return c3d::INVALID_ARGUMENT~;
            grouped[action] = true;
            if (!math::is_finite(space.positions[index])
                || (index && space.positions[index] <= space.positions[index - 1])) {
                return c3d::INVALID_ARGUMENT~;
            }
            float duration = context.assets.clip(source.actions[action].clip).data.duration;
            if (!math::is_finite(duration) || duration <= 0) return c3d::INVALID_ARGUMENT~;
        }
    }
}

fn void? attach_animator(void* value, ReadContext* context) @local {
    AnimatorAuthoring* source = value;
    Animator* animator = anim::add_animator(context.scene, context.node);
    defer catch context.scene.remove_component(context.node, Animator);
    animator.root_node = source.root_node;
    AnimationActionId[anim::MAX_ACTIONS] ids;
    foreach (index, action : source.actions) {
        JointMask mask = { .nodes = action.mask };
        ids[index] = animator.play(context.assets, action.clip, {
            .layer = action.layer, .additive = action.additive, .mask = &mask,
            .root_motion = action.root_motion, .root_yaw = action.root_yaw,
        })!;
        Action* restored = animator.action(ids[index]);
        restored.speed = action.speed;
        restored.weight = action.weight;
        restored.fade_target = action.weight == 0 ? 1 : action.weight;
        restored.loop = action.loop;
        restored.playing = action.playing;
    }
    foreach (index, space : source.spaces) {
        BlendSpace1D restored = {
            .count = (uint)space.actions.len, .parameter = space.parameter, .weight = space.weight,
            .fade_target = space.weight == 0 ? 1 : space.weight, .speed = space.speed, .playing = space.playing,
        };
        foreach (member, action_index : space.actions) {
            AnimationActionId id = ids[action_index];
            restored.actions[member] = id;
            restored.positions[member] = space.positions[member];
            Action* action = animator.action(id);
            action.blend_space = (uint)index + 1;
            action.weight = 0;
            action.playing = false;
        }
        animator.blend_spaces[index] = restored;
    }
}
