module c3d::test::inertial_math;

import c3d::anim @public;
import std::math;
import std::io;

const double INERTIAL_TEST_MATRIX_EPSILON @local = 1e-4;
const double INERTIAL_TEST_RATE_EPSILON @local = 1e-4;
const double INERTIAL_TEST_SCALAR_EPSILON @local = 1e-6;
const double INERTIAL_TEST_ORACLE_SERIES_LIMIT @local = 0.01;
const uint INERTIAL_TEST_SEED @local = 3532026;
const uint INERTIAL_TEST_CORPUS_COUNT @local = 2000;

fn Matrix3 inertial_oracle_identity() @local {
    return { .m = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } };
}

fn Matrix3 inertial_oracle_skew(double[<3>] value) @local {
    return { .m = { 0, value.z, -value.y, -value.z, 0, value.x, value.y, -value.x, 0 } };
}

fn Matrix3 inertial_oracle_add(Matrix3 left, Matrix3 right) @local => { .m = left.m + right.m };

fn Matrix3 inertial_oracle_scale(Matrix3 value, double amount) @local => { .m = value.m * amount };

fn Matrix3 inertial_oracle_product(Matrix3 left, Matrix3 right) @local {
    Matrix3 result;
    for (uint row = 0; row < 3; row++) for (uint column = 0; column < 3; column++) {
        for (uint inner = 0; inner < 3; inner++) {
            result.m[column * 3 + row] += left.m[inner * 3 + row] * right.m[column * 3 + inner];
        }
    }
    return result;
}

fn Matrix3 inertial_oracle_transpose(Matrix3 value) @local {
    Matrix3 result;
    for (uint row = 0; row < 3; row++) for (uint column = 0; column < 3; column++) {
        result.m[column * 3 + row] = value.m[row * 3 + column];
    }
    return result;
}

fn Matrix3 inertial_oracle_quaternion_matrix(Quaternion value) @local {
    double[<4>] unit = value.v / value.v.length();
    return {
        .m = {
            1 - 2 * (unit.y * unit.y + unit.z * unit.z),
            2 * (unit.x * unit.y + unit.z * unit.w),
            2 * (unit.x * unit.z - unit.y * unit.w),
            2 * (unit.x * unit.y - unit.z * unit.w),
            1 - 2 * (unit.x * unit.x + unit.z * unit.z),
            2 * (unit.y * unit.z + unit.x * unit.w),
            2 * (unit.x * unit.z + unit.y * unit.w),
            2 * (unit.y * unit.z - unit.x * unit.w),
            1 - 2 * (unit.x * unit.x + unit.y * unit.y),
        },
    };
}

fn Matrix3 inertial_oracle_rodrigues(double[<3>] rotation) @local {
    double angle = rotation.length();
    double square = angle * angle;
    double first;
    double second;
    if (angle < INERTIAL_TEST_ORACLE_SERIES_LIMIT) {
        first = 1 - square / 6 + square * square / 120 - square * square * square / 5040;
        second = 0.5 - square / 24 + square * square / 720 - square * square * square / 40320;
    } else {
        first = math::sin(angle) / angle;
        double half_sine = math::sin(angle * 0.5);
        second = 2 * half_sine * half_sine / square;
    }
    Matrix3 skew = inertial_oracle_skew(rotation);
    return inertial_oracle_add(inertial_oracle_identity(), inertial_oracle_add(
        inertial_oracle_scale(skew, first),
        inertial_oracle_scale(inertial_oracle_product(skew, skew), second)));
}

fn Matrix3 inertial_oracle_rodrigues_derivative(double[<3>] rotation, double[<3>] velocity) @local {
    double angle = rotation.length();
    double square = angle * angle;
    double angle_rate = angle == 0 ? 0 : rotation.dot(velocity) / angle;
    double first;
    double second;
    double first_derivative;
    double second_derivative;
    if (angle < INERTIAL_TEST_ORACLE_SERIES_LIMIT) {
        first = 1 - square / 6 + square * square / 120 - square * square * square / 5040;
        second = 0.5 - square / 24 + square * square / 720 - square * square * square / 40320;
        first_derivative = angle * (-1.0 / 3 + square / 30 - square * square / 840);
        second_derivative = angle * (-1.0 / 12 + square / 180 - square * square / 6720);
    } else {
        first = math::sin(angle) / angle;
        double half_sine = math::sin(angle * 0.5);
        second = 2 * half_sine * half_sine / square;
        first_derivative = (angle * math::cos(angle) - math::sin(angle)) / square;
        second_derivative = (angle * math::sin(angle) - 4 * half_sine * half_sine) / (square * angle);
    }
    Matrix3 skew = inertial_oracle_skew(rotation);
    Matrix3 skew_rate = inertial_oracle_skew(velocity);
    Matrix3 product_rate = inertial_oracle_add(inertial_oracle_product(skew_rate, skew),
        inertial_oracle_product(skew, skew_rate));
    return inertial_oracle_add(
        inertial_oracle_add(inertial_oracle_scale(skew, first_derivative * angle_rate),
            inertial_oracle_scale(skew_rate, first)),
        inertial_oracle_add(inertial_oracle_scale(inertial_oracle_product(skew, skew),
            second_derivative * angle_rate), inertial_oracle_scale(product_rate, second)));
}

fn double[<3>] inertial_oracle_spatial_rate(
    double[<3>] rotation,
    double[<3>] residual_rate,
    Quaternion target,
    double[<3>] target_rate,
) @local {
    Matrix3 residual_matrix = inertial_oracle_rodrigues(rotation);
    Matrix3 target_matrix = inertial_oracle_quaternion_matrix(target);
    Matrix3 combined = inertial_oracle_product(residual_matrix, target_matrix);
    Matrix3 derivative = inertial_oracle_add(
        inertial_oracle_product(inertial_oracle_rodrigues_derivative(rotation, residual_rate), target_matrix),
        inertial_oracle_product(residual_matrix,
            inertial_oracle_product(inertial_oracle_skew(target_rate), target_matrix)));
    Matrix3 spatial = inertial_oracle_product(derivative, inertial_oracle_transpose(combined));
    return { (spatial.m21 - spatial.m12) * 0.5, (spatial.m02 - spatial.m20) * 0.5,
        (spatial.m10 - spatial.m01) * 0.5 };
}

fn InertialScalarState inertial_oracle_horner(
    double offset,
    double velocity,
    double duration,
    double elapsed,
) @local {
    if (duration == 0 || elapsed >= duration) return {};
    double time = elapsed / duration;
    double[6] coefficients = {
        offset, duration * velocity, 0,
        -10 * offset - 6 * duration * velocity,
        15 * offset + 8 * duration * velocity,
        -6 * offset - 3 * duration * velocity,
    };
    InertialScalarState result;
    for (int degree = 5; degree >= 0; degree--) {
        result.rate = result.rate * time + result.value;
        result.value = result.value * time + coefficients[degree];
    }
    result.rate /= duration;
    return result;
}

fn void inertial_assert_matrix(Quaternion actual, Matrix3 expected) @local {
    Matrix3 observed = inertial_oracle_quaternion_matrix(actual);
    for (uint index = 0; index < 9; index++) {
        assert(math::abs(observed.m[index] - expected.m[index]) <= INERTIAL_TEST_MATRIX_EPSILON);
    }
}

fn void inertial_assert_rate(double[<3>] actual, double[<3>] expected) @local {
    assert((actual - expected).length() <= INERTIAL_TEST_RATE_EPSILON * (1 + expected.length()));
}

fn void inertial_assert_scalar(InertialScalarState actual, InertialScalarState expected) @local {
    assert(math::abs(actual.value - expected.value) <= INERTIAL_TEST_SCALAR_EPSILON);
    assert(math::abs(actual.rate - expected.rate) <= INERTIAL_TEST_RATE_EPSILON * (1 + math::abs(expected.rate)));
}

fn Quaternion inertial_input_rotation(double[<3>] rotation) @local {
    double angle = rotation.length();
    if (angle == 0) return { .v = { 0, 0, 0, 1 } };
    return quaternion::from_axis_angle{double}(rotation / angle, angle);
}

fn double inertial_random_unit(uint* state) @local {
    *state ^= *state << 13;
    *state ^= *state >> 17;
    *state ^= *state << 5;
    return (double)*state / 4294967296.0;
}

fn double[<3>] inertial_random_vector(uint* state) @local {
    return { 2 * inertial_random_unit(state) - 1, 2 * inertial_random_unit(state) - 1,
        2 * inertial_random_unit(state) - 1 };
}

fn void test_animation_inertial_math_quintic_matches_independent_horner_and_endpoints() @test {
    InertialQuinticBasis middle = anim::inertial_quintic_basis(0.5);
    assert(middle.value == 0.5 && middle.velocity == 0.15625);
    assert(middle.value_rate == -1.875 && middle.velocity_rate == -0.4375);
    foreach (double elapsed : { 0.0, 0.5, 1.0, 1.5, 2.0, 3.0 }) {
        InertialScalarState actual = anim::inertial_scalar_residual(
            offset: 3,
            velocity: -2,
            duration: 2,
            elapsed: elapsed,
        );
        InertialScalarState expected = inertial_oracle_horner(
            offset: 3,
            velocity: -2,
            duration: 2,
            elapsed: elapsed,
        );
        inertial_assert_scalar(actual, expected);
        InertialVectorState vector = anim::inertial_vector_residual(
            offset: { 3, -4, 0.5 },
            velocity: { -2, 1.5, 5 },
            duration: 2,
            elapsed: elapsed,
        );
        double[<3>] offsets = { 3, -4, 0.5 };
        double[<3>] velocities = { -2, 1.5, 5 };
        for (uint axis = 0; axis < 3; axis++) {
            expected = inertial_oracle_horner(
                offset: offsets[axis],
                velocity: velocities[axis],
                duration: 2,
                elapsed: elapsed,
            );
            inertial_assert_scalar({ .value = vector.value[axis], .rate = vector.rate[axis] }, expected);
        }
    }
    InertialScalarState onset = anim::inertial_scalar_residual(offset: 3, velocity: -2, duration: 2, elapsed: 0);
    assert(onset.value == 3 && onset.rate == -2);
    InertialScalarState zero = anim::inertial_scalar_residual(offset: 3, velocity: -2, duration: 0, elapsed: 0);
    assert(zero.value == 0 && zero.rate == 0);
}

fn void test_animation_inertial_math_log_scale_preserves_positive_physical_velocity() @test {
    InertialScalarState source = { .value = 1, .rate = -10 };
    InertialScalarState target = { .value = 1 };
    InertialScalarState onset = anim::inertial_log_scale(source: source, target: target, duration: 1, elapsed: 0);
    assert(onset.value == 1 && onset.rate == -10);
    InertialScalarState quarter = anim::inertial_log_scale(
        source: source,
        target: target,
        duration: 1,
        elapsed: 0.25,
    );
    double expected = math::exp(-1.845703125);
    assert(math::abs(quarter.value - expected) < 1e-12 && quarter.value > 0);
    assert(math::abs(quarter.rate - expected * -3.1640625) < 1e-12);
    InertialScalarState finished = anim::inertial_log_scale(source: source, target: target, duration: 1, elapsed: 1);
    assert(finished.value == target.value && finished.rate == target.rate);
    InertialScalarState tiny = anim::inertial_log_scale(
        source: { .value = 1e-30, .rate = -1e-29 },
        target: { .value = 2e-30, .rate = 1e-30 },
        duration: 0.1,
        elapsed: 0,
    );
    assert(tiny.value > 0 && math::abs(tiny.value / 1e-30 - 1) < 1e-12);
    assert(math::abs(tiny.rate / 1e-30 + 10) < 1e-12);
    InertialScalarState moving_source = { .value = 1.5, .rate = -0.2 };
    InertialScalarState target_start = { .value = 0.8, .rate = 0.1 };
    InertialScalarState captured = anim::inertial_onset_scale_residual(moving_source, target_start);
    foreach (double elapsed : { 0.0, 0.25, 0.5, 0.75, 1.0 }) {
        InertialScalarState current_target = { .value = 0.8 + elapsed * 0.1, .rate = 0.1 };
        InertialScalarState residual = anim::inertial_scalar_residual(
            offset: captured.value,
            velocity: captured.rate,
            duration: 1,
            elapsed: elapsed,
        );
        InertialScalarState actual = anim::inertial_correct_log_scale(residual, current_target);
        InertialScalarState oracle = inertial_oracle_horner(
            offset: math::ln(1.5 / 0.8),
            velocity: -0.2 / 1.5 - 0.1 / 0.8,
            duration: 1,
            elapsed: elapsed,
        );
        double value = current_target.value * math::exp(oracle.value);
        inertial_assert_scalar(actual, {
            .value = value,
            .rate = value * (0.1 / current_target.value + oracle.rate),
        });
    }
    InertialScalarState unrelated = anim::inertial_scalar_residual(
        offset: -2,
        velocity: -10,
        duration: 1,
        elapsed: 0.25,
    );
    assert(-1 + unrelated.value < 0);
}

fn void test_animation_inertial_math_half_turn_ties_and_transported_onset_rate() @test {
    Quaternion[3] half_turns = {
        { .v = { -1, 0, 0, 0 } }, { .v = { 0, -1, 0, 0 } }, { .v = { 0, 0, -1, 0 } },
    };
    foreach (half_turn : half_turns) {
        double[<3>] actual = anim::inertial_rotation_log(half_turn);
        double[<3>] opposite = anim::inertial_rotation_log(-half_turn);
        assert(actual == opposite && actual.x >= 0 && actual.y >= 0 && actual.z >= 0);
        assert(math::abs(actual.length() - math::PI) < 1e-14);
        inertial_assert_matrix(anim::inertial_rotation_exp(actual), inertial_oracle_quaternion_matrix(half_turn));
    }
    Quaternion mixed = { .v = { 2.0 / 3, -1.0 / 3, 2.0 / 3, 0 } };
    double[<3>] mixed_log = anim::inertial_rotation_log(mixed);
    assert(mixed_log.x > 0 && mixed_log.y < 0 && mixed_log.z > 0);
    assert(mixed_log == anim::inertial_rotation_log(-mixed));
    foreach (double scale : { 1e-200, 1e-40, 1e30, 1e200 }) {
        Quaternion scaled_identity = { .v = { 0, 0, 0, scale } };
        assert(anim::inertial_rotation_log(scaled_identity) == (double[<3>]){});
    }
    double[<3>] residual = { 0, 0, math::PI * 0.5 };
    double[<3>] source_rate = { 1, 2, 3 };
    double[<3>] target_rate = { 3, -1, 2 };
    Quaternion identity = { .v = { 0, 0, 0, 1 } };
    double[<3>] transported = anim::inertial_onset_rotation_rate(residual, source_rate, target_rate);
    inertial_assert_rate(inertial_oracle_spatial_rate(
        rotation: residual,
        residual_rate: transported,
        target: identity,
        target_rate: target_rate,
    ), source_rate);
    double[<3>] naive = inertial_oracle_spatial_rate(
        rotation: residual,
        residual_rate: source_rate - target_rate,
        target: identity,
        target_rate: target_rate,
    );
    assert((naive - source_rate).length() > 0.1);
}

fn void test_animation_inertial_math_fixed_angles_signs_and_series_boundary() @test {
    double[9] angles = {
        0, 1e-9, 1e-4 * 0.9999, 1e-4 * 1.0001,
        math::PI / 6, math::PI * 0.5, math::PI * 179 / 180, math::PI, 0.3,
    };
    double[<3>] axis = { 2.0 / 3, -1.0 / 3, 2.0 / 3 };
    Quaternion target = inertial_input_rotation({ -0.2, 0.7, 0.3 });
    double[<3>] source_rate = { 1.1, -0.4, 0.7 };
    double[<3>] target_rate = { -0.2, 0.9, 0.5 };
    foreach (angle : angles) {
        Quaternion source = inertial_input_rotation(axis * angle).mul(target);
        inertial_assert_matrix(anim::inertial_rotation_exp(axis * angle), inertial_oracle_rodrigues(axis * angle));
        for (uint signs = 0; signs < 4; signs++) {
            Quaternion signed_source = (signs & 1) != 0 ? -source : source;
            Quaternion signed_target = (signs & 2) != 0 ? -target : target;
            double[<3>] initial = anim::inertial_rotation_log(signed_source.mul(signed_target.conjugate()));
            double[<3>] initial_rate = anim::inertial_onset_rotation_rate(initial, source_rate, target_rate);
            InertialRotationState actual = anim::inertial_correct_rotation(
                initial: initial,
                initial_rate: initial_rate,
                duration: 0.7,
                elapsed: 0,
                target: signed_target,
                target_rate: target_rate,
            );
            inertial_assert_matrix(actual.orientation, inertial_oracle_quaternion_matrix(signed_source));
            inertial_assert_rate(actual.angular_velocity, source_rate);
            inertial_assert_rate(inertial_oracle_spatial_rate(
                rotation: initial,
                residual_rate: initial_rate,
                target: signed_target,
                target_rate: target_rate,
            ), source_rate);
        }
    }
}

fn void test_animation_inertial_math_seeded_rotations_and_interruptions_match_independent_oracles() @test {
    uint random = INERTIAL_TEST_SEED;
    uint discriminations;
    double maximum_rate_error;
    double maximum_scalar_error;
    double[8] angles = {
        1e-9, 1e-4 * 0.9999, 1e-4 * 1.0001,
        math::PI / 6, math::PI * 0.5, math::PI * 179 / 180, math::PI, 0,
    };
    for (uint sample = 0; sample < INERTIAL_TEST_CORPUS_COUNT; sample++) {
        double[<3>] axis = inertial_random_vector(&random);
        axis /= axis.length();
        Quaternion first_target = inertial_input_rotation(inertial_random_vector(&random) * 1.5);
        Quaternion source = inertial_input_rotation(axis * angles[sample % angles.len]).mul(first_target);
        if ((sample & 1) != 0) source = -source;
        if ((sample & 2) != 0) first_target = -first_target;
        double[<3>] source_rate = inertial_random_vector(&random) * 2;
        double[<3>] target_rate = inertial_random_vector(&random) * 3;
        double[<3>] initial = anim::inertial_rotation_log(source.mul(first_target.conjugate()));
        double[<3>] initial_rate = anim::inertial_onset_rotation_rate(initial, source_rate, target_rate);
        double duration = 0.01 + 3 * inertial_random_unit(&random);
        if (sample % 11 == 0) duration = 1e-4;
        if (sample % 13 == 0) duration = 100;
        double elapsed = duration * inertial_random_unit(&random);
        Quaternion target = inertial_input_rotation(target_rate * elapsed).mul(first_target);
        InertialRotationState actual = anim::inertial_correct_rotation(
            initial: initial,
            initial_rate: initial_rate,
            duration: duration,
            elapsed: elapsed,
            target: target,
            target_rate: target_rate,
        );
        double[<3>] residual;
        double[<3>] residual_rate;
        for (uint coordinate = 0; coordinate < 3; coordinate++) {
            InertialScalarState oracle = inertial_oracle_horner(
                offset: initial[coordinate],
                velocity: initial_rate[coordinate],
                duration: duration,
                elapsed: elapsed,
            );
            residual[coordinate] = oracle.value;
            residual_rate[coordinate] = oracle.rate;
        }
        Matrix3 expected_orientation = inertial_oracle_product(inertial_oracle_rodrigues(residual),
            inertial_oracle_quaternion_matrix(target));
        double[<3>] expected_rate = inertial_oracle_spatial_rate(
            rotation: residual,
            residual_rate: residual_rate,
            target: target,
            target_rate: target_rate,
        );
        inertial_assert_matrix(actual.orientation, expected_orientation);
        inertial_assert_rate(actual.angular_velocity, expected_rate);
        maximum_rate_error = math::max(maximum_rate_error, (actual.angular_velocity - expected_rate).length());
        inertial_assert_rate(inertial_oracle_spatial_rate(
            rotation: initial,
            residual_rate: initial_rate,
            target: first_target,
            target_rate: target_rate,
        ), source_rate);
        double[<3>] naive_rate = inertial_oracle_spatial_rate(
            rotation: initial,
            residual_rate: source_rate - target_rate,
            target: first_target,
            target_rate: target_rate,
        );
        if ((naive_rate - source_rate).length() > 0.001) discriminations++;
        Quaternion replacement = inertial_input_rotation(inertial_random_vector(&random) * 1.7);
        double[<3>] replacement_rate = inertial_random_vector(&random) * 2.5;
        double[<3>] replacement_initial = anim::inertial_rotation_log(actual.orientation.mul(replacement.conjugate()));
        double[<3>] replacement_initial_rate = anim::inertial_onset_rotation_rate(
            replacement_initial, actual.angular_velocity, replacement_rate);
        InertialRotationState restarted = anim::inertial_correct_rotation(
            initial: replacement_initial,
            initial_rate: replacement_initial_rate,
            duration: 0.37,
            elapsed: 0,
            target: replacement,
            target_rate: replacement_rate,
        );
        inertial_assert_matrix(restarted.orientation, inertial_oracle_quaternion_matrix(actual.orientation));
        inertial_assert_rate(restarted.angular_velocity, actual.angular_velocity);
        for (uint channel = 0; channel < 5; channel++) {
            double source_value = 10 * (2 * inertial_random_unit(&random) - 1);
            double source_velocity = 5 * (2 * inertial_random_unit(&random) - 1);
            double target_value = 10 * (2 * inertial_random_unit(&random) - 1);
            double target_velocity = 3 * (2 * inertial_random_unit(&random) - 1);
            InertialScalarState scalar = anim::inertial_scalar_residual(
                offset: source_value - target_value,
                velocity: source_velocity - target_velocity,
                duration: duration,
                elapsed: elapsed,
            );
            InertialScalarState oracle = inertial_oracle_horner(
                offset: source_value - target_value,
                velocity: source_velocity - target_velocity,
                duration: duration,
                elapsed: elapsed,
            );
            inertial_assert_scalar(scalar, oracle);
            maximum_scalar_error = math::max(maximum_scalar_error, math::abs(scalar.value - oracle.value));
            double corrected_value = target_value + elapsed * target_velocity + scalar.value;
            double corrected_rate = target_velocity + scalar.rate;
            double next_target = 8 * (2 * inertial_random_unit(&random) - 1);
            double next_rate = 4 * (2 * inertial_random_unit(&random) - 1);
            InertialScalarState interrupted = anim::inertial_scalar_residual(
                offset: corrected_value - next_target,
                velocity: corrected_rate - next_rate,
                duration: 0.37,
                elapsed: 0,
            );
            assert(math::abs(next_target + interrupted.value - corrected_value) <= INERTIAL_TEST_SCALAR_EPSILON);
            assert(math::abs(next_rate + interrupted.rate - corrected_rate)
              <= INERTIAL_TEST_RATE_EPSILON * (1 + math::abs(corrected_rate)));
        }
    }
    assert(discriminations > 0);
    io::printfn("inertial seed=%s transitions=%s", INERTIAL_TEST_SEED, INERTIAL_TEST_CORPUS_COUNT);
    io::printfn("rate_error=%.17g scalar_error=%.17g", maximum_rate_error, maximum_scalar_error);
    io::printfn("naive velocity discriminations=%s", discriminations);
}

fn void test_animation_inertial_math_zero_completion_and_repeated_corrected_interruptions() @test {
    double[<3>] initial = { 0.4, -0.8, 0.2 };
    Quaternion target = inertial_input_rotation({ 0.2, 0.1, -0.5 });
    double[<3>] source_rate = { -0.4, 0.7, 1.1 };
    double[<3>] target_rate = { 0.2, -0.6, 0.3 };
    double[<3>] initial_rate = anim::inertial_onset_rotation_rate(initial, source_rate, target_rate);
    foreach (double elapsed : { 0.0, 1.0, 2.0 }) {
        InertialRotationState completed = anim::inertial_correct_rotation(
            initial: initial,
            initial_rate: initial_rate,
            duration: 0,
            elapsed: elapsed,
            target: target,
            target_rate: target_rate,
        );
        inertial_assert_matrix(completed.orientation, inertial_oracle_quaternion_matrix(target));
        inertial_assert_rate(completed.angular_velocity, target_rate);
    }
    foreach (double elapsed : { 1.0, 2.0 }) {
        InertialRotationState completed = anim::inertial_correct_rotation(
            initial: initial,
            initial_rate: initial_rate,
            duration: 1,
            elapsed: elapsed,
            target: target,
            target_rate: target_rate,
        );
        inertial_assert_matrix(completed.orientation, inertial_oracle_quaternion_matrix(target));
        inertial_assert_rate(completed.angular_velocity, target_rate);
    }
    foreach (double elapsed : { 1e-4, 0.5, 1 - 1e-6, 0.25 }) {
        Quaternion advanced = inertial_input_rotation(target_rate * elapsed).mul(target);
        InertialRotationState current = anim::inertial_correct_rotation(
            initial: initial,
            initial_rate: initial_rate,
            duration: 1,
            elapsed: elapsed,
            target: advanced,
            target_rate: target_rate,
        );
        Quaternion replacement = inertial_input_rotation({ -0.3, 0.2, 0.7 });
        double[<3>] replacement_rate = { -0.1, 0.5, -0.4 };
        initial = anim::inertial_rotation_log(current.orientation.mul(replacement.conjugate()));
        initial_rate = anim::inertial_onset_rotation_rate(initial, current.angular_velocity, replacement_rate);
        InertialRotationState onset = anim::inertial_correct_rotation(
            initial: initial,
            initial_rate: initial_rate,
            duration: 0.8,
            elapsed: 0,
            target: replacement,
            target_rate: replacement_rate,
        );
        inertial_assert_matrix(onset.orientation, inertial_oracle_quaternion_matrix(current.orientation));
        inertial_assert_rate(onset.angular_velocity, current.angular_velocity);
        target = replacement;
        target_rate = replacement_rate;
    }
}
