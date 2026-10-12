module c3d::anim;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::scene;
import std::math;

<* @param lead : "Clocks and fades to step ahead; STEP tracks keep their current key." *>
fn void blend_pose(
    PlaybackView* playback,
    AssetStore* assets,
    PoseDestination destination,
    PoseScratch scratch,
    bool onset = false,
    CapturedMotionChain* consumed_chain = null,
    LeadStep lead = LeadStep.NONE,
) @private {
    Transform[] result = destination.pose;
    ChannelSums[] sums = scratch.channels;
    float[][] morph_result = destination.morph_weights;
    float[][] morph_sums = scratch.morph_sums;
    float[] morph_weights = scratch.morph_weights;
    double[<3>][] scale_values = consumed_chain ? consumed_chain.pose_scale_sums : (double[<3>][]){};

    result[..] = destination.base_pose[..];
    foreach (index, base : destination.base_morph_weights) morph_result[index][..] = base[..];

    bool[MAX_ANIMATION_LAYERS] active;
    foreach (id : playback.order[:*playback.action_count]) {
        Action* action = playback.actions.get(id);
        if (action_lead_weight(action, lead) > 0) active[action.layer] = true;
    }

    float[] samples = scratch.sample;

    foreach (layer, used : active) {
        if (!used) continue;
        sums[..] = (ChannelSums){};
        if (consumed_chain) scale_values[..] = (double[<3>]){};
        morph_weights[..] = 0;
        foreach (values : morph_sums) values[..] = 0;

        foreach (id : playback.order[:*playback.action_count]) {
            Action* action = playback.actions.get(id);
            if (action.layer != layer || action.additive) continue;

            float action_weight = action_lead_weight(action, lead);
            if (action_weight <= 0) continue;

            ClipAsset* clip_asset = assets.clip(action.clip);
            AnimationClip* clip = &clip_asset.data;
            ClipTime time = action_clip_time(
                action: action,
                clip: clip,
                onset: onset,
                lead: lead,
            );
            bool compressed = clip.is_compressed();
            PoseCacheWalk walk = begin_pose_cache_walk(
                cache: !onset && !consumed_chain ? scratch.cache : null,
                clip: action.clip,
                revision: clip_asset.header.revision,
                time: action.time,
            );
            if (walk.entry) {
                blend_shared_action(
                    action: action,
                    clip: clip,
                    destination: destination,
                    scratch: scratch,
                    walk: &walk,
                    action_weight: action_weight,
                );
                continue;
            }

            foreach (track_index, &track : clip.tracks) {
                uint node = clip.targets[track.target];
                if (!destination.present[node] || !action.mask[node]) continue;
                if (track.path == TargetPath.MORPH_WEIGHTS && !destination.mesh_present[node]) continue;

                float weight = masked_weight(action, node, action_weight);
                if (weight <= 0) continue;

                float[] sample = samples[:track.stride()];
                if (!onset && !consumed_chain) {
                    if (compressed) {
                        sample_track(
                            track: track,
                            time: action.time,
                            cursor: &action.cursors[track_index],
                            out: sample,
                        );
                    } else {
                        sample_raw(
                            track: track,
                            time: action.time,
                            cursor: &action.cursors[track_index],
                            out: sample,
                        );
                    }
                } else {
                    sample_pose_channel(
                        action: action,
                        track: track,
                        track_index: (uint)track_index,
                        node: node,
                        time: time,
                        consumed_chain: consumed_chain,
                        sample: sample,
                    );
                }
                pin_root_sample(action, (uint)track_index, sample);

                switch (track.path) {
                    case TRANSLATION:
                        sums[node].translation += (Vec3){ sample[0], sample[1], sample[2] } * weight;
                        sums[node].translation_weight += weight;
                    case ROTATION:
                        Vec4 rotation = { sample[0], sample[1], sample[2], sample[3] };
                        if (rotation.dot(result[node].rotation.v) < 0) rotation = -rotation;
                        sums[node].rotation += rotation * weight;
                        sums[node].rotation_weight += weight;
                    case SCALE:
                        if (consumed_chain) {
                            scale_values[node] +=
                              (double[<3>]){ sample[0], sample[1], sample[2] } * (double)weight;
                        } else {
                            sums[node].scale += (Vec3){ sample[0], sample[1], sample[2] } * weight;
                        }
                        sums[node].scale_weight += weight;
                    case MORPH_WEIGHTS:
                        usz mesh = destination.mesh_indices[node];
                        foreach (index, value : sample) morph_sums[mesh][index] += value * weight;
                        morph_weights[mesh] += weight;
                }
            }
        }

        foreach (index, &pose : result) {
            ChannelSums* sum = &sums[index];
            pose.position = blend_vec3(sum.translation, sum.translation_weight, pose.position);
            pose.rotation = { .v = (sum.rotation + pose.rotation.v * residual(sum.rotation_weight)).normalize() };
            if (consumed_chain) {
                double[<3>] scale = { pose.scale.x, pose.scale.y, pose.scale.z };
                scale = (scale_values[index] + scale * (double)residual(sum.scale_weight))
                  / (double)math::max(1.0f, sum.scale_weight);
                pose.scale = inertial_publish_vector(scale);
            } else {
                pose.scale = blend_vec3(sum.scale, sum.scale_weight, pose.scale);
            }
        }

        foreach (index, values : morph_result) {
            float total = morph_weights[index];
            foreach (weight_index, &value : values) {
                *value = (morph_sums[index][weight_index] + *value * residual(total)) / math::max(1.0f, total);
            }
        }

        foreach (id : playback.order[:*playback.action_count]) {
            Action* action = playback.actions.get(id);
            if (action.layer != layer || !action.additive) continue;

            float action_weight = action_lead_weight(action, lead);
            if (action_weight <= 0) continue;

            AnimationClip* clip = &assets.clip(action.clip).data;
            ClipTime time = action_clip_time(
                action: action,
                clip: clip,
                onset: onset,
                lead: lead,
            );
            usz reference_offset;
            bool compressed = clip.is_compressed();
            foreach (track_index, &track : clip.tracks) {
                uint stride = track.stride();
                float[] reference = action.reference[reference_offset:stride];
                reference_offset += stride;
                uint node = clip.targets[track.target];
                if (!destination.present[node] || !action.mask[node]) continue;
                if (track.path == TargetPath.MORPH_WEIGHTS && !destination.mesh_present[node]) continue;

                float weight = masked_weight(action, node, action_weight);
                if (weight <= 0) continue;

                float[] sample = samples[:stride];
                if (!onset && !consumed_chain) {
                    if (compressed) {
                        sample_track(
                            track: track,
                            time: action.time,
                            cursor: &action.cursors[track_index],
                            out: sample,
                        );
                    } else {
                        sample_raw(
                            track: track,
                            time: action.time,
                            cursor: &action.cursors[track_index],
                            out: sample,
                        );
                    }
                } else {
                    sample_pose_channel(
                        action: action,
                        track: track,
                        track_index: (uint)track_index,
                        node: node,
                        time: time,
                        consumed_chain: consumed_chain,
                        sample: sample,
                    );
                }

                switch (track.path) {
                    case TRANSLATION:
                        result[node].position += (Vec3){
                            sample[0] - reference[0], sample[1] - reference[1], sample[2] - reference[2],
                        } * weight;
                    case ROTATION:
                        Quat origin = { .v = { reference[0], reference[1], reference[2], reference[3] } };
                        Quat current = { .v = { sample[0], sample[1], sample[2], sample[3] } };
                        Quat delta = origin.conjugate().mul(current).normalize();
                        if (delta.v.w < 0) delta = -delta;
                        Quat weighted = quaternion::IDENTITY.nlerp(delta, weight);
                        result[node].rotation = result[node].rotation.mul(weighted).normalize();
                    case SCALE:
                        if (action.additive_scale == AdditiveScaleMode.MULTIPLICATIVE) {
                            for (uint axis = 0; axis < 3; axis++) {
                                double factor = math::pow((double)sample[axis] / reference[axis], (double)weight);
                                result[node].scale[axis] = (float)((double)result[node].scale[axis] * factor);
                            }
                        } else {
                            result[node].scale += (Vec3){
                                sample[0] - reference[0], sample[1] - reference[1], sample[2] - reference[2],
                            } * weight;
                        }
                    case MORPH_WEIGHTS:
                        usz mesh = destination.mesh_indices[node];
                        foreach (index, value : sample) {
                            morph_result[mesh][index] += (value - reference[index]) * weight;
                        }
                }
            }
        }
    }
}

// Duplicates blend_pose's plain branch for actions with an entry: a cache branch inside that loop
// stopped pin_root_sample inlining and cost 4% more instructions.
fn void blend_shared_action(
    Action* action,
    AnimationClip* clip,
    PoseDestination destination,
    PoseScratch scratch,
    PoseCacheWalk* walk,
    float action_weight,
) @local @noinline {
    foreach (track_index, &track : clip.tracks) {
        uint node = clip.targets[track.target];
        if (!destination.present[node] || !action.mask[node]) continue;
        if (track.path == TargetPath.MORPH_WEIGHTS && !destination.mesh_present[node]) continue;

        float weight = masked_weight(action, node, action_weight);
        if (weight <= 0) continue;

        float[] sample = scratch.sample[:track.stride()];
        walk.sample(
            track: track,
            track_index: (uint)track_index,
            time: action.time,
            cursor: &action.cursors[track_index],
            out: sample,
        );
        pin_root_sample(action, (uint)track_index, sample);

        ChannelSums* sum = &scratch.channels[node];
        switch (track.path) {
            case TRANSLATION:
                sum.translation += (Vec3){ sample[0], sample[1], sample[2] } * weight;
                sum.translation_weight += weight;
            case ROTATION:
                Vec4 rotation = { sample[0], sample[1], sample[2], sample[3] };
                if (rotation.dot(destination.pose[node].rotation.v) < 0) rotation = -rotation;
                sum.rotation += rotation * weight;
                sum.rotation_weight += weight;
            case SCALE:
                sum.scale += (Vec3){ sample[0], sample[1], sample[2] } * weight;
                sum.scale_weight += weight;
            case MORPH_WEIGHTS:
                usz mesh = destination.mesh_indices[node];
                foreach (index, value : sample) scratch.morph_sums[mesh][index] += value * weight;
                scratch.morph_weights[mesh] += weight;
        }
    }
}

<*
 Sample one clip at full weight into the destination pose and morph weights.
 Never advances playback; reads the store and writes only the cursors, scratch and destination.
 @param [&in] assets : "Owns the clip."
 @param time : "Seconds; clamped to each track's key range."
 @param [inout] cursors : "Seek hints, one per track; any value is valid."
 @param [&inout] scratch : "Sample buffer at least as wide as the clip's widest track; scratch from the destination's pose storage qualifies."
 @require assets.clips.is_live(clip), cursors.len >= assets.clip(clip).data.tracks.len
 @require destination.pose.len == destination.base_pose.len
 @require destination.present.len == destination.base_pose.len
 @require destination.mesh_present.len == destination.base_pose.len
 @require destination.mesh_indices.len == destination.base_pose.len
 @require destination.morph_weights.len == destination.base_morph_weights.len
*>
fn void sample_pose(
    AssetStore* assets,
    ClipId clip,
    float time,
    uint[] cursors,
    PoseScratch* scratch,
    PoseDestination destination,
) {
    AnimationClip* data = &assets.clip(clip).data;
    Transform[] result = destination.pose;

    // Blending renormalizes every rotation, tracked or not.
    foreach (index, &pose : result) {
        *pose = destination.base_pose[index];
        pose.rotation = { .v = pose.rotation.v.normalize() };
    }
    foreach (index, base : destination.base_morph_weights) destination.morph_weights[index][..] = base[..];

    bool compressed = data.is_compressed();
    foreach (track_index, &track : data.tracks) {
        uint node = data.targets[track.target];
        if (!destination.present[node]) continue;
        if (track.path == TargetPath.MORPH_WEIGHTS && !destination.mesh_present[node]) continue;

        float[] sample = scratch.sample[:track.stride()];
        if (compressed) {
            sample_track(
                track: track,
                time: time,
                cursor: &cursors[track_index],
                out: sample,
            );
        } else {
            sample_raw(
                track: track,
                time: time,
                cursor: &cursors[track_index],
                out: sample,
            );
        }

        switch (track.path) {
            case TRANSLATION:
                result[node].position = (Vec3){ sample[0], sample[1], sample[2] };
            case ROTATION:
                Vec4 rotation = { sample[0], sample[1], sample[2], sample[3] };
                // Blending takes the hemisphere of the pose below it, which is the base pose here.
                if (rotation.dot(destination.base_pose[node].rotation.v) < 0) rotation = -rotation;
                result[node].rotation = { .v = rotation.normalize() };
            case SCALE:
                result[node].scale = (Vec3){ sample[0], sample[1], sample[2] };
            case MORPH_WEIGHTS:
                destination.morph_weights[destination.mesh_indices[node]][:sample.len] = sample[..];
        }
    }
}

fn float residual(float total) @private => math::max(0.0f, 1 - total);

fn Vec3 blend_vec3(Vec3 sum, float total, Vec3 below) @private {
    return (sum + below * residual(total)) / math::max(1.0f, total);
}

fn float action_node_weight(Action* action, uint node) @private => masked_weight(action, node, action.weight);

fn float masked_weight(Action* action, uint node, float weight) @private {
    if (!action.mask[node]) return 0;
    if (!action.weighted_mask.len) return weight;

    return weight * action.weighted_mask[node];
}

fn float action_lead_weight(Action* action, LeadStep lead) @private {
    // Fades always step forward; a group member's weight follows its group, fixed while a transition starts.
    if (lead != LeadStep.FORWARD || action.blend_space || action.fade_rate <= 0) return action.weight;

    float step = action.fade_rate * LEAD_SECONDS;
    float remaining = action.fade_target - action.weight;
    if (math::abs(remaining) <= step) return action.fade_target;

    return action.weight + (remaining < 0 ? -step : step);
}

fn void sample_pose_channel(
    Action* action,
    Track* track,
    uint track_index,
    uint node,
    ClipTime time,
    CapturedMotionChain* consumed_chain,
    float[] sample,
) @local {
    uint* cursor = &action.cursors[track_index];
    bool precise = precise_pose_channel(
        consumed_chain: consumed_chain,
        action: action,
        track: track,
        track_index: track_index,
        node: node,
    );
    if (!precise) {
        sample_track_on_side(
            track: track,
            time: track_clip_time(track, time),
            cursor: cursor,
            out: sample,
            side: time.side,
        );
        return;
    }

    double[4] value;
    sample_track_double(
        track: track,
        time: track_clip_time(track, time),
        cursor: cursor,
        value: value[:sample.len],
        side: time.side,
    );
    foreach (index, component : value[:sample.len]) sample[index] = (float)component;
}

// Consumed chain rotations and scales sample in double precision, as their extraction does.
fn bool precise_pose_channel(
    CapturedMotionChain* consumed_chain,
    Action* action,
    Track* track,
    uint track_index,
    uint node,
) @local {
    if (!consumed_chain || track.path == TargetPath.MORPH_WEIGHTS) return false;
    if (action.motion_chain && captured_motion_track(action.motion_chain, track_index)) return true;

    return (track.path == TargetPath.ROTATION || track.path == TargetPath.SCALE)
      && captured_motion_node(consumed_chain, node);
}

fn bool captured_motion_track(CapturedMotionChain* chain, uint track) @local {
    foreach (node : chain.nodes) {
        if (node.translation_track == track || node.rotation_track == track || node.scale_track == track) return true;
    }

    return false;
}

fn bool captured_motion_node(CapturedMotionChain* chain, uint model_node) @local {
    foreach (node : chain.nodes) if (node.model_node == model_node) return true;

    return false;
}
