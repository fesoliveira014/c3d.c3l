module c3d::anim;

import c3d;
import c3d::maths;
import std::math;

const double INERTIAL_JACOBIAN_SERIES_LIMIT @private = 1e-4; // Avoids coefficient cancellation below this angle.

const double INERTIAL_MIN_SCALE @local = 0x1p-126; // Smallest normal float; keeps corrected consumed scale invertible.

struct InertialQuinticBasis @private {
    double value;
    double velocity;
}

struct InertialScalarState @private {
    double value;
    double rate;
}

<* Evaluate the residual basis in normalized time.
   @require time >= 0 && time <= 1 *>
fn InertialQuinticBasis inertial_quintic_basis(double time) @private {
    double square = time * time;
    double cube = square * time;
    double fourth = cube * time;
    double fifth = fourth * time;

    return {
        .value = 1 - 10 * cube + 15 * fourth - 6 * fifth,
        .velocity = time - 6 * cube + 8 * fourth - 3 * fifth,
    };
}

<* Decay one admitted linear residual in update seconds.
   @require math::is_finite(duration) && duration >= 0
   @require math::is_finite(elapsed) && elapsed >= 0 *>
fn double inertial_scalar_residual(
    double offset,
    double velocity,
    double duration,
    double elapsed,
) @private {
    if (duration == 0 || elapsed >= duration) return 0;

    InertialQuinticBasis basis = inertial_quintic_basis(elapsed / duration);
    return offset * basis.value + duration * velocity * basis.velocity;
}

<* Decay one admitted vector residual in update seconds.
   @require math::is_finite(duration) && duration >= 0
   @require math::is_finite(elapsed) && elapsed >= 0 *>
fn double[<3>] inertial_vector_residual(
    double[<3>] offset,
    double[<3>] velocity,
    double duration,
    double elapsed,
) @private {
    if (duration == 0 || elapsed >= duration) return {};

    InertialQuinticBasis basis = inertial_quintic_basis(elapsed / duration);
    return offset * basis.value + velocity * (duration * basis.velocity);
}

<* Capture an admitted scale residual in log coordinates.
   @require source.value > 0 && target.value > 0 *>
fn InertialScalarState inertial_onset_scale_residual(
    InertialScalarState source,
    InertialScalarState target,
) @private {
    return {
        .value = math::ln(source.value / target.value),
        .rate = source.rate / source.value - target.rate / target.value,
    };
}

fn Quaternion inertial_rotation_exp(double[<3>] rotation) @private {
    double angle = rotation.length();
    double square = angle * angle;
    double scale = angle < INERTIAL_JACOBIAN_SERIES_LIMIT
      ? 0.5 - square / 48 + square * square / 3840
      : math::sin(angle * 0.5) / angle;

    double[<3>] axis = rotation * scale;
    return { .v = { axis.x, axis.y, axis.z, math::cos(angle * 0.5) } };
}

<* Resolve the shortest orientation with lexicographic half-turn ties.
   @require inertial_rotation_valid(value) *>
fn double[<3>] inertial_rotation_log(Quaternion value) @private {
    value = inertial_normalize_rotation(value);
    bool negative_axis = value.v.x < 0 || (value.v.x == 0 && value.v.y < 0)
      || (value.v.x == 0 && value.v.y == 0 && value.v.z < 0);
    if (value.v.w < 0 || (value.v.w == 0 && negative_axis)) value = -value;

    double[<3>] axis = { value.v.x, value.v.y, value.v.z };
    double length = axis.length();
    if (length == 0) return {};

    return axis * (2 * math::atan2(length, value.v.w) / length);
}

<* Transport through a nonsingular shortest rotation chart.
   @require rotation.length() < 2 * math::PI *>
fn double[<3>] inertial_left_jacobian_inverse(double[<3>] rotation, double[<3>] velocity) @private {
    double angle = rotation.length();
    double square = angle * angle;
    double coefficient = angle < INERTIAL_JACOBIAN_SERIES_LIMIT
      ? 1.0 / 12 + square / 720 + square * square / 30240
      : (1 - angle * 0.5 * math::cos(angle * 0.5) / math::sin(angle * 0.5)) / square;

    double[<3>] cross = rotation.cross(velocity);
    return velocity - cross * 0.5 + rotation.cross(cross) * coefficient;
}

fn double[<3>] inertial_onset_rotation_rate(
    double[<3>] residual,
    double[<3>] source_rate,
    double[<3>] target_rate,
) @private {
    Quaternion correction = inertial_rotation_exp(residual);
    return inertial_left_jacobian_inverse(residual, source_rate - correction.rotate_vec3(target_rate));
}

<* Apply the residual orientation to the target.
   @require math::is_finite(duration) && duration >= 0
   @require math::is_finite(elapsed) && elapsed >= 0 *>
fn Quaternion inertial_correct_rotation(
    double[<3>] initial,
    double[<3>] initial_rate,
    double duration,
    double elapsed,
    Quaternion target,
) @private {
    double[<3>] residual = inertial_vector_residual(
        offset: initial,
        velocity: initial_rate,
        duration: duration,
        elapsed: elapsed,
    );

    return inertial_rotation_exp(residual).mul(target);
}

fn bool inertial_rotation_valid(Quaternion value) @private {
    return math::is_finite(value.v.x) && math::is_finite(value.v.y)
      && math::is_finite(value.v.z) && math::is_finite(value.v.w)
      && (value.v.x != 0 || value.v.y != 0 || value.v.z != 0 || value.v.w != 0);
}

<* Normalize admitted finite nonzero quaternion components without magnitude limits.
   @require inertial_rotation_valid(value) *>
fn Quaternion inertial_normalize_rotation(Quaternion value) @private {
    double first = math::max(math::abs(value.v.x), math::abs(value.v.y));
    double second = math::max(math::abs(value.v.z), math::abs(value.v.w));
    double maximum = math::max(first, second);
    double[<4>] scaled = value.v / maximum;

    return { .v = scaled / scaled.length() };
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
