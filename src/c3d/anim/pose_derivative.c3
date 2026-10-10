module c3d::anim;

import c3d;
import c3d::maths @public;
import std::math;

struct ChannelDerivativeSums @private {
    double[<3>] translation;
    double[<4>] rotation;
    double[<4>] rotation_value;
    double[<3>] scale;
}

struct PoseDerivativeScratch @private {
    ChannelDerivativeSums[] channels;
    PoseVelocity[] velocity;
    double[] morph_sums;
    double[] morph_rates;
    float[] morph_values;
    bool[] consumed_scale;
    double[] sample;
    double[] sample_rate;
}

fn PoseDerivativeScratch*? create_pose_derivative_scratch(
    Allocator allocator,
    usz nodes,
    float[][] base_morph_weights,
    usz sample_width,
) @private {
    PoseDerivativeScratch* scratch = alloc::new_try(allocator, PoseDerivativeScratch)
      ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch destroy_pose_derivative_scratch(allocator, scratch);

    usz morphs;
    foreach (weights : base_morph_weights) morphs += weights.len;

    scratch.channels = alloc::new_array_try(allocator, ChannelDerivativeSums, (sz)nodes)
      ?? c3d::CAPACITY_EXCEEDED~!;
    scratch.velocity = alloc::new_array_try(allocator, PoseVelocity, (sz)nodes)
      ?? c3d::CAPACITY_EXCEEDED~!;
    scratch.morph_sums = alloc::new_array_try(allocator, double, (sz)morphs)
      ?? c3d::CAPACITY_EXCEEDED~!;
    scratch.morph_rates = alloc::new_array_try(allocator, double, (sz)morphs)
      ?? c3d::CAPACITY_EXCEEDED~!;
    scratch.morph_values = alloc::new_array_try(allocator, float, (sz)morphs)
      ?? c3d::CAPACITY_EXCEEDED~!;
    scratch.consumed_scale = alloc::new_array_try(allocator, bool, (sz)nodes)
      ?? c3d::CAPACITY_EXCEEDED~!;
    scratch.sample = alloc::new_array_try(allocator, double, (sz)sample_width)
      ?? c3d::CAPACITY_EXCEEDED~!;
    scratch.sample_rate = alloc::new_array_try(allocator, double, (sz)sample_width)
      ?? c3d::CAPACITY_EXCEEDED~!;

    return scratch;
}

fn void destroy_pose_derivative_scratch(Allocator allocator, PoseDerivativeScratch* scratch) @private {
    alloc::free(allocator, scratch.channels.ptr);
    alloc::free(allocator, scratch.velocity.ptr);
    alloc::free(allocator, scratch.morph_sums.ptr);
    alloc::free(allocator, scratch.morph_rates.ptr);
    alloc::free(allocator, scratch.morph_values.ptr);
    alloc::free(allocator, scratch.consumed_scale.ptr);
    alloc::free(allocator, scratch.sample.ptr);
    alloc::free(allocator, scratch.sample_rate.ptr);
    alloc::free(allocator, scratch);
}

fn StepSampleSide action_sample_side(Action* action, bool onset) @private {
    double speed = action.blend_space ? action.analytic_speed : action.playing ? (double)action.speed : 0;
    if (!onset || speed == 0) return StepSampleSide.EXACT;

    return speed < 0 ? StepSampleSide.LEFT : StepSampleSide.RIGHT;
}

fn void sample_pose_channel(
    Action* action,
    Track* track,
    uint track_index,
    float[] sample,
    PoseDerivativeScratch* derivative,
    bool onset,
) @private {
    if (!derivative && action.motion_chain && track.path != TargetPath.MORPH_WEIGHTS
      && captured_motion_track(action.motion_chain, track_index)) {
        double[4] value;
        double[4] rate;
        sample_track_analytic(
            track: track,
            time: action.time,
            cursor: &action.cursors[track_index],
            value: value[:sample.len],
            rate: rate[:sample.len],
            side: action_sample_side(action, onset),
        );
        foreach (index, component : value[:sample.len]) sample[index] = (float)component;
        return;
    }
    if (!derivative) {
        sample_track(track: track, time: action.time, cursor: &action.cursors[track_index], out: sample);
        return;
    }

    double[] value = derivative.sample[:sample.len];
    double[] rate = derivative.sample_rate[:sample.len];
    sample_track_analytic(
        track: track,
        time: action.time,
        cursor: &action.cursors[track_index],
        value: value,
        rate: rate,
        side: action_sample_side(action, onset),
    );
    double speed = action.blend_space ? action.analytic_speed : action.playing ? (double)action.speed : 0;
    foreach (index, component : value) {
        sample[index] = (float)component;
        rate[index] *= speed;
    }
}

fn double[<4>] normalized_rotation_derivative(double[<4>] value, double[<4>] derivative) @private {
    double length = value.length();
    double[<4>] unit = value / length;

    return (derivative - unit * unit.dot(derivative)) / length;
}

fn double[<4>] rotation_derivative(Quat rotation, double[<3>] angular) @private {
    Quaternion rate = { .v = { angular.x * 0.5, angular.y * 0.5, angular.z * 0.5, 0 } };
    Quaternion orientation = { .v = { rotation.v.x, rotation.v.y, rotation.v.z, rotation.v.w } };

    return rate.mul(orientation).v;
}

fn double[<3>] spatial_rotation_rate(double[<4>] orientation, double[<4>] derivative) @private {
    Quaternion rotation = { .v = orientation };
    Quaternion rate = { .v = derivative };
    Quaternion angular = rate.mul(rotation.conjugate());

    return { 2 * angular.v.x, 2 * angular.v.y, 2 * angular.v.z };
}

fn usz derivative_morph_offset(uint[] widths, uint mesh) @local {
    usz offset;
    foreach (width : widths[:mesh]) offset += width;

    return offset;
}

fn void accumulate_pose_derivative(
    PoseDerivativeScratch* derivative,
    Action* action,
    Track* track,
    uint track_index,
    uint node,
    uint mesh,
    uint[] mesh_widths,
    float[] sample,
    Transform below,
    float weight,
) @private {
    double[] rate = derivative.sample_rate[:sample.len];
    if (!action.extraction.generalized && action.root_motion != RootMotion.KEEP) {
        if (track_index == action.translation_track) rate[0] = rate[2] = 0;
        if (track_index == action.rotation_track && action.root_yaw) {
            pin_analytic_rotation_derivative(action, derivative);
        }
    }

    ChannelDerivativeSums* sums = &derivative.channels[node];
    switch (track.path) {
        case TRANSLATION:
            sums.translation += (double[<3>]){ rate[0], rate[1], rate[2] } * (double)weight;
        case SCALE:
            sums.scale += (double[<3>]){ rate[0], rate[1], rate[2] } * (double)weight;
        case ROTATION:
            Vec4 rotation = { sample[0], sample[1], sample[2], sample[3] };
            double sign = rotation.dot(below.rotation.v) < 0 ? -1 : 1;
            sums.rotation += (double[<4>]){ rate[0], rate[1], rate[2], rate[3] } * ((double)weight * sign);
            sums.rotation_value += (double[<4>]){
                derivative.sample[0], derivative.sample[1], derivative.sample[2], derivative.sample[3],
            } * ((double)weight * sign);
        case MORPH_WEIGHTS:
            usz offset = derivative_morph_offset(mesh_widths, mesh);
            foreach (usz index, value : rate) derivative.morph_sums[offset + index] += value * weight;
    }
}

fn void fold_pose_derivative(
    PoseDerivativeScratch* derivative,
    uint node,
    ChannelSums* sums,
    Transform below,
) @private {
    PoseVelocity* velocity = &derivative.velocity[node];
    ChannelDerivativeSums rates = derivative.channels[node];
    velocity.translation = (rates.translation + velocity.translation * (double)residual(sums.translation_weight))
      / (double)math::max(1.0f, sums.translation_weight);
    velocity.scale = (rates.scale + velocity.scale * (double)residual(sums.scale_weight))
      / (double)math::max(1.0f, sums.scale_weight);

    double[<4>] below_rotation = { below.rotation.v.x, below.rotation.v.y,
      below.rotation.v.z, below.rotation.v.w };
    double[<4>] raw = rates.rotation_value + below_rotation * (double)residual(sums.rotation_weight);
    double[<4>] raw_rate = rates.rotation
      + rotation_derivative(below.rotation, velocity.angular) * (double)residual(sums.rotation_weight);
    double[<4>] unit = analytic_unit_rotation(raw);
    velocity.angular = spatial_rotation_rate(unit, normalized_rotation_derivative(raw, raw_rate));
}

fn void fold_additive_pose_derivative(
    PoseDerivativeScratch* derivative,
    Action* action,
    Track* track,
    uint node,
    uint mesh,
    uint[] mesh_widths,
    float[] sample,
    float[] reference,
    Transform below,
    float weight,
) @private {
    double[] rate = derivative.sample_rate[:sample.len];
    PoseVelocity* velocity = &derivative.velocity[node];
    switch (track.path) {
        case TRANSLATION:
            velocity.translation += (double[<3>]){ rate[0], rate[1], rate[2] } * (double)weight;
        case SCALE:
            if (action.additive_scale == AdditiveScaleMode.MULTIPLICATIVE) {
                for (uint axis = 0; axis < 3; axis++) {
                    double factor = 1 + (double)weight * ((double)sample[axis] / reference[axis] - 1);
                    velocity.scale[axis] = velocity.scale[axis] * factor
                      + (double)below.scale[axis] * (double)weight * rate[axis] / reference[axis];
                }
            } else {
                velocity.scale += (double[<3>]){ rate[0], rate[1], rate[2] } * (double)weight;
            }
        case ROTATION:
            Quaternion origin = { .v = { reference[0], reference[1], reference[2], reference[3] } };
            Quaternion current = { .v = { sample[0], sample[1], sample[2], sample[3] } };
            Quaternion sampled_rate = { .v = { rate[0], rate[1], rate[2], rate[3] } };
            Quaternion delta = origin.conjugate().mul(current);
            Quaternion delta_rate = origin.conjugate().mul(sampled_rate);
            if (delta.v.w < 0) {
                delta = -delta;
                delta_rate = -delta_rate;
            }

            double[<4>] mixed = delta.v * (double)weight;
            mixed.w += 1 - (double)weight;
            double[<4>] mixed_rate = delta_rate.v * (double)weight;
            double[<4>] unit = analytic_unit_rotation(mixed);
            double[<3>] added = spatial_rotation_rate(unit, normalized_rotation_derivative(mixed, mixed_rate));
            Quaternion orientation = { .v = { below.rotation.v.x, below.rotation.v.y,
              below.rotation.v.z, below.rotation.v.w } };
            velocity.angular += orientation.rotate_vec3(added);
        case MORPH_WEIGHTS:
            usz offset = derivative_morph_offset(mesh_widths, mesh);
            foreach (usz index, value : rate) derivative.morph_rates[offset + index] += value * weight;
    }
}

fn usz pose_derivative_storage_bytes(PoseDerivativeScratch* scratch) @private {
    return PoseDerivativeScratch::size + (usz)scratch.channels.len * ChannelDerivativeSums::size
      + (usz)scratch.velocity.len * PoseVelocity::size
      + (usz)scratch.morph_values.len * float::size
      + (usz)scratch.consumed_scale.len * bool::size
      + (usz)(scratch.morph_sums.len + scratch.morph_rates.len
          + scratch.sample.len + scratch.sample_rate.len) * double::size;
}

fn void pin_analytic_rotation_derivative(Action* action, PoseDerivativeScratch* derivative) @local {
    double[] sample = derivative.sample[:4];
    double[] rate = derivative.sample_rate[:4];
    Quaternion rotation = { .v = { sample[0], sample[1], sample[2], sample[3] } };
    Quaternion rotation_rate = { .v = { rate[0], rate[1], rate[2], rate[3] } };
    double[<4>] projected = { 0, sample[1], 0, sample[3] };
    double[<4>] projected_rate = { 0, rate[1], 0, rate[3] };
    if (projected.length() < (double)maths::TWIST_EPSILON) return;

    Quaternion twist = { .v = analytic_unit_rotation(projected) };
    Quaternion twist_rate = { .v = normalized_rotation_derivative(projected, projected_rate) };
    Quat reference_twist = maths::twist_about(action.root_rotation, (Vec3){ 0, 1, 0 });
    Quaternion reference = inertial_pose_rotation(reference_twist);
    Quaternion pinned = reference.mul(twist.conjugate()).mul(rotation);
    Quaternion first_rate = reference.mul(twist_rate.conjugate()).mul(rotation);
    Quaternion second_rate = reference.mul(twist.conjugate()).mul(rotation_rate);
    Quaternion pinned_rate = { .v = first_rate.v + second_rate.v };

    for (uint component = 0; component < 4; component++) {
        sample[component] = pinned.v[component];
        rate[component] = pinned_rate.v[component];
    }
}

fn bool captured_motion_track(CapturedMotionChain* chain, uint track) @local {
    foreach (node : chain.nodes) {
        if (node.translation_track == track || node.rotation_track == track || node.scale_track == track) return true;
    }

    return false;
}
