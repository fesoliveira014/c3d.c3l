module c3d::anim;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::scene;
import std::math;

fn void blend_pose(
    PlaybackView* playback,
    AssetStore* assets,
    PoseDestination destination,
    PoseScratch scratch,
) @private {
    Transform[] result = destination.pose;
    ChannelSums[] sums = scratch.channels;
    float[][] morph_result = destination.morph_weights;
    float[][] morph_sums = scratch.morph_sums;
    float[] morph_weights = scratch.morph_weights;

    result[..] = destination.base_pose[..];
    foreach (index, base : destination.base_morph_weights) morph_result[index][..] = base[..];

    bool[MAX_ANIMATION_LAYERS] active;
    foreach (id : playback.order[:*playback.action_count]) {
        Action* action = playback.actions.get(id);
        if (action.weight <= 0) continue;
        active[action.layer] = true;
    }

    float[] samples = scratch.sample;

    foreach (layer, used : active) {
        if (!used) continue;
        sums[..] = (ChannelSums){};
        morph_weights[..] = 0;
        foreach (values : morph_sums) values[..] = 0;

        foreach (id : playback.order[:*playback.action_count]) {
            Action* action = playback.actions.get(id);
            if (action.layer != layer || action.additive || action.weight <= 0) continue;

            AnimationClip* clip = &assets.clip(action.clip).data;
            foreach (track_index, &track : clip.tracks) {
                uint node = clip.targets[track.target];
                if (!destination.present[node] || !action.mask[node]) continue;
                if (track.path == TargetPath.MORPH_WEIGHTS && !destination.mesh_present[node]) continue;

                float weight = action_node_weight(action, node);
                if (weight <= 0) continue;

                float[] sample = samples[:track.stride()];
                sample_track(
                    track: track,
                    time: action.time,
                    cursor: &action.cursors[track_index],
                    out: sample,
                );
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
                        sums[node].scale += (Vec3){ sample[0], sample[1], sample[2] } * weight;
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
            pose.scale = blend_vec3(sum.scale, sum.scale_weight, pose.scale);
        }

        foreach (index, values : morph_result) {
            float total = morph_weights[index];
            foreach (weight_index, &value : values) {
                *value = (morph_sums[index][weight_index] + *value * residual(total)) / math::max(1.0f, total);
            }
        }

        foreach (id : playback.order[:*playback.action_count]) {
            Action* action = playback.actions.get(id);
            if (action.layer != layer || !action.additive || action.weight <= 0) continue;

            AnimationClip* clip = &assets.clip(action.clip).data;
            usz reference_offset;
            foreach (track_index, &track : clip.tracks) {
                uint stride = track.stride();
                float[] reference = action.reference[reference_offset:stride];
                reference_offset += stride;
                uint node = clip.targets[track.target];
                if (!destination.present[node] || !action.mask[node]) continue;
                if (track.path == TargetPath.MORPH_WEIGHTS && !destination.mesh_present[node]) continue;

                float weight = action_node_weight(action, node);
                if (weight <= 0) continue;

                float[] sample = samples[:stride];
                if (track.path == TargetPath.SCALE && action.additive_scale == AdditiveScaleMode.MULTIPLICATIVE) {
                    Vec3 scale = sample_multiplicative_scale(track, action.time, &action.cursors[track_index]);
                    sample[0] = scale.x;
                    sample[1] = scale.y;
                    sample[2] = scale.z;
                } else {
                    sample_track(
                        track: track,
                        time: action.time,
                        cursor: &action.cursors[track_index],
                        out: sample,
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
                                double factor = 1 + (double)weight * ((double)sample[axis] / reference[axis] - 1);
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

fn float residual(float total) @private => math::max(0.0f, 1 - total);

fn Vec3 blend_vec3(Vec3 sum, float total, Vec3 below) @private {
    return (sum + below * residual(total)) / math::max(1.0f, total);
}

fn float action_node_weight(Action* action, uint node) @private {
    if (!action.mask[node]) return 0;
    if (!action.weighted_mask.len) return action.weight;

    return action.weight * action.weighted_mask[node];
}
