module c3d::anim;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::scene;
import std::math;

const float MOTION_BASIS_TOLERANCE @private = 1e-4f; // accepts float transform roundoff in upright uniform bases
const uint NO_MOTION_TRACK @private = uint::max;
const Vec3 MOTION_UP @private = { 0, 1, 0 };

<* Planar displacement and turn in the instance root's frame. *>
struct RootMotionDelta {
    Vec3 translation;
    Quat rotation;
}

<* Planar displacement and yaw before pivot compensation. *>
struct PlanarMotion {
    Vec3 translation;
    float yaw;
}

<*
 Move and turn a node by motion in its authored frame.
 @param [&inout] node : "World matrices are published separately."
 @param delta : "Uniform positive scale is required for turns."
*>
fn void apply_root_motion(Node* node, RootMotionDelta delta) {
    node.local.position += node.local.rotation.rotate_vec3(node.local.scale * delta.translation);
    node.local.rotation = node.local.rotation.mul(delta.rotation).normalize();
}

fn uint find_root_node(Animator* animator) @private {
    ModelInstance* instance = animator.scene.get(animator.instance_root, ModelInstance);
    for (uint node_index = 0; node_index < instance.nodes.len; node_index++) {
        Node* node = instance.present_node(node_index);
        if (!node) continue;
        SkinBinding* skin = animator.scene.get(node, SkinBinding);
        if (!skin) continue;
        foreach (joint : skin.joints) {
            bool parent_is_joint;
            foreach (member : skin.joints) parent_is_joint |= joint.parent == member;
            if (parent_is_joint) continue;
            for (uint index = 0; index < instance.nodes.len; index++) {
                if (instance.present_node(index) == joint) return index;
            }
        }
        return NO_ROOT_NODE;
    }
    return NO_ROOT_NODE;
}

fn bool upright_uniform_basis(Mat4 basis) @private {
    Vec3 horizontal = maths::transform_dir(basis, { 1, 0, 0 });
    Vec3 up = maths::transform_dir(basis, MOTION_UP);
    Vec3 forward = maths::transform_dir(basis, { 0, 0, 1 });
    float scale = up.length();
    if (scale <= 0) return false;
    horizontal /= scale;
    up /= scale;
    forward /= scale;
    return (up - MOTION_UP).length() < MOTION_BASIS_TOLERANCE
        && math::abs(horizontal.length() - 1) < MOTION_BASIS_TOLERANCE
        && math::abs(forward.length() - 1) < MOTION_BASIS_TOLERANCE
        && horizontal.cross(up).dot(forward) > 1 - MOTION_BASIS_TOLERANCE;
}

fn void? configure_motion(
    PlaybackView* playback,
    Action* action,
    AnimationClip* clip,
    PlayDesc desc,
    MotionBasis motion_basis,
    usz node_count,
) @private {
    action.root_motion = desc.root_motion;
    action.root_yaw = desc.root_yaw;
    action.translation_track = NO_MOTION_TRACK;
    action.rotation_track = NO_MOTION_TRACK;
    action.root_rotation = quaternion::IDENTITY;
    action.motion_basis = matrix::IDENTITY4;

    if (desc.root_yaw && desc.root_motion == RootMotion.KEEP) return c3d::INVALID_ARGUMENT~;
    if (desc.additive && desc.root_motion != RootMotion.KEEP) return c3d::INVALID_ARGUMENT~;
    if (desc.root_motion != RootMotion.KEEP && playback.root_node >= node_count) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (playback.root_node >= node_count) return;

    foreach (uint index, track : clip.tracks) {
        if (clip.targets[track.target] != playback.root_node) continue;
        if (track.path == TargetPath.TRANSLATION) action.translation_track = index;
        if (track.path == TargetPath.ROTATION) action.rotation_track = index;
    }
    if (desc.root_motion == RootMotion.KEEP) return;

    if (!motion_basis.root_present) return;
    if (!motion_basis.parent_space || !motion_basis.ancestors_parent_space) return c3d::INVALID_ARGUMENT~;
    action.motion_basis = motion_basis.basis;
    if (desc.root_yaw && desc.root_motion == RootMotion.EXTRACT
        && (!upright_uniform_basis(action.motion_basis)
            || !upright_uniform_basis(matrix::IDENTITY4.scale(motion_basis.instance_scale)))) {
        return c3d::INVALID_ARGUMENT~;
    }

    action.root_position = motion_position(action, clip, 0);
    action.root_rotation = motion_rotation(action, clip, 0);
    PlanarMotion cycle = sample_motion(action, clip, clip.duration);
    action.cycle_translation = cycle.translation;
    action.cycle_yaw = cycle.yaw;
}

fn Vec3 motion_position(Action* action, AnimationClip* clip, float time) @private {
    if (action.translation_track == NO_MOTION_TRACK) return {};
    float[3] values;
    uint cursor;
    sample_track(
        track: &clip.tracks[action.translation_track],
        time: time,
        cursor: &cursor,
        out: values[..],
    );
    return { values[0], values[1], values[2] };
}

fn Quat motion_rotation(Action* action, AnimationClip* clip, float time) @private {
    if (action.rotation_track == NO_MOTION_TRACK) return quaternion::IDENTITY;
    float[4] values;
    uint cursor;
    sample_track(
        track: &clip.tracks[action.rotation_track],
        time: time,
        cursor: &cursor,
        out: values[..],
    );
    return { .v = { values[0], values[1], values[2], values[3] } };
}

fn float yaw_angle(Quat rotation) @private {
    Quat twist = maths::twist_about(rotation, MOTION_UP);
    return 2 * math::atan2(twist.v.y, twist.v.w);
}

fn float wrap_yaw(float value) @private => math::atan2(math::sin(value), math::cos(value));

fn PlanarMotion sample_motion(Action* action, AnimationClip* clip, float time) @private {
    Vec3 displacement = motion_position(action, clip, time) - action.root_position;
    displacement.y = 0;
    displacement = maths::transform_dir(action.motion_basis, displacement);
    displacement.y = 0;
    float yaw;
    if (action.root_yaw) {
        yaw = wrap_yaw(yaw_angle(motion_rotation(action, clip, time)) - yaw_angle(action.root_rotation));
    }
    return { .translation = displacement, .yaw = yaw };
}

fn PlanarMotion compose_motion(PlanarMotion first, PlanarMotion second) @private {
    Quat turn = quaternion::from_axis_angle{float}(MOTION_UP, first.yaw);
    return {
        .translation = first.translation + turn.rotate_vec3(second.translation),
        .yaw = wrap_yaw(first.yaw + second.yaw),
    };
}

fn PlanarMotion inverse_motion(PlanarMotion value) @private {
    Quat turn = quaternion::from_axis_angle{float}(MOTION_UP, -value.yaw);
    return { .translation = turn.rotate_vec3(-value.translation), .yaw = -value.yaw };
}

fn PlanarMotion cycle_power(PlanarMotion cycle, double count) @private {
    if (count < 0) {
        cycle = inverse_motion(cycle);
        count = -count;
    }
    PlanarMotion result;
    while (count >= 1) {
        double half = math::floor(count / 2);
        if (count - 2 * half >= 1) result = compose_motion(result, cycle);
        count = half;
        if (count >= 1) cycle = compose_motion(cycle, cycle);
    }
    return result;
}

fn PlanarMotion action_motion(Action* action, AnimationClip* clip) @private {
    if (action.clock_delta == 0) return {};
    PlanarMotion first = sample_motion(action, clip, (float)action.previous_time);
    double end = (double)action.previous_time + action.clock_delta;
    PlanarMotion last;
    if (action.loop) {
        double cycles = math::floor(end / clip.duration);
        float phase = (float)(end - cycles * clip.duration);
        PlanarMotion cycle = { .translation = action.cycle_translation, .yaw = action.cycle_yaw };
        last = compose_motion(cycle_power(cycle, cycles), sample_motion(action, clip, phase));
    } else {
        last = sample_motion(action, clip, (float)end);
    }
    return compose_motion(inverse_motion(first), last);
}

fn void pin_root_sample(Action* action, uint track, float[] sample) @private {
    if (action.root_motion == RootMotion.KEEP) return;
    if (track == action.translation_track) {
        sample[0] = action.root_position.x;
        sample[2] = action.root_position.z;
    }
    if (action.root_yaw && track == action.rotation_track) {
        Quat current = { .v = { sample[0], sample[1], sample[2], sample[3] } };
        Quat reference = maths::twist_about(action.root_rotation, MOTION_UP);
        Quat twist = maths::twist_about(current, MOTION_UP);
        Quat pinned = reference.mul(twist.conjugate()).mul(current).normalize();
        for (uint channel = 0; channel < 4; channel++) sample[channel] = pinned.v[channel];
    }
}

fn PlanarMotion evaluate_root_motion(
    PlaybackView* playback,
    AssetStore* assets,
    PoseDestination destination,
) @private {
    if (playback.root_node >= destination.pose.len || !destination.present[playback.root_node]) return {};

    Vec3 translation;
    float yaw;

    for (uint layer = 0; layer < MAX_ANIMATION_LAYERS; layer++) {
        Vec3 sum;
        float translation_weight;
        float yaw_sum;
        float rotation_weight;

        foreach (id : playback.order[:*playback.action_count]) {
            Action* action = playback.actions.get(id);
            if (action.layer != layer || action.additive || action.weight <= 0
                || !action.mask[playback.root_node]) continue;

            PlanarMotion delta;
            if (action.root_motion == RootMotion.EXTRACT) delta = action_motion(action, &assets.clip(action.clip).data);

            if (action.translation_track != NO_MOTION_TRACK) {
                sum += delta.translation * action.weight;
                translation_weight += action.weight;
            }

            if (action.rotation_track != NO_MOTION_TRACK) {
                yaw_sum += delta.yaw * action.weight;
                rotation_weight += action.weight;
            }
        }

        translation = (sum + translation * math::max(0.0f, 1 - translation_weight))
            / math::max(1.0f, translation_weight);
        yaw = (yaw_sum + yaw * math::max(0.0f, 1 - rotation_weight)) / math::max(1.0f, rotation_weight);
    }

    return { .translation = translation, .yaw = yaw };
}

<*
 Compose extracted motion about an evaluated root reference.
 @param reference : "Root pivot in the instance owner's frame."
 @pure
*>
fn RootMotionDelta root_motion_delta(PlanarMotion motion, Vec3 reference) {
    Vec3 translation = motion.translation;
    float yaw = motion.yaw;
    Quat rotation = quaternion::from_axis_angle{float}(MOTION_UP, yaw);
    if (yaw != 0) {
        reference.y = 0;
        if (reference.x != 0 || reference.z != 0) {
            double half_sine = math::sin((double)yaw / 2);
            double one_minus_cosine = 2 * half_sine * half_sine;
            double sine = math::sin((double)yaw);

            translation.x += (float)(one_minus_cosine * reference.x - sine * reference.z);
            translation.z += (float)(sine * reference.x + one_minus_cosine * reference.z);
        }
    }

    return { .translation = translation, .rotation = rotation };
}

fn void advance_clock(Action* action, float duration, double travel) @private {
    if (duration <= 0 || travel == 0) return;
    double start = action.time != action.published_time ? (double)action.time : action.clock_time;
    if (action.loop) {
        start -= math::floor(start / duration) * duration;
        if (start == 0 && travel < 0) start = duration;
    } else {
        start = math::clamp(start, 0.0, (double)duration);
    }
    double end = start + travel;
    if (!action.loop) end = math::clamp(end, 0.0, (double)duration);

    action.previous_time = start;
    action.clock_delta = end - start;

    if (action.loop) {
        action.clock_time = end - math::floor(end / duration) * duration;
    } else {
        action.clock_time = end;
        if (end <= 0 || end >= duration) action.playing = false;
    }

    action.time = (float)action.clock_time;
    action.published_time = action.time;
}
