module c3d::anim;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::instrumentation @public;
import c3d::maths;
import c3d::scene;
import c3d::pool;
import std::math;

<* Live action slots owned by each animator. *>
const uint MAX_ACTIONS = 16; // sixteen Action slots and model-sized mask rows; bounds concurrent clips

<* Layers folded from the authored pose upward. *>
const uint MAX_ANIMATION_LAYERS = 4; // up to four channel folds; base plus upper-body/head overlays

<* Full-weight regular playback on the base layer. *>
const PlayDesc PLAY_DESC_DEFAULT = {};

<* One clip's captured configuration and mutable playback state. *>
struct Action {
    ClipId clip;
    uint[] cursors;
    bool[] mask;
    float[] reference;
    float time;
    float speed;
    float weight;
    float fade_target;
    float fade_rate;
    uint layer;
    bool additive;
    bool loop;
    bool playing;
}

<* Fixed playback slots and masks owned by one model instance. *>
struct Animator {
    Scene* scene;
    Node*[] nodes;
    Pool{Action, AnimationActionId} actions;
    AnimationActionId[MAX_ACTIONS] order;
    uint action_count;
    bool[] mask_storage;
}

<* Captured configuration of a newly played action. *>
struct PlayDesc {
    float fade_in;
    uint layer;
    bool additive;
    JointMask* mask;
}

<*
 Start a clip and return its stable playback identity.
 @param [&in] assets : "Owns the clip throughout playback."
 @param desc : "Mask membership is copied during this call."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn AnimationActionId? Animator.play(
    &self,
    AssetStore* assets,
    ClipId clip,
    PlayDesc desc = PLAY_DESC_DEFAULT,
) {
    AnimationClip* data = &assets.clips.try_get(clip)!.data;
    if (!math::is_finite(desc.fade_in) || desc.fade_in < 0 || desc.layer >= MAX_ANIMATION_LAYERS) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (desc.mask && desc.mask.nodes.len != self.nodes.len) return c3d::INVALID_ARGUMENT~;

    usz reference_count;
    foreach (target : data.targets) {
        if (target >= self.nodes.len) return c3d::INVALID_ARGUMENT~;
    }
    foreach (&track : data.tracks) {
        reference_count += track.stride();
        if (track.path != TargetPath.MORPH_WEIGHTS) continue;
        Mesh* mesh = self.scene.get(self.nodes[data.targets[track.target]], Mesh);
        if (!mesh || mesh.morph_weights.len != track.stride()) return c3d::INVALID_ARGUMENT~;
    }
    if (!self.actions.free_count) return c3d::CAPACITY_EXCEEDED~;

    Allocator allocator = self.scene.allocator;
    uint[] cursors = alloc::new_array(allocator, uint, data.tracks.len);
    defer catch alloc::free(allocator, cursors.ptr);

    float[] reference;
    if (desc.additive) reference = alloc::new_array(allocator, float, (sz)reference_count);
    defer catch alloc::free(allocator, reference.ptr);

    if (desc.additive) {
        usz offset;
        foreach (&track : data.tracks) {
            uint cursor;
            sample_track(
                track: track,
                time: 0,
                cursor: &cursor,
                out: reference[offset:track.stride()],
            );
            offset += track.stride();
        }
    }

    AnimationActionId id = self.actions.add({
        .clip = clip,
        .cursors = cursors,
        .reference = reference,
        .speed = 1,
        .weight = desc.fade_in > 0 ? 0 : 1,
        .fade_target = 1,
        .fade_rate = desc.fade_in > 0 ? 1 / desc.fade_in : 0,
        .layer = desc.layer,
        .additive = desc.additive,
        .loop = true,
        .playing = true,
    })!;
    Action* action = self.actions.get(id);
    action.mask = self.mask_storage[(usz)id.index * self.nodes.len:self.nodes.len];
    if (desc.mask) {
        action.mask[..] = desc.mask.nodes[..];
    } else {
        action.mask[..] = true;
    }

    self.order[self.action_count++] = id;
    return id;
}

<*
 Borrow a known-live action until structural action changes.
 @require self.actions.is_live(action)
*>
fn Action* Animator.action(&self, AnimationActionId action) => self.actions.get(action);

<*
 Borrow an action until structural action changes.
 @return? c3d::INVALID_ID
*>
fn Action*? Animator.try_action(&self, AnimationActionId action) => self.actions.try_get(action);

<*
 Fade out an action or remove it immediately.
 @param fade_out : "Finite nonnegative seconds; zero removes immediately."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
*>
fn void? Animator.stop(&self, AnimationActionId action, float fade_out = 0) {
    Action* state = self.actions.try_get(action)!;
    if (!math::is_finite(fade_out) || fade_out < 0) return c3d::INVALID_ARGUMENT~;

    if (fade_out == 0) {
        uint index;
        while (!c3d::same_id(self.order[index], action)) index++;
        remove_action(self, index);
        return;
    }

    state.fade_target = 0;
    state.fade_rate = state.weight / fade_out;
}

<*
 Fade one action out while another reaches full weight.
 @param duration : "Finite positive seconds."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
*>
fn void? Animator.cross_fade(
    &self,
    AnimationActionId from,
    AnimationActionId to,
    float duration,
) {
    Action* source = self.actions.try_get(from)!;
    Action* target = self.actions.try_get(to)!;
    if (!math::is_finite(duration) || duration <= 0 || c3d::same_id(from, to)) return c3d::INVALID_ARGUMENT~;

    source.fade_target = 0;
    source.fade_rate = source.weight / duration;
    target.fade_target = 1;
    target.fade_rate = math::abs(1 - target.weight) / duration;
}

<*
 Add an animator to an instance root and return its short-lived address.
 @param [&inout] scene : "Owns the component and every action array."
 @param [&in] instance_root : "Carries ModelInstance."
 @require scene.has(instance_root, ModelInstance), !scene.has(instance_root, Animator)
*>
fn Animator* add_animator(Scene* scene, Node* instance_root) {
    ModelInstance* instance = scene.get(instance_root, ModelInstance);
    Animator animator = { .scene = scene, .nodes = instance.nodes };
    animator.actions = pool::create_pool{Action, AnimationActionId}(scene.allocator, MAX_ACTIONS);
    animator.mask_storage = alloc::new_array(scene.allocator, bool, (sz)(MAX_ACTIONS * instance.nodes.len));
    return scene.add(instance_root, animator);
}

<*
 Advance every animator and write instance node locals and morph weights.
 @param [&in] assets : "Resolves clips."
 @param [&inout] scene : "Pose is written; structure unchanged."
 @param dt : "Seconds."
*>
fn void update(AssetStore* assets, Scene* scene, float dt) {
    instrumentation::@scope("anim.update") {
        scene.@each(Animator; Entity entity, Animator* animator) {
            ModelInstance* instance = scene.get(scene.node(entity), ModelInstance);
            advance(animator, assets, dt);
            @pool() {
                blend_instance(animator, assets, instance);
            };
        };
    };
}

<*
 Component removal hook: frees the action arrays with the hook allocator.
 @param [in] component : "Animator being removed."
 @param [in] user : "Allocator* the arrays were allocated with."
*>
fn void free_animator(Entity entity, void* component, void* user) {
    Animator* animator = (Animator*)component;
    Allocator allocator = *(Allocator*)user;

    foreach (id : animator.order[:animator.action_count]) {
        Action* action = animator.actions.get(id);
        alloc::free(allocator, action.cursors.ptr);
        alloc::free(allocator, action.reference.ptr);
    }

    pool::destroy_pool{Action, AnimationActionId}(&animator.actions);
    alloc::free(allocator, animator.mask_storage.ptr);
}

fn void remove_action(Animator* animator, uint index) @local {
    AnimationActionId id = animator.order[index];
    Action* action = animator.actions.get(id);
    alloc::free(animator.scene.allocator, action.cursors.ptr);
    alloc::free(animator.scene.allocator, action.reference.ptr);
    *action = {};

    animator.actions.remove(id);
    animator.action_count--;
    for (uint next = index; next < animator.action_count; next++) animator.order[next] = animator.order[next + 1];
}

fn void advance(Animator* animator, AssetStore* assets, float dt) @local {
    for (uint index = animator.action_count; index > 0; index--) {
        Action* action = animator.actions.get(animator.order[index - 1]);
        if (action.playing) {
            float duration = assets.clip(action.clip).data.duration;
            action.time += dt * action.speed;
            if (duration == 0) {
                action.time = 0;
            } else if (action.loop) {
                action.time -= math::floor(action.time / duration) * duration;
            } else if (action.time <= 0 || action.time >= duration) {
                action.time = math::clamp(action.time, 0.0f, duration);
                action.playing = false;
            }
        }

        if (action.fade_rate > 0) {
            float step = action.fade_rate * dt;
            float remaining = action.fade_target - action.weight;
            if (math::abs(remaining) <= step) {
                action.weight = action.fade_target;
                action.fade_rate = 0;
            } else {
                action.weight += remaining < 0 ? -step : step;
            }
        }

        if (action.fade_target == 0 && action.weight == 0) remove_action(animator, index - 1);
    }
}
