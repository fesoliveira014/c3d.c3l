module c3d::anim;

import c3d;
import c3d::maths;
import std::math;

const double GENERALIZED_TWO_PI @local = 2 * math::PI;
const GeneralizedMotionFrame GENERALIZED_FRAME_IDENTITY @private = {
    .rotation = { .v = { 0, 0, 0, 1 } },
    .scale = 1,
};

struct GeneralizedMotionFrame @private {
    double[<3>] position;
    Quaternion rotation;
    double scale;
}

// Translation is the published rigid displacement, including the pivot term.
struct GeneralizedMotion @private {
    double[<3>] translation;
    double twist;
}

struct GeneralizedMotionReference @private {
    GeneralizedMotionFrame frame;
    double[<3>] up;
    double twist;
    GeneralizedMotion cycle;
    float duration;
}

fn GeneralizedMotionFrame sample_generalized_endpoint(
    CapturedMotionChain* chain,
    AnimationClip* clip,
    float time,
    StepSampleSide side = StepSampleSide.EXACT,
) @private {
    GeneralizedMotionFrame world = GENERALIZED_FRAME_IDENTITY;

    for (sz index = chain.nodes.len; index > 0; index--) {
        CapturedMotionNode* node = &chain.nodes[index - 1];
        GeneralizedMotionFrame local = generalized_frame_from_transform(node.baseline);
        double[4] value;
        double[4] rate;
        uint cursor;

        if (node.translation_track != NO_MOTION_TRACK) {
            sample_track_analytic(
                track: &clip.tracks[node.translation_track],
                time: time,
                cursor: &cursor,
                value: value[:3],
                rate: rate[:3],
                side: side,
            );
            local.position = { value[0], value[1], value[2] };
        }

        if (node.rotation_track != NO_MOTION_TRACK) {
            cursor = 0;
            sample_track_analytic(
                track: &clip.tracks[node.rotation_track],
                time: time,
                cursor: &cursor,
                value: value[..],
                rate: rate[..],
                side: side,
            );
            local.rotation = { .v = { value[0], value[1], value[2], value[3] } };
        }

        if (node.scale_track != NO_MOTION_TRACK) {
            cursor = 0;
            sample_track_analytic(
                track: &clip.tracks[node.scale_track],
                time: time,
                cursor: &cursor,
                value: value[:3],
                rate: rate[:3],
                side: side,
            );
            local.scale = (value[0] + value[1] + value[2]) / 3;
        }

        world = compose_generalized_frames(world, local);
    }

    return world;
}

fn GeneralizedMotionReference capture_generalized_motion_reference(
    CapturedMotionChain* chain,
    AnimationClip* clip,
    StepSampleSide side = StepSampleSide.EXACT,
) @private {
    Vec3 captured_up = chain.extraction.up;
    double[<3>] up = { captured_up.x, captured_up.y, captured_up.z };
    // Admission preserves authoring; this unit direction constructs proper double rigid rotations.
    up /= up.length();
    GeneralizedMotionReference reference = {
        .frame = sample_generalized_endpoint(
            chain: chain,
            clip: clip,
            time: 0,
            side: side,
        ),
        .up = up,
        .duration = clip.duration,
    };
    reference.twist = generalized_twist_angle(reference.frame.rotation, up);

    reference.cycle = generalized_endpoint_motion(
        chain: chain,
        reference: &reference,
        endpoint: sample_generalized_endpoint(chain, clip, clip.duration),
    );

    return reference;
}

fn GeneralizedMotion generalized_motion_delta(
    CapturedMotionChain* chain,
    AnimationClip* clip,
    GeneralizedMotionReference* reference,
    double begin,
    double end,
    bool loop,
    StepSampleSide begin_side = StepSampleSide.EXACT,
    StepSampleSide end_side = StepSampleSide.EXACT,
) @private {
    if (begin == end) return {};

    GeneralizedMotion first = generalized_motion_trajectory(
        chain: chain,
        clip: clip,
        reference: reference,
        time: begin,
        loop: loop,
        side: begin_side,
    );
    GeneralizedMotion last = generalized_motion_trajectory(
        chain: chain,
        clip: clip,
        reference: reference,
        time: end,
        loop: loop,
        side: end_side,
    );

    return compose_generalized_motion(inverse_generalized_motion(first, reference.up), last, reference.up);
}

fn GeneralizedMotionFrame generalized_reference_anchor(
    GeneralizedMotionFrame consumed,
    GeneralizedMotionFrame target_reference,
) @private {
    return compose_generalized_frames(consumed, inverse_generalized_frame(target_reference));
}

fn GeneralizedMotionFrame generalized_branch_correction(
    GeneralizedMotionFrame consumed,
    GeneralizedMotionFrame anchor = GENERALIZED_FRAME_IDENTITY,
) @private {
    return compose_generalized_frames(inverse_generalized_frame(consumed), anchor);
}

fn void compensate_generalized_branches(
    CapturedMotionChain* chain,
    Transform[] pose,
    GeneralizedMotionFrame correction,
) @private {
    foreach (model_node : chain.top_level_nodes) {
        Transform* local = &pose[model_node];
        double[<3>] position = { local.position.x, local.position.y, local.position.z };
        Quaternion rotation = { .v = {
            local.rotation.v.x, local.rotation.v.y, local.rotation.v.z, local.rotation.v.w,
        } };
        position = correction.position + correction.rotation.rotate_vec3(position * correction.scale);
        rotation = inertial_normalize_rotation(correction.rotation.mul(rotation));

        local.position = { (float)position.x, (float)position.y, (float)position.z };
        local.rotation = { .v = {
            (float)rotation.v.x, (float)rotation.v.y, (float)rotation.v.z, (float)rotation.v.w,
        } };
        local.scale *= (float)correction.scale;
    }
}

fn GeneralizedMotionFrame compose_generalized_frames(
    GeneralizedMotionFrame parent,
    GeneralizedMotionFrame local,
) @private {
    return {
        .position = parent.position + parent.rotation.rotate_vec3(local.position * parent.scale),
        .rotation = inertial_normalize_rotation(parent.rotation.mul(local.rotation)),
        .scale = parent.scale * local.scale,
    };
}

fn GeneralizedMotionFrame inverse_generalized_frame(GeneralizedMotionFrame frame) @private {
    Quaternion rotation = frame.rotation.conjugate();

    return {
        .position = rotation.rotate_vec3(-frame.position) / frame.scale,
        .rotation = rotation,
        .scale = 1 / frame.scale,
    };
}

fn GeneralizedMotionFrame generalized_frame_from_transform(Transform transform) @private {
    Quaternion rotation = { .v = {
        transform.rotation.v.x, transform.rotation.v.y, transform.rotation.v.z, transform.rotation.v.w,
    } };

    return {
        .position = { transform.position.x, transform.position.y, transform.position.z },
        .rotation = inertial_normalize_rotation(rotation),
        .scale = ((double)transform.scale.x + (double)transform.scale.y + (double)transform.scale.z) / 3,
    };
}

fn GeneralizedMotionFrame generalized_frame_from_motion(GeneralizedMotion motion, double[<3>] up) @private {
    return {
        .position = motion.translation,
        .rotation = generalized_twist_rotation(up, motion.twist),
        .scale = 1,
    };
}

fn GeneralizedMotion compose_generalized_motion(
    GeneralizedMotion first,
    GeneralizedMotion second,
    double[<3>] up,
) @private {
    Quaternion rotation = generalized_twist_rotation(up, first.twist);

    return {
        .translation = first.translation + rotation.rotate_vec3(second.translation),
        .twist = nearest_generalized_twist(first.twist + second.twist),
    };
}

fn GeneralizedMotion inverse_generalized_motion(GeneralizedMotion motion, double[<3>] up) @private {
    double twist = -motion.twist;
    Quaternion rotation = generalized_twist_rotation(up, twist);

    return { .translation = rotation.rotate_vec3(-motion.translation), .twist = twist };
}

fn double[<3>] generalized_pivot_displacement(double[<3>] up, double twist, double[<3>] pivot) @private {
    double[<3>] radial = pivot - up * up.dot(pivot);
    double half_sine = math::sin(twist * 0.5);

    return radial * (2 * half_sine * half_sine) - up.cross(pivot) * math::sin(twist);
}

fn double generalized_twist_angle(Quaternion rotation, double[<3>] up) @local {
    double projected = rotation.v.x * up.x + rotation.v.y * up.y + rotation.v.z * up.z;
    if (projected == 0 && rotation.v.w == 0) return 0;

    return 2 * math::atan2(projected, rotation.v.w);
}

fn double nearest_generalized_twist(double twist) @local {
    return twist - GENERALIZED_TWO_PI * math::round(twist / GENERALIZED_TWO_PI);
}

fn Quaternion generalized_twist_rotation(double[<3>] up, double twist) @local {
    double sine = math::sin(twist * 0.5);

    return { .v = { up.x * sine, up.y * sine, up.z * sine, math::cos(twist * 0.5) } };
}

fn GeneralizedMotion generalized_endpoint_motion(
    CapturedMotionChain* chain,
    GeneralizedMotionReference* reference,
    GeneralizedMotionFrame endpoint,
) @local {
    double[<3>] displacement = endpoint.position - reference.frame.position;
    for (uint axis = 0; axis < 3; axis++) {
        if (!chain.extraction.translation_axes[axis]) displacement[axis] = 0;
    }

    double twist;
    if (chain.extraction.twist) {
        twist = nearest_generalized_twist(generalized_twist_angle(endpoint.rotation, reference.up) - reference.twist);
    }

    return {
        .translation = displacement + generalized_pivot_displacement(reference.up, twist, reference.frame.position),
        .twist = twist,
    };
}

fn GeneralizedMotion generalized_cycle_power(
    GeneralizedMotion cycle,
    double count,
    double[<3>] up,
) @local {
    if (count < 0) {
        cycle = inverse_generalized_motion(cycle, up);
        count = -count;
    }

    GeneralizedMotion result;
    while (count >= 1) {
        double half = math::floor(count / 2);
        if (count - 2 * half >= 1) result = compose_generalized_motion(result, cycle, up);
        count = half;
        if (count >= 1) cycle = compose_generalized_motion(cycle, cycle, up);
    }

    return result;
}

fn GeneralizedMotion generalized_motion_trajectory(
    CapturedMotionChain* chain,
    AnimationClip* clip,
    GeneralizedMotionReference* reference,
    double time,
    bool loop,
    StepSampleSide side,
) @private {
    if (!loop) {
        float clamped = (float)math::clamp(time, 0.0, (double)reference.duration);
        return generalized_endpoint_motion(
            chain: chain,
            reference: reference,
            endpoint: sample_generalized_endpoint(
                chain: chain,
                clip: clip,
                time: clamped,
                side: side,
            ),
        );
    }

    double cycles = math::floor(time / (double)reference.duration);
    double phase = time - cycles * (double)reference.duration;
    if (phase == 0 && side == StepSampleSide.LEFT) {
        cycles--;
        phase = reference.duration;
    }

    GeneralizedMotion partial = generalized_endpoint_motion(
        chain: chain,
        reference: reference,
        endpoint: sample_generalized_endpoint(
            chain: chain,
            clip: clip,
            time: (float)phase,
            side: side,
        ),
    );

    return compose_generalized_motion(
        first: generalized_cycle_power(reference.cycle, cycles, reference.up),
        second: partial,
        up: reference.up,
    );
}

fn GeneralizedMotionFrame generalized_cycle_anchor(GeneralizedMotionReference* reference, double time) @private {
    double cycles = math::floor(time / (double)reference.duration);
    GeneralizedMotion motion = generalized_cycle_power(reference.cycle, cycles, reference.up);

    return generalized_frame_from_motion(motion, reference.up);
}
