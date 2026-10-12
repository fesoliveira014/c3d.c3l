module c3d::anim;

import c3d;
import c3d::asset;
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
    ClipTime time,
) @private {
    GeneralizedMotionFrame world = GENERALIZED_FRAME_IDENTITY;

    for (sz index = chain.nodes.len; index > 0; index--) {
        CapturedMotionNode* node = &chain.nodes[index - 1];
        GeneralizedMotionFrame local = generalized_frame_from_transform(node.baseline);
        double[4] value;

        if (node.translation_track != NO_MOTION_TRACK) {
            sample_endpoint_track(&clip.tracks[node.translation_track], time, value[:3]);
            local.position = { value[0], value[1], value[2] };
        }

        if (node.rotation_track != NO_MOTION_TRACK) {
            sample_endpoint_track(&clip.tracks[node.rotation_track], time, value[..]);
            local.rotation = { .v = { value[0], value[1], value[2], value[3] } };
        }

        if (node.scale_track != NO_MOTION_TRACK) {
            sample_endpoint_track(&clip.tracks[node.scale_track], time, value[:3]);
            local.scale = (value[0] + value[1] + value[2]) / 3;
        }

        world = compose_generalized_frames(world, local);
    }

    return world;
}

fn void sample_endpoint_track(Track* track, ClipTime time, double[] value) @local {
    // A cursor past the last key bisects the keys rather than walking from the first.
    uint cursor = uint::max;
    sample_track_double(
        track: track,
        time: track_clip_time(track, time),
        cursor: &cursor,
        value: value,
        side: time.side,
    );
}

fn ClipTime fixed_clip_time(float time, StepSampleSide side = StepSampleSide.EXACT) @private {
    return { .time = time, .ahead = time, .side = side };
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
        .frame = sample_generalized_endpoint(chain, clip, fixed_clip_time(0, side)),
        .up = up,
        .duration = clip.duration,
    };
    reference.twist = generalized_twist_angle(reference.frame.rotation, up);

    reference.cycle = generalized_endpoint_motion(
        chain: chain,
        reference: &reference,
        endpoint: sample_generalized_endpoint(chain, clip, fixed_clip_time(clip.duration)),
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
        side: StepSampleSide.EXACT,
    );

    return compose_generalized_motion(inverse_generalized_motion(first, reference.up), last, reference.up);
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
        local.position = { (float)position.x, (float)position.y, (float)position.z };
        local.scale *= (float)correction.scale;
        if (!inertial_rotation_valid(rotation)) continue;

        rotation = inertial_normalize_rotation(correction.rotation.mul(rotation));
        local.rotation = { .v = {
            (float)rotation.v.x, (float)rotation.v.y, (float)rotation.v.z, (float)rotation.v.w,
        } };
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
) @private {
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
            endpoint: sample_generalized_endpoint(chain, clip, fixed_clip_time(clamped, side)),
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
        endpoint: sample_generalized_endpoint(chain, clip, fixed_clip_time((float)phase, side)),
    );

    return compose_generalized_motion(
        first: generalized_cycle_power(reference.cycle, cycles, reference.up),
        second: partial,
        up: reference.up,
    );
}

<* Fold admitted endpoint motion and pin its extracted part out of the pose.
   @param [&in] playback : "Borrows actions until owner structure changes."
   @param [&in] assets : "Owns live immutable clips."
   @param destination : "Raw evaluated locals; top-level branches are compensated in place."
   @param [&in] chain : "Captured chain shared by every generalized action."
   @param dt : "Zero reports no motion."
   @param onset : "Pins sample STEP keys on the playback side, as the pose does."
   @param lead : "Clocks and fades to step ahead, as the pose samples them."
   @require math::is_finite(dt) && dt >= 0 *>
fn GeneralizedMotion evaluate_generalized_playback_motion(
    PlaybackView* playback,
    AssetStore* assets,
    PoseDestination destination,
    CapturedMotionChain* chain,
    double dt,
    bool onset = false,
    LeadStep lead = LeadStep.NONE,
) @private {
    if (playback.root_node >= destination.pose.len || !destination.present[playback.root_node]) return {};

    GeneralizedMotion delta;
    GeneralizedMotion offset;

    for (uint layer = 0; layer < MAX_ANIMATION_LAYERS; layer++) {
        GeneralizedMotion delta_sum;
        GeneralizedMotion offset_sum;
        double translation_weight;
        double twist_weight;

        foreach (id : playback.order[:*playback.action_count]) {
            Action* action = playback.actions.get(id);
            if (action.layer != layer || action.additive) continue;

            double weight = masked_weight(action, playback.root_node, action_lead_weight(action, lead));
            if (weight <= 0) continue;

            AnimationClip* clip = &assets.clip(action.clip).data;
            GeneralizedMotion action_delta;
            GeneralizedMotion action_offset;

            if (action.motion_chain) {
                if (dt > 0 && action.clock_delta != 0) {
                    action_delta = generalized_motion_delta(
                        chain: action.motion_chain,
                        clip: clip,
                        reference: &action.motion_reference,
                        begin: action.previous_time,
                        end: action.previous_time + action.clock_delta,
                        loop: action.loop,
                        begin_side: motion_begin_sample_side(
                            action: action,
                            onset: playback.inertial != null && playback.inertial.control.onset_pending,
                        ),
                    );
                }

                ClipTime time = action_clip_time(
                    action: action,
                    clip: clip,
                    onset: onset,
                    lead: lead,
                );
                GeneralizedMotionFrame endpoint = sample_generalized_endpoint(action.motion_chain, clip, time);
                action_offset = generalized_endpoint_motion(action.motion_chain, &action.motion_reference, endpoint);
            }

            bool translation;
            bool twist;
            generalized_playback_channels(
                clip: clip,
                chain: chain,
                translation: &translation,
                twist: &twist,
            );

            if (translation) {
                delta_sum.translation += action_delta.translation * weight;
                offset_sum.translation += action_offset.translation * weight;
                translation_weight += weight;
            }

            if (twist) {
                delta_sum.twist += action_delta.twist * weight;
                offset_sum.twist += action_offset.twist * weight;
                twist_weight += weight;
            }
        }

        fold_generalized_layer(
            below: &delta,
            sum: delta_sum,
            translation_weight: translation_weight,
            twist_weight: twist_weight,
        );
        fold_generalized_layer(
            below: &offset,
            sum: offset_sum,
            translation_weight: translation_weight,
            twist_weight: twist_weight,
        );
    }

    double[<3>] up = generalized_chain_up(chain);
    GeneralizedMotionFrame correction = inverse_generalized_frame(generalized_frame_from_motion(offset, up));
    compensate_generalized_branches(chain, destination.pose, correction);

    return delta;
}

fn CapturedMotionChain* generalized_playback_chain(PlaybackView* playback) @private {
    foreach (id : playback.order[:*playback.action_count]) {
        Action* action = playback.actions.get(id);
        if (action.motion_chain) return action.motion_chain;
    }

    return null;
}

fn double[<3>] generalized_chain_up(CapturedMotionChain* chain) @private {
    double[<3>] up = { chain.extraction.up.x, chain.extraction.up.y, chain.extraction.up.z };

    return up / up.length();
}

fn void fold_generalized_layer(
    GeneralizedMotion* below,
    GeneralizedMotion sum,
    double translation_weight,
    double twist_weight,
) @local {
    below.translation = (sum.translation + below.translation * math::max(0.0, 1 - translation_weight))
      / math::max(1.0, translation_weight);
    below.twist = (sum.twist + below.twist * math::max(0.0, 1 - twist_weight)) / math::max(1.0, twist_weight);
}

fn void generalized_playback_channels(
    AnimationClip* clip,
    CapturedMotionChain* chain,
    bool* translation,
    bool* twist,
) @local {
    *translation = false;
    *twist = false;

    foreach (track : clip.tracks) {
        uint node = clip.targets[track.target];
        foreach (ancestor : chain.nodes) {
            if (ancestor.model_node != node) continue;

            if (track.path == TargetPath.TRANSLATION || track.path == TargetPath.ROTATION
              || track.path == TargetPath.SCALE) *translation = true;
            if (track.path == TargetPath.ROTATION) *twist = true;
        }
    }
}
