module c3d::anim;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::scene;
import std::math;

struct ChannelSums @private {
    Vec3 translation;
    float translation_weight;
    Vec4 rotation;
    float rotation_weight;
    Vec3 scale;
    float scale_weight;
}

fn void blend_instance(Animator* animator, AssetStore* assets, ModelInstance* instance) @private {
    Transform[] result = alloc::new_array(tmem, Transform, instance.nodes.len);
    result[..] = instance.base_pose[..];
    ChannelSums[] sums = alloc::new_array(tmem, ChannelSums, instance.nodes.len);
    float[][] morph_result = alloc::new_array(tmem, float[], instance.base_morph_weights.len);
    float[][] morph_sums = alloc::new_array(tmem, float[], instance.base_morph_weights.len);
    float[] morph_weights = alloc::new_array(tmem, float, instance.base_morph_weights.len);
    foreach (index, base : instance.base_morph_weights) {
        morph_result[index] = alloc::new_array(tmem, float, base.len);
        morph_result[index][..] = base[..];
        morph_sums[index] = alloc::new_array(tmem, float, base.len);
    }

    uint max_stride;
    bool[MAX_ANIMATION_LAYERS] active;
    foreach (id : animator.order[:animator.action_count]) {
        Action* action = animator.actions.get(id);
        if (action.weight <= 0) continue;
        active[action.layer] = true;
        foreach (&track : assets.clip(action.clip).data.tracks) max_stride = math::max(max_stride, track.stride());
    }
    float[] scratch = alloc::new_array(tmem, float, max_stride);

    foreach (layer, used : active) {
        if (!used) continue;
        sums[..] = (ChannelSums){};
        morph_weights[..] = 0;
        foreach (values : morph_sums) values[..] = 0;

        foreach (id : animator.order[:animator.action_count]) {
            Action* action = animator.actions.get(id);
            if (action.layer != layer || action.additive || action.weight <= 0) continue;

            AnimationClip* clip = &assets.clip(action.clip).data;
            foreach (track_index, &track : clip.tracks) {
                uint node = clip.targets[track.target];
                Node* present = instance.present_node(node);
                if (!present || !action.mask[node]) continue;
                if (track.path == TargetPath.MORPH_WEIGHTS && !animator.scene.has(present, Mesh)) continue;

                float[] sample = scratch[:track.stride()];
                sample_track(
                    track: track,
                    time: action.time,
                    cursor: &action.cursors[track_index],
                    out: sample,
                );
                pin_root_sample(action, (uint)track_index, sample);

                switch (track.path) {
                    case TRANSLATION:
                        sums[node].translation += (Vec3){ sample[0], sample[1], sample[2] } * action.weight;
                        sums[node].translation_weight += action.weight;
                    case ROTATION:
                        Vec4 rotation = { sample[0], sample[1], sample[2], sample[3] };
                        if (rotation.dot(result[node].rotation.v) < 0) rotation = -rotation;
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

        foreach (id : animator.order[:animator.action_count]) {
            Action* action = animator.actions.get(id);
            if (action.layer != layer || !action.additive || action.weight <= 0) continue;

            AnimationClip* clip = &assets.clip(action.clip).data;
            usz reference_offset;
            foreach (track_index, &track : clip.tracks) {
                uint stride = track.stride();
                float[] reference = action.reference[reference_offset:stride];
                reference_offset += stride;
                uint node = clip.targets[track.target];
                Node* present = instance.present_node(node);
                if (!present || !action.mask[node]) continue;
                if (track.path == TargetPath.MORPH_WEIGHTS && !animator.scene.has(present, Mesh)) continue;

                float[] sample = scratch[:stride];
                sample_track(
                    track: track,
                    time: action.time,
                    cursor: &action.cursors[track_index],
                    out: sample,
                );

                switch (track.path) {
                    case TRANSLATION:
                        result[node].position += (Vec3){
                            sample[0] - reference[0], sample[1] - reference[1], sample[2] - reference[2],
                        } * action.weight;
                    case ROTATION:
                        Quat origin = { .v = { reference[0], reference[1], reference[2], reference[3] } };
                        Quat current = { .v = { sample[0], sample[1], sample[2], sample[3] } };
                        Quat delta = origin.conjugate().mul(current).normalize();
                        if (delta.v.w < 0) delta = -delta;
                        Quat weighted = quaternion::IDENTITY.nlerp(delta, action.weight);
                        result[node].rotation = result[node].rotation.mul(weighted).normalize();
                    case SCALE:
                        result[node].scale += (Vec3){
                            sample[0] - reference[0], sample[1] - reference[1], sample[2] - reference[2],
                        } * action.weight;
                    case MORPH_WEIGHTS:
                        usz mesh = mesh_index(instance, node);
                        foreach (index, value : sample) {
                            morph_result[mesh][index] += (value - reference[index]) * action.weight;
                        }
                }
            }
        }
    }

    foreach (usz index, pose : result) {
        Node* node = instance.present_node(index);
        if (node) node.local = pose;
    }
    foreach (index, values : morph_result) {
        Node* node = instance.present_node(instance.mesh_nodes[index]);
        if (!node) continue;
        Mesh* mesh = animator.scene.get(node, Mesh);
        if (mesh) mesh.morph_weights[..] = values[..];
    }
}

fn usz mesh_index(ModelInstance* instance, uint node) @private {
    usz index;
    while (instance.mesh_nodes[index] != node) index++;
    return index;
}

fn float residual(float total) @private => math::max(0.0f, 1 - total);

fn Vec3 blend_vec3(Vec3 sum, float total, Vec3 below) @private {
    return (sum + below * residual(total)) / math::max(1.0f, total);
}
