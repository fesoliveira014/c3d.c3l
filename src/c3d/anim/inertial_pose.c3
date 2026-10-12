module c3d::anim;

import c3d;
import c3d::maths;
import std::math;

const double INERTIAL_MIN_SCALE @local = 0x1p-126; // Smallest normal float; keeps corrected consumed scale invertible.

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

        Quaternion source_rotation = inertial_pose_rotation(source.rotation);
        Quaternion target_rotation = inertial_pose_rotation(target.rotation);
        row.offset[index].angular = {};
        row.offset_velocity[index].angular = {};
        if (inertial_rotation_valid(source_rotation) && inertial_rotation_valid(target_rotation)) {
            Quaternion difference = inertial_normalize_rotation(source_rotation)
              .mul(inertial_normalize_rotation(target_rotation).conjugate());
            double[<3>] angular_offset = inertial_rotation_log(difference);
            row.offset[index].angular = angular_offset;
            row.offset_velocity[index].angular = inertial_onset_rotation_rate(
                residual: angular_offset,
                source_rate: source_rate.angular,
                target_rate: target_rate.angular,
            );
        }

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

<* Correct the moving target without advancing control state.
   @param [&in] row : "Captured residual rows."
   @require target_pose.len == row.previous_pose.len && consumed_scale.len == target_pose.len
   @require target_morph.len == row.previous_morph.len
   @require math::is_finite(duration) && duration >= 0
   @require math::is_finite(elapsed) && elapsed >= 0 *>
fn void apply_inertial_pose(
    InertialRow* row,
    Transform[] target_pose,
    float[] target_morph,
    bool[] consumed_scale,
    double duration,
    double elapsed,
) @private {
    if (duration == 0 || elapsed >= duration) return;

    foreach (index, &target : target_pose) {
        double[<3>] translation = inertial_vector_residual(
            offset: row.offset[index].translation,
            velocity: row.offset_velocity[index].translation,
            duration: duration,
            elapsed: elapsed,
        );
        target.position = inertial_publish_vector(inertial_pose_vector(target.position) + translation);

        Quaternion target_rotation = inertial_pose_rotation(target.rotation);
        if (inertial_rotation_valid(target_rotation)) {
            Quaternion rotation = inertial_correct_rotation(
                initial: row.offset[index].angular,
                initial_rate: row.offset_velocity[index].angular,
                duration: duration,
                elapsed: elapsed,
                target: inertial_normalize_rotation(target_rotation),
            );
            target.rotation = inertial_publish_rotation(rotation);
        }

        if (!consumed_scale[index]) {
            double[<3>] scale = inertial_vector_residual(
                offset: row.offset[index].scale,
                velocity: row.offset_velocity[index].scale,
                duration: duration,
                elapsed: elapsed,
            );
            target.scale = inertial_publish_vector(inertial_pose_vector(target.scale) + scale);
            continue;
        }

        double target_scale = inertial_uniform_scale_mean(inertial_pose_vector(target.scale));
        if (!(target_scale > 0)) continue;

        double residual = inertial_scalar_residual(
            offset: row.offset[index].scale.x,
            velocity: row.offset_velocity[index].scale.x,
            duration: duration,
            elapsed: elapsed,
        );
        float value = (float)math::clamp(target_scale * math::exp(residual), INERTIAL_MIN_SCALE, (double)float::max);
        target.scale = { value, value, value };
    }

    foreach (index, &target : target_morph) {
        double residual = inertial_scalar_residual(
            offset: row.morph_offset[index],
            velocity: row.morph_offset_velocity[index],
            duration: duration,
            elapsed: elapsed,
        );
        *target = (float)((double)*target + residual);
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
        row.velocity[index] = valid ? inertial_pose_rate(row.previous_pose[index], pose, dt) : (PoseVelocity){};
        row.previous_pose[index] = pose;
    }

    foreach (index, weight : published_morph) {
        row.morph_velocity[index] = valid ? ((double)weight - (double)row.previous_morph[index]) / dt : 0;
        row.previous_morph[index] = weight;
    }

    row.control.previous_dt = dt;
    row.control.history_valid = true;
}

<* @require dt > 0 *>
fn PoseVelocity inertial_pose_rate(Transform previous, Transform current, double dt) @private {
    PoseVelocity rate = {
        .translation = (inertial_pose_vector(current.position) - inertial_pose_vector(previous.position)) / dt,
        .scale = (inertial_pose_vector(current.scale) - inertial_pose_vector(previous.scale)) / dt,
    };

    // A rotation that cannot be normalized contributes no angular rate.
    Quaternion current_rotation = inertial_pose_rotation(current.rotation);
    Quaternion previous_rotation = inertial_pose_rotation(previous.rotation);
    if (inertial_rotation_valid(current_rotation) && inertial_rotation_valid(previous_rotation)) {
        Quaternion change = inertial_normalize_rotation(current_rotation)
          .mul(inertial_normalize_rotation(previous_rotation).conjugate());
        rate.angular = inertial_rotation_log(change) / dt;
    }

    return rate;
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
