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

<* Scale composition used by an additive action. *>
enum AdditiveScaleMode {
    DIFFERENCE,
    MULTIPLICATIVE,
}

<* One clip's captured configuration and mutable playback state. *>
struct Action {
    ClipId clip;
    uint[] cursors;
    bool[] mask;
    float[] weighted_mask;
    float[] reference;
    AdditiveScaleMode additive_scale;
    float time;
    float speed;
    float weight;
    float fade_target;
    float fade_rate;
    uint layer;
    bool additive;
    bool loop;
    bool playing;

    RootMotion root_motion;
    bool root_yaw;
    RootExtractionDesc extraction;
    CapturedMotionChain* motion_chain;
    GeneralizedMotionReference motion_reference;
    uint translation_track;
    uint rotation_track;
    Vec3 root_position;
    Quat root_rotation;
    Mat4 motion_basis;
    Vec3 cycle_translation;
    float cycle_yaw;

    double previous_time;
    double clock_delta;
    double clock_time;
    float published_time;
    uint blend_space;
    double analytic_speed;
}

<* Fixed playback slots and masks owned by one model instance. *>
struct Animator {
    Scene* scene;
    <* Borrowed table; resolve nodes through ModelInstance.present_node. *>
    Node*[] nodes;
    Pool{Action, AnimationActionId}* actions;
    AnimationActionId[] order;
    uint action_count;
    bool[] mask_storage;

    Node* instance_root;
    uint root_node;
    RootMotionDelta root_motion;

    FiredEvent[] events;
    uint event_count;
    uint events_dropped;

    BlendSpace1D[] blend_spaces;
    BlendSpace2D[] blend_spaces_2d;
    PoseStorage* pose_storage;
    InertialStorage* inertial_storage;
    GeneralizedPlaybackState generalized_state;
}

<* Captured configuration of a newly played action. *>
struct PlayDesc {
    float fade_in;
    uint layer;
    bool additive;
    JointMask* mask;
    WeightedJointMask* weighted_mask;
    AdditiveScaleMode additive_scale;
    RootMotion root_motion;
    bool root_yaw;
    RootExtractionDesc extraction;
}

struct ActionStorage @local {
    Pool{Action, AnimationActionId} actions;
    AnimationActionId[MAX_ACTIONS] order;
    FiredEvent[MAX_FIRED_EVENTS] events;
    BlendSpace1D[MAX_BLEND_SPACES] blend_spaces;
}

$assert $reflect(ActionStorage.actions).offset == 0;

<*
 Start a clip and return its stable playback identity.
 @param [&in] assets : "Owns the clip throughout playback."
 @param desc : "Mask membership is copied during this call."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
*>
fn AnimationActionId? Animator.play(
    &self,
    AssetStore* assets,
    ClipId clip,
    PlayDesc desc = PLAY_DESC_DEFAULT,
) {
    PlaybackView playback = self.playback();
    refresh_destination(self);

    return playback.play(
        assets: assets,
        clip: clip,
        desc: desc,
        destination: self.pose_storage.destination,
        motion_basis: animator_motion_basis(self),
    );
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
    PlaybackView playback = self.playback();
    playback.stop(action, fade_out)!;
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
    PlaybackView playback = self.playback();
    playback.cross_fade(from, to, duration)!;
}

<*
 Add an animator to an instance root and return its short-lived address.
 @param [&inout] scene : "Owns the component and every action array."
 @param [&in] instance_root : "Carries ModelInstance."
 @require scene.has(instance_root, ModelInstance), !scene.has(instance_root, Animator)
*>
fn Animator* add_animator(Scene* scene, Node* instance_root, AnimatorDesc desc = {}) {
    ModelInstance* instance = scene.get(instance_root, ModelInstance);
    usz mask_count = MAX_ACTIONS * instance.nodes.len;
    ActionStorage* storage = (ActionStorage*)alloc::malloc(scene.allocator, (sz)(ActionStorage::size + mask_count));
    *storage = {};

    storage.actions = pool::create_pool{Action, AnimationActionId}(scene.allocator, MAX_ACTIONS);

    Animator animator = {
        .scene = scene,
        .nodes = instance.nodes,
        .actions = &storage.actions,
        .order = storage.order[..],
        .mask_storage = ((bool*)(storage + 1))[:mask_count],
        .instance_root = instance_root,
        .root_motion = { .rotation = quaternion::IDENTITY },
        .events = storage.events[..],
        .blend_spaces = storage.blend_spaces[..],
    };

    animator.blend_spaces_2d = create_blend_spaces_2d(scene.allocator, MAX_ACTIONS)!!;

    animator.root_node = find_root_node(&animator);

    animator.pose_storage = create_pose_storage(
        allocator: scene.allocator,
        base_pose: instance.base_pose,
        mesh_nodes: instance.mesh_nodes,
        base_morph_weights: instance.base_morph_weights,
        event_capacity: MAX_FIRED_EVENTS,
        inertia_enabled: desc.inertia_enabled,
    );

    if (desc.inertia_enabled) {
        uint morphs;
        foreach (values : instance.base_morph_weights) morphs += (uint)values.len;
        animator.inertial_storage = create_inertial_storage(
            allocator: scene.allocator,
            nodes: (uint)instance.nodes.len,
            morphs: morphs,
            capacity: 1,
        )!!;
        reset_inertial_row(animator.inertial_storage, 0, instance_root.id.generation);
    }

    return scene.add(instance_root, animator);
}

<*
 Advance every animator and write instance node locals and morph weights.
 @param [&in] assets : "Resolves clips."
 @param [&inout] scene : "Pose is written; structure unchanged."
 @param dt : "Finite nonnegative seconds."
 @require math::is_finite(dt) && dt >= 0
*>
fn void update(AssetStore* assets, Scene* scene, float dt) {
    instrumentation::@scope("anim.update") {
        scene.@each(Animator; Entity entity, Animator* animator) {
            ModelInstance* instance = scene.get(scene.node(entity), ModelInstance);

            refresh_destination(animator);
            PlaybackView playback = animator.playback();

            PoseReport report = evaluate_pose(
                playback: &playback,
                assets: assets,
                destination: animator.pose_storage.destination,
                scratch: animator.pose_storage.scratch,
                dt: dt,
                events: event_output(animator.events),
            );

            animator.event_count = report.events.count;
            animator.events_dropped = report.events.dropped;

            if (report.generalized) {
                animator.root_motion = publish_generalized_owner_motion(
                    playback: &playback,
                    destination: animator.pose_storage.destination,
                    motion: report.generalized_motion,
                    dt: (double)dt,
                    scratch: animator.pose_storage.scratch,
                );
                publish_animator_pose(animator, instance);
            } else {
                publish_animator_pose(animator, instance);

                Vec3 reference;
                if (report.motion.yaw != 0) {
                    Node* root = instance.present_node(animator.root_node);
                    reference = root.local.position;

                    for (Node* parent = root.parent; parent && parent != animator.instance_root; parent = parent.parent) {
                        reference = maths::transform_point(parent.local.to_mat4(), reference);
                    }
                }

                animator.root_motion = root_motion_delta(report.motion, reference);
                if (animator.inertial_storage) {
                    animator.root_motion = publish_inertial_root_motion(
                        row: &animator.inertial_storage.rows[0],
                        target: animator.root_motion,
                        target_twist: (double)report.motion.yaw,
                        up: { 0, 1, 0 },
                        pivot: { reference.x, reference.y, reference.z },
                        dt: (double)dt,
                    );
                }

            }

            record_playback_inertial_history(
                playback: &playback,
                destination: animator.pose_storage.destination,
                scratch: animator.pose_storage.scratch,
                dt: (double)dt,
            );
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
        release_prepared_action(allocator, action);
    }

    if (animator.inertial_storage) destroy_inertial_storage(animator.inertial_storage);

    destroy_blend_spaces_2d(allocator, animator.blend_spaces_2d);
    destroy_pose_storage(allocator, animator.pose_storage);
    pool::destroy_pool{Action, AnimationActionId}(animator.actions);
    alloc::free(allocator, animator.actions);
}
