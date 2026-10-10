module c3d::anim;

import c3d;
import c3d::maths;
import std::math;

<* Reject nonfinite source channels and finite zero rotations before capture.
   @return? c3d::INVALID_ARGUMENT *>
fn void? validate_inertial_pose_source(Transform[] pose, float[] morph) @private {
    foreach (node : pose) {
        for (uint axis = 0; axis < 3; axis++) {
            if (!math::is_finite(node.position[axis]) || !math::is_finite(node.scale[axis])) {
                return c3d::INVALID_ARGUMENT~;
            }
        }

        if (!inertial_rotation_valid(inertial_pose_rotation(node.rotation))) return c3d::INVALID_ARGUMENT~;
    }

    foreach (weight : morph) {
        if (!math::is_finite(weight)) return c3d::INVALID_ARGUMENT~;
    }
}

<* Capture residuals from the displayed source and admitted target onset.
   @param [&inout] row : "Reserved residual rows; history remains unchanged."
   @require source_pose.len == row.previous_pose.len && target_pose.len == source_pose.len
   @require target_velocity.len == source_pose.len && consumed_scale.len == source_pose.len
   @require source_morph.len == row.previous_morph.len && target_morph.len == source_morph.len
   @require target_morph_rate.len == source_morph.len *>
fn void capture_inertial_pose_residuals(
    InertialRow* row,
    Transform[] source_pose,
    float[] source_morph,
    Transform[] target_pose,
    PoseVelocity[] target_velocity,
    float[] target_morph,
    double[] target_morph_rate,
    bool[] consumed_scale,
) @private {
    foreach (index, source : source_pose) {
        Transform target = target_pose[index];
        PoseVelocity source_rate = row.control.history_valid ? row.velocity[index] : (PoseVelocity){};
        PoseVelocity target_rate = target_velocity[index];
        row.offset[index].translation = inertial_pose_vector(source.position) - inertial_pose_vector(target.position);
        row.offset_velocity[index].translation = source_rate.translation - target_rate.translation;

        Quaternion source_rotation = inertial_normalize_rotation(inertial_pose_rotation(source.rotation));
        Quaternion target_rotation = inertial_normalize_rotation(inertial_pose_rotation(target.rotation));
        double[<3>] angular_offset = inertial_rotation_log(source_rotation.mul(target_rotation.conjugate()));
        row.offset[index].angular = angular_offset;
        row.offset_velocity[index].angular = inertial_onset_rotation_rate(
            angular_offset, source_rate.angular, target_rate.angular);

        if (consumed_scale[index]) {
            InertialScalarState residual = inertial_onset_scale_residual(
                source: {
                    .value = inertial_uniform_scale_mean(inertial_pose_vector(source.scale)),
                    .rate = inertial_uniform_scale_mean(source_rate.scale),
                },
                target: {
                    .value = inertial_uniform_scale_mean(inertial_pose_vector(target.scale)),
                    .rate = inertial_uniform_scale_mean(target_rate.scale),
                },
            );
            row.offset[index].scale = { residual.value, residual.value, residual.value };
            row.offset_velocity[index].scale = { residual.rate, residual.rate, residual.rate };
        } else {
            row.offset[index].scale = inertial_pose_vector(source.scale) - inertial_pose_vector(target.scale);
            row.offset_velocity[index].scale = source_rate.scale - target_rate.scale;
        }
    }

    foreach (index, source : source_morph) {
        double source_rate = row.control.history_valid ? row.morph_velocity[index] : 0;
        row.morph_offset[index] = (double)source - (double)target_morph[index];
        row.morph_offset_velocity[index] = source_rate - target_morph_rate[index];
    }
}

<* Correct the moving target and analytic rates without advancing control state.
   @param [&in] row : "Captured residual rows."
   @require target_pose.len == row.previous_pose.len && target_velocity.len == target_pose.len
   @require consumed_scale.len == target_pose.len
   @require target_morph.len == row.previous_morph.len && target_morph_rate.len == target_morph.len
   @require math::is_finite(duration) && duration >= 0
   @require math::is_finite(elapsed) && elapsed >= 0 *>
fn void apply_inertial_pose(
    InertialRow* row,
    Transform[] target_pose,
    PoseVelocity[] target_velocity,
    float[] target_morph,
    double[] target_morph_rate,
    bool[] consumed_scale,
    double duration,
    double elapsed,
) @private {
    bool active = duration > 0 && elapsed < duration;
    foreach (index, &target : target_pose) {
        PoseVelocity* velocity = &target_velocity[index];
        if (active) {
            InertialVectorState translation = inertial_vector_residual(
                offset: row.offset[index].translation,
                velocity: row.offset_velocity[index].translation,
                duration: duration,
                elapsed: elapsed,
            );
            target.position = inertial_publish_vector(inertial_pose_vector(target.position) + translation.value);
            velocity.translation += translation.rate;

            InertialRotationState rotation = inertial_correct_rotation(
                initial: row.offset[index].angular,
                initial_rate: row.offset_velocity[index].angular,
                duration: duration,
                elapsed: elapsed,
                target: inertial_normalize_rotation(inertial_pose_rotation(target.rotation)),
                target_rate: velocity.angular,
            );
            target.rotation = inertial_publish_rotation(rotation.orientation);
            velocity.angular = rotation.angular_velocity;
        }

        if (consumed_scale[index]) {
            InertialScalarState target_scale = {
                .value = inertial_uniform_scale_mean(inertial_pose_vector(target.scale)),
                .rate = inertial_uniform_scale_mean(velocity.scale),
            };
            InertialScalarState result = target_scale;
            if (active) {
                InertialScalarState residual = inertial_scalar_residual(
                    offset: row.offset[index].scale.x,
                    velocity: row.offset_velocity[index].scale.x,
                    duration: duration,
                    elapsed: elapsed,
                );
                result = inertial_correct_log_scale(residual, target_scale);
            }

            float value = (float)result.value;
            target.scale = { value, value, value };
            velocity.scale = { result.rate, result.rate, result.rate };
        } else if (active) {
            InertialVectorState scale = inertial_vector_residual(
                offset: row.offset[index].scale,
                velocity: row.offset_velocity[index].scale,
                duration: duration,
                elapsed: elapsed,
            );
            target.scale = inertial_publish_vector(inertial_pose_vector(target.scale) + scale.value);
            velocity.scale += scale.rate;
        }
    }

    if (!active) return;

    foreach (index, &target : target_morph) {
        InertialScalarState residual = inertial_scalar_residual(
            offset: row.morph_offset[index],
            velocity: row.morph_offset_velocity[index],
            duration: duration,
            elapsed: elapsed,
        );
        *target = (float)((double)*target + residual.value);
        target_morph_rate[index] += residual.rate;
    }
}

<* Record corrected float output and double positive-step secant rates.
   @param [&inout] row : "Updates history only; transition control remains unchanged."
   @param dt : "Binary32 update seconds, promoted without rounding."
   @require published_pose.len == row.previous_pose.len && published_morph.len == row.previous_morph.len
   @require math::is_finite(dt) && dt >= 0 *>
fn void record_inertial_pose_history(
    InertialRow* row,
    Transform[] published_pose,
    float[] published_morph,
    double dt,
) @private {
    if (dt == 0) return;

    bool valid = row.control.history_valid;
    foreach (index, pose : published_pose) {
        if (valid) {
            Transform previous = row.previous_pose[index];
            row.velocity[index].translation =
              (inertial_pose_vector(pose.position) - inertial_pose_vector(previous.position)) / dt;
            row.velocity[index].scale =
              (inertial_pose_vector(pose.scale) - inertial_pose_vector(previous.scale)) / dt;
            Quaternion current_rotation = inertial_normalize_rotation(inertial_pose_rotation(pose.rotation));
            Quaternion previous_rotation = inertial_normalize_rotation(inertial_pose_rotation(previous.rotation));
            row.velocity[index].angular =
              inertial_rotation_log(current_rotation.mul(previous_rotation.conjugate())) / dt;
        } else {
            row.velocity[index] = {};
        }

        row.previous_pose[index] = pose;
    }

    foreach (index, weight : published_morph) {
        row.morph_velocity[index] = valid ? ((double)weight - (double)row.previous_morph[index]) / dt : 0;
        row.previous_morph[index] = weight;
    }

    row.control.previous_dt = dt;
    row.control.history_valid = true;
}

fn double inertial_uniform_scale_mean(double[<3>] value) @private {
    return (value.x + value.y + value.z) / 3;
}

fn double[<3>] inertial_pose_vector(Vec3 value) @private => { value.x, value.y, value.z };

fn Quaternion inertial_pose_rotation(Quat value) @private {
    return { .v = { value.v.x, value.v.y, value.v.z, value.v.w } };
}

fn Vec3 inertial_publish_vector(double[<3>] value) @private {
    return { (float)value.x, (float)value.y, (float)value.z };
}

fn Quat inertial_publish_rotation(Quaternion value) @private {
    return { .v = { (float)value.v.x, (float)value.v.y, (float)value.v.z, (float)value.v.w } };
}
