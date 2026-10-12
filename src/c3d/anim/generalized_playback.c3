module c3d::anim;

import c3d;
import c3d::asset;
import std::math;

<* Fold admitted endpoint motion and pin its extracted part out of the pose.
   @param [&in] playback : "Borrows actions until owner structure changes."
   @param [&in] assets : "Owns live immutable clips."
   @param destination : "Raw evaluated locals; top-level branches are compensated in place."
   @param [&in] chain : "Captured chain shared by every generalized action."
   @param dt : "Zero reports no motion."
   @param onset : "Pins sample STEP keys on the playback side, as the pose does."
   @param velocity : "Optional raw physical local rates, transformed with their branches."
   @require math::is_finite(dt) && dt >= 0
   @require velocity.len == 0 || velocity.len == destination.pose.len *>
fn GeneralizedMotion evaluate_generalized_playback_motion(
    PlaybackView* playback,
    AssetStore* assets,
    PoseDestination destination,
    CapturedMotionChain* chain,
    double dt,
    bool onset = false,
    PoseVelocity[] velocity = {},
) @private {
    if (playback.root_node >= destination.pose.len || !destination.present[playback.root_node]) return {};

    GeneralizedMotion delta;
    GeneralizedMotion offset;
    GeneralizedMotion offset_rate;

    for (uint layer = 0; layer < MAX_ANIMATION_LAYERS; layer++) {
        GeneralizedMotion delta_sum;
        GeneralizedMotion offset_sum;
        GeneralizedMotion offset_rate_sum;
        double translation_weight;
        double twist_weight;

        foreach (id : playback.order[:*playback.action_count]) {
            Action* action = playback.actions.get(id);
            if (action.layer != layer || action.additive) continue;

            double weight = action_node_weight(action, playback.root_node);
            if (weight <= 0) continue;

            AnimationClip* clip = &assets.clip(action.clip).data;
            GeneralizedMotion action_delta;
            GeneralizedMotion action_offset;
            GeneralizedMotion action_offset_rate;

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

                GeneralizedFrameRate endpoint_rate;
                GeneralizedMotionFrame endpoint = sample_generalized_endpoint(
                    chain: action.motion_chain,
                    clip: clip,
                    time: action.time,
                    side: action_sample_side(action, onset),
                    rate: velocity.len ? &endpoint_rate : null,
                );
                action_offset = generalized_endpoint_motion(action.motion_chain, &action.motion_reference, endpoint);

                if (velocity.len) {
                    action_offset_rate = generalized_endpoint_motion_rate(
                        chain: action.motion_chain,
                        reference: &action.motion_reference,
                        endpoint: endpoint,
                        rate: endpoint_rate,
                    );
                    double speed = action_analytic_speed(action);
                    action_offset_rate.translation *= speed;
                    action_offset_rate.twist *= speed;
                }
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
                offset_rate_sum.translation += action_offset_rate.translation * weight;
                translation_weight += weight;
            }

            if (twist) {
                delta_sum.twist += action_delta.twist * weight;
                offset_sum.twist += action_offset.twist * weight;
                offset_rate_sum.twist += action_offset_rate.twist * weight;
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
        fold_generalized_layer(
            below: &offset_rate,
            sum: offset_rate_sum,
            translation_weight: translation_weight,
            twist_weight: twist_weight,
        );
    }

    pin_generalized_branches(
        chain: chain,
        pose: destination.pose,
        velocity: velocity,
        offset: offset,
        offset_rate: offset_rate,
    );

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

<* @require velocity.len == 0 || velocity.len == pose.len *>
fn void pin_generalized_branches(
    CapturedMotionChain* chain,
    Transform[] pose,
    PoseVelocity[] velocity,
    GeneralizedMotion offset,
    GeneralizedMotion offset_rate,
) @local {
    double[<3>] up = generalized_chain_up(chain);
    GeneralizedMotionFrame correction = inverse_generalized_frame(generalized_frame_from_motion(offset, up));

    if (velocity.len) {
        double[<3>] angular_rate = up * -offset_rate.twist;
        double[<3>] translation_rate = angular_rate.cross(correction.position)
          - correction.rotation.rotate_vec3(offset_rate.translation);

        foreach (node : chain.top_level_nodes) {
            PoseVelocity* rate = &velocity[node];
            double[<3>] position = correction.rotation.rotate_vec3(inertial_pose_vector(pose[node].position));
            rate.translation = translation_rate + angular_rate.cross(position)
              + correction.rotation.rotate_vec3(rate.translation);
            rate.angular = angular_rate + correction.rotation.rotate_vec3(rate.angular);
        }
    }

    compensate_generalized_branches(chain, pose, correction);
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
