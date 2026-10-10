module c3d::anim;

import c3d;
import c3d::asset;
import std::math;

struct GeneralizedPlaybackCycle @private {
    AnimationActionId action;
    GeneralizedMotion motion;
}

struct GeneralizedPlaybackState @private {
    ModelId model;
    uint root_node;
    RootExtractionDesc extraction;
    Vec3 instance_scale;
    bool initialized;
    GeneralizedMotionFrame consumed;
    GeneralizedMotionFrame anchor;
    GeneralizedMotionFrame cycle_anchor;
    GeneralizedMotion cycle_rate;
    double[<3>] carrier_translation_rate;
    double carrier_twist_rate;
    GeneralizedPlaybackCycle[MAX_ACTIONS] cycles;
}

<* Capture admitted identity and discard prior action cycle rows.
   @param [&inout] state : "Fixed owner storage; no action resources are retained."
   @param [&in] playback : "Contains at least one admitted generalized action."
   @param consumed : "Final motion already consumed by the application."
   @param anchor : "Target reference rebase, or identity for ordinary playback."
   @require generalized_playback_chain(playback) != null *>
fn void initialize_generalized_playback(
    GeneralizedPlaybackState* state,
    PlaybackView* playback,
    GeneralizedMotionFrame consumed = GENERALIZED_FRAME_IDENTITY,
    GeneralizedMotionFrame anchor = GENERALIZED_FRAME_IDENTITY,
) @private {
    CapturedMotionChain* chain = generalized_playback_chain(playback);
    *state = {
        .model = playback.model,
        .root_node = chain.root_node,
        .extraction = chain.extraction,
        .instance_scale = chain.instance_scale,
        .initialized = true,
        .consumed = consumed,
        .anchor = anchor,
        .cycle_anchor = GENERALIZED_FRAME_IDENTITY,
    };
}

<* Fold admitted endpoint motion after clocks and pose evaluation.
   @param [&in] playback : "Borrows actions until owner structure changes."
   @param [&in] assets : "Owns live immutable clips."
   @param [&inout] state : "Retains only keyed cycle transforms and captured identity."
   @param dt : "Zero reports no motion and advances no cycle rows."
   @require state.initialized
   @require math::is_finite(dt) && dt >= 0
   @require playback.root_node == state.root_node
   @require playback.actions.items.len <= MAX_ACTIONS *>
fn GeneralizedMotion evaluate_generalized_playback_motion(
    PlaybackView* playback,
    AssetStore* assets,
    PoseDestination destination,
    GeneralizedPlaybackState* state,
    double dt,
) @private {
    if (playback.root_node >= destination.pose.len || !destination.present[playback.root_node]) return {};

    CapturedMotionChain* chain = generalized_playback_chain(playback);
    if (!chain) return {};

    double[<3>] up = { state.extraction.up.x, state.extraction.up.y, state.extraction.up.z };
    up /= up.length();
    GeneralizedMotion result;
    GeneralizedMotion cycle_result;
    GeneralizedMotion cycle_rate;

    for (uint layer = 0; layer < MAX_ANIMATION_LAYERS; layer++) {
        GeneralizedMotion sum;
        GeneralizedMotion cycle_sum;
        GeneralizedMotion cycle_rate_sum;
        double translation_weight;
        double translation_weight_rate;
        double twist_weight;
        double twist_weight_rate;

        foreach (id : playback.order[:*playback.action_count]) {
            Action* action = playback.actions.get(id);
            if (action.layer != layer || action.additive) continue;

            GeneralizedMotion delta;
            GeneralizedMotion cycles;
            AnimationClip* clip = &assets.clip(action.clip).data;
            if (action.motion_chain) {
                GeneralizedPlaybackCycle* retained = &state.cycles[id.index];
                if (!c3d::same_id(retained.action, id)) {
                    *retained = { .action = id };
                }

                if (dt > 0 && action.clock_delta != 0) {
                    delta = generalized_motion_delta(
                        chain: action.motion_chain,
                        clip: clip,
                        reference: &action.motion_reference,
                        begin: action.previous_time,
                        end: action.previous_time + action.clock_delta,
                        loop: action.loop,
                    );

                    if (action.loop) {
                        double duration = clip.duration;
                        double crossings = math::floor((action.previous_time + action.clock_delta) / duration)
                          - math::floor(action.previous_time / duration);
                        if (crossings != 0) {
                            GeneralizedMotionFrame crossing = generalized_cycle_anchor(
                                &action.motion_reference, crossings * duration);
                            GeneralizedMotion motion = {
                                .translation = crossing.position,
                                .twist = action.motion_reference.cycle.twist * crossings,
                            };
                            retained.motion = compose_generalized_motion(retained.motion, motion, up);
                        }
                    }
                }

                cycles = retained.motion;
            }

            double weight = action_node_weight(action, playback.root_node);
            double weight_rate = action_node_weight_rate(action, playback.root_node);
            if (weight <= 0 && weight_rate == 0) continue;

            bool translation;
            bool twist;
            generalized_playback_channels(
                clip: clip,
                chain: chain,
                translation: &translation,
                twist: &twist,
            );
            if (translation) {
                sum.translation += delta.translation * weight;
                cycle_sum.translation += cycles.translation * weight;
                cycle_rate_sum.translation += cycles.translation * weight_rate;
                translation_weight += weight;
                translation_weight_rate += weight_rate;
            }

            if (twist) {
                sum.twist += delta.twist * weight;
                cycle_sum.twist += cycles.twist * weight;
                cycle_rate_sum.twist += cycles.twist * weight_rate;
                twist_weight += weight;
                twist_weight_rate += weight_rate;
            }
        }

        double translation_below = math::max(0.0, 1 - translation_weight);
        double translation_total = math::max(1.0, translation_weight);
        result.translation = (sum.translation + result.translation * translation_below) / translation_total;
        double below_rate = translation_weight < 1 || (translation_weight == 1 && translation_weight_rate < 0)
          ? -translation_weight_rate : 0;
        double divisor_rate = translation_weight > 1 || (translation_weight == 1 && translation_weight_rate > 0)
          ? translation_weight_rate : 0;
        double[<3>] folded_cycle =
          (cycle_sum.translation + cycle_result.translation * translation_below) / translation_total;
        cycle_rate.translation = (cycle_rate_sum.translation + cycle_rate.translation * translation_below
          + cycle_result.translation * below_rate - folded_cycle * divisor_rate) / translation_total;
        cycle_result.translation = folded_cycle;
        double twist_below = math::max(0.0, 1 - twist_weight);
        double twist_total = math::max(1.0, twist_weight);
        result.twist = (sum.twist + result.twist * twist_below) / twist_total;
        below_rate = twist_weight < 1 || (twist_weight == 1 && twist_weight_rate < 0) ? -twist_weight_rate : 0;
        divisor_rate = twist_weight > 1 || (twist_weight == 1 && twist_weight_rate > 0) ? twist_weight_rate : 0;
        double folded_twist = (cycle_sum.twist + cycle_result.twist * twist_below) / twist_total;
        cycle_rate.twist = (cycle_rate_sum.twist + cycle_rate.twist * twist_below
          + cycle_result.twist * below_rate - folded_twist * divisor_rate) / twist_total;
        cycle_result.twist = folded_twist;
    }

    state.cycle_anchor = generalized_frame_from_motion(cycle_result, up);
    state.cycle_rate = cycle_rate;

    return result;
}

<* Consume final published motion and compensate each top-level branch once.
   @param [&inout] state : "Receives the exact delta after any inertial correction."
   @param destination : "Contains the uncorrected KEEP-equivalent local pose."
   @param [in] published : "Optional exact float delta emitted to the application."
   @require state.initialized *>
fn void finish_generalized_playback(
    GeneralizedPlaybackState* state,
    PlaybackView* playback,
    PoseDestination destination,
    GeneralizedMotion final_motion,
    RootMotionDelta* published = null,
    double dt = 0,
    PoseVelocity[] velocity = {},
) @private {
    CapturedMotionChain* chain = generalized_playback_chain(playback);
    if (!chain) return;

    double[<3>] up = { state.extraction.up.x, state.extraction.up.y, state.extraction.up.z };
    up /= up.length();
    GeneralizedMotionFrame emitted = generalized_frame_from_motion(final_motion, up);
    if (published) {
        emitted.position = inertial_pose_vector(published.translation);
        emitted.rotation = inertial_normalize_rotation(inertial_pose_rotation(published.rotation));
    }

    if (dt > 0) {
        state.carrier_translation_rate = state.consumed.rotation.rotate_vec3(emitted.position / dt);
        state.carrier_twist_rate = final_motion.twist / dt;
    }
    state.consumed = compose_generalized_frames(state.consumed, emitted);

    compensate_generalized_playback_target(
        state: state,
        playback: playback,
        destination: destination,
        velocity: velocity,
    );
}

<* Transform raw target locals and rates into the displayed carrier frame.
   @param [&in] state : "Consumed transform, fixed target anchor and final published carrier rates."
   @param destination : "Only the captured top-level branches are modified."
   @param velocity : "Optional physical local rates; descendants keep their parent-local rates."
   @require state.initialized
   @require velocity.len == 0 || velocity.len == destination.pose.len *>
fn void compensate_generalized_playback_target(
    GeneralizedPlaybackState* state,
    PlaybackView* playback,
    PoseDestination destination,
    PoseVelocity[] velocity = {},
) @private {
    CapturedMotionChain* chain = generalized_playback_chain(playback);
    if (!chain) return;

    GeneralizedMotionFrame target_anchor = compose_generalized_frames(state.anchor, state.cycle_anchor);
    GeneralizedMotionFrame correction = generalized_branch_correction(state.consumed, target_anchor);

    if (velocity.len) {
        double[<3>] up = { state.extraction.up.x, state.extraction.up.y, state.extraction.up.z };
        up /= up.length();
        Quaternion inverse_rotation = state.consumed.rotation.conjugate();
        double[<3>] anchor_translation_rate = state.anchor.rotation.rotate_vec3(
            state.cycle_rate.translation * state.anchor.scale);
        double[<3>] anchor_angular_rate = state.anchor.rotation.rotate_vec3(up * state.cycle_rate.twist);
        double[<3>] carrier_angular_rate = up * state.carrier_twist_rate;
        double[<3>] angular_rate = inverse_rotation.rotate_vec3(anchor_angular_rate - carrier_angular_rate);
        double[<3>] translation_rate = inverse_rotation.rotate_vec3(
            anchor_translation_rate - state.carrier_translation_rate) / state.consumed.scale
          - inverse_rotation.rotate_vec3(carrier_angular_rate).cross(correction.position);

        foreach (node : chain.top_level_nodes) {
            PoseVelocity* rate = &velocity[node];
            double[<3>] position = correction.rotation.rotate_vec3(
                inertial_pose_vector(destination.pose[node].position) * correction.scale);
            rate.translation = translation_rate + angular_rate.cross(position)
              + correction.rotation.rotate_vec3(rate.translation * correction.scale);
            rate.angular = angular_rate + correction.rotation.rotate_vec3(rate.angular);
            rate.scale *= correction.scale;
        }
    }

    compensate_generalized_branches(chain, destination.pose, correction);
}

<* Compose the admitted motion-node frame from existing local pose storage.
   @require generalized_playback_chain(playback) != null *>
fn GeneralizedMotionFrame generalized_playback_pose_endpoint(
    PlaybackView* playback,
    Transform[] pose,
) @private {
    CapturedMotionChain* chain = generalized_playback_chain(playback);
    GeneralizedMotionFrame result = GENERALIZED_FRAME_IDENTITY;

    for (sz index = chain.nodes.len; index > 0; index--) {
        result = compose_generalized_frames(
            result, generalized_frame_from_transform(pose[chain.nodes[index - 1].model_node]));
    }

    return result;
}

<* Anchor a blended target onset to the displayed source motion-node frame.
   @param [&inout] state : "Preserves consumed motion and derived carrier rates."
   @param target_onset : "Raw blended target frame with directional onset sampling already applied."
   @param destination_source : "Displayed source locals, before the target replaces them."
   @require generalized_playback_chain(playback) != null
   @require target_onset.scale > 0 *>
fn double initialize_transition_anchor(
    GeneralizedPlaybackState* state,
    PlaybackView* playback,
    GeneralizedMotionFrame target_onset,
    PoseDestination destination_source,
) @private {
    GeneralizedMotionFrame consumed = state.initialized ? state.consumed : GENERALIZED_FRAME_IDENTITY;
    double[<3>] translation_rate = state.carrier_translation_rate;
    double twist_rate = state.carrier_twist_rate;
    GeneralizedMotionFrame source = generalized_playback_pose_endpoint(playback, destination_source.pose);
    source.scale = 1;
    target_onset.scale = 1;
    GeneralizedMotionFrame carrier = compose_generalized_frames(consumed, source);
    GeneralizedMotionFrame anchor = generalized_reference_anchor(carrier, target_onset);

    initialize_generalized_playback(
        state: state,
        playback: playback,
        consumed: consumed,
        anchor: anchor,
    );
    state.carrier_translation_rate = translation_rate;
    state.carrier_twist_rate = twist_rate;

    return 1;
}
fn CapturedMotionChain* generalized_playback_chain(PlaybackView* playback) @private {
    foreach (id : playback.order[:*playback.action_count]) {
        Action* action = playback.actions.get(id);
        if (action.motion_chain) return action.motion_chain;
    }

    return null;
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
