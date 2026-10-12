module c3d::anim;

import std::math;

const double INERTIAL_JACOBIAN_SERIES_LIMIT @private = 1e-4; // Avoids coefficient cancellation below this angle.

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
