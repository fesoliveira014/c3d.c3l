module c3d::anim;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import std::collections::list;
import std::math;

const usz ACTION_INITIAL_CAPACITY @local = 4; // one clip plus a cross-fade partner without growth

<*
 One clip playing on an instance; a borrow that play and removal invalidate.
*>
struct Action {
    ClipId clip;
    uint[] cursors;
    float  time;
    float  speed;
    float  weight;
    float  fade_target;
    float  fade_rate;
    bool   loop;
    bool   playing;
}

<*
 Actions blended onto one model instance; lives on the instance root.
*>
struct Animator {
    Scene*       scene;
    Node*[]      nodes;
    List{Action} actions;
}

struct ChannelSums @local {
    Vec3  translation;
    float translation_weight;
    Vec4  rotation;
    float rotation_weight;
    Vec3  scale;
    float scale_weight;
}

<*
 Start the clip at time zero and return its short-lived action.
 Invalidates every action pointer of this animator.
 @param [&in] assets : "Resolves the clip."
 @param fade_in : "Seconds from weight zero to one; zero starts at full weight."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
 @require fade_in >= 0
*>
fn Action*? Animator.play(&self, AssetStore* assets, ClipId clip, float fade_in = 0) {
    AnimationClip* data = &assets.clips.try_get(clip)!.data;
    foreach (target : data.targets) {
        if (target >= self.nodes.len) return c3d::INVALID_ARGUMENT~;
    }
    foreach (&track : data.tracks) {
        if (track.path != TargetPath.MORPH_WEIGHTS) continue;
        Mesh* mesh = self.scene.get(self.nodes[data.targets[track.target]], Mesh);
        if (!mesh || mesh.morph_weights.len != track.stride()) return c3d::INVALID_ARGUMENT~;
    }
    self.actions.push({
        .clip        = clip,
        .cursors     = alloc::new_array(self.scene.allocator, uint, data.tracks.len),
        .speed       = 1,
        .weight      = fade_in > 0 ? 0 : 1,
        .fade_target = 1,
        .fade_rate   = fade_in > 0 ? 1 / fade_in : 0,
        .loop        = true,
        .playing     = true,
    });
    return &self.actions[self.actions.len() - 1];
}

<*
 Fade the action out and remove it, or remove it now.
 Invalidates every action pointer of this animator when removing now.
 @param [&inout] action : "An action of this animator."
 @param fade_out : "Seconds to weight zero; zero removes now."
 @require fade_out >= 0
*>
fn void Animator.stop(&self, Action* action, float fade_out = 0) {
    if (fade_out == 0) {
        remove_action(self, action - self.actions.entries);
        return;
    }
    action.fade_target = 0;
    action.fade_rate = action.weight / fade_out;
}

<*
 Fade one action out while the other fades to full weight.
 @param [&inout] from : "An action of this animator."
 @param [&inout] to : "An action of this animator."
 @require duration > 0, from != to
*>
fn void Animator.cross_fade(&self, Action* from, Action* to, float duration) {
    self.stop(from, duration);
    to.fade_target = 1;
    to.fade_rate = (1 - to.weight) / duration;
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
    animator.actions.init(scene.allocator, ACTION_INITIAL_CAPACITY);
    return scene.add(instance_root, animator);
}

<*
 Advance every animator and write instance node locals and morph weights.
 @param [&in] assets : "Resolves clips."
 @param [&inout] scene : "Pose is written; structure unchanged."
 @param dt : "Seconds."
*>
fn void update(AssetStore* assets, Scene* scene, float dt) {
    scene.@each(Animator; Entity entity, Animator* animator) {
        ModelInstance* instance = scene.get(scene.node(entity), ModelInstance);
        advance(animator, assets, dt);
        @pool() {
            blend_instance(animator, assets, instance);
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
    foreach (&action : animator.actions) alloc::free(allocator, action.cursors.ptr);
    animator.actions.free();
}

fn void remove_action(Animator* animator, sz index) @local {
    alloc::free(animator.scene.allocator, animator.actions[index].cursors.ptr);
    animator.actions.remove_at(index);
}

fn void advance(Animator* animator, AssetStore* assets, float dt) @local {
    for (sz index = animator.actions.len(); index > 0; index--) {
        Action* action = &animator.actions[index - 1];
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
                if (action.fade_target == 0) remove_action(animator, index - 1);
            } else {
                action.weight += remaining < 0 ? -step : step;
            }
        }
    }
}

fn void blend_instance(Animator* animator, AssetStore* assets, ModelInstance* instance) @local {
    ChannelSums[] sums = alloc::new_array(tmem, ChannelSums, instance.nodes.len);
    float[][] morph_sums = alloc::new_array(tmem, float[], instance.base_morph_weights.len);
    float[] morph_weights = alloc::new_array(tmem, float, instance.base_morph_weights.len);
    foreach (index, base : instance.base_morph_weights) morph_sums[index] = alloc::new_array(tmem, float, base.len);

    foreach (&action : animator.actions) {
        if (action.weight <= 0) continue;
        AnimationClip* clip = &assets.clip(action.clip).data;
        foreach (track_index, &track : clip.tracks) {
            float[] sample = alloc::new_array(tmem, float, track.stride());
            sample_track(track, action.time, &action.cursors[track_index], sample);
            uint node = clip.targets[track.target];
            switch (track.path) {
                case TRANSLATION:
                    sums[node].translation += (Vec3){ sample[0], sample[1], sample[2] } * action.weight;
                    sums[node].translation_weight += action.weight;
                case ROTATION:
                    Vec4 rotation = { sample[0], sample[1], sample[2], sample[3] };
                    if (rotation.dot(instance.base_pose[node].rotation.v) < 0) rotation = -rotation;
                    sums[node].rotation += rotation * action.weight;
                    sums[node].rotation_weight += action.weight;
                case SCALE:
                    sums[node].scale += (Vec3){ sample[0], sample[1], sample[2] } * action.weight;
                    sums[node].scale_weight += action.weight;
                case MORPH_WEIGHTS:
                    usz mesh = mesh_index(instance, node);
                    foreach (index, value : sample) morph_sums[mesh][index] += value * action.weight;
                    morph_weights[mesh] += action.weight;
            }
        }
    }

    foreach (index, node : instance.nodes) {
        ChannelSums* sum = &sums[index];
        Transform* base = &instance.base_pose[index];
        node.local.position = blend_vec3(sum.translation, sum.translation_weight, base.position);
        node.local.rotation = { .v = (sum.rotation + base.rotation.v * residual(sum.rotation_weight)).normalize() };
        node.local.scale = blend_vec3(sum.scale, sum.scale_weight, base.scale);
    }
    foreach (index, base : instance.base_morph_weights) {
        Mesh* mesh = animator.scene.get(instance.nodes[instance.mesh_nodes[index]], Mesh);
        float total = morph_weights[index];
        foreach (weight_index, &weight : mesh.morph_weights) {
            *weight = (morph_sums[index][weight_index] + base[weight_index] * residual(total)) / math::max(1.0f, total);
        }
    }
}

fn usz mesh_index(ModelInstance* instance, uint node) @local {
    usz index;
    while (instance.mesh_nodes[index] != node) index++;
    return index;
}

fn float residual(float total) @local {
    return math::max(0.0f, 1 - total);
}

fn Vec3 blend_vec3(Vec3 sum, float total, Vec3 base) @local {
    return (sum + base * residual(total)) / math::max(1.0f, total);
}
