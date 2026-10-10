module c3d::test::analytic_sample;

import c3d::anim @public;
import std::math;

const double ANALYTIC_TEST_VALUE_EPSILON @local = 1e-10;
const double ANALYTIC_TEST_RATE_EPSILON @local = 1e-9;

fn Matrix3 analytic_test_matrix_product(Matrix3 left, Matrix3 right) @local {
    Matrix3 result;
    for (uint row = 0; row < 3; row++) for (uint column = 0; column < 3; column++) {
        for (uint inner = 0; inner < 3; inner++) {
            result.m[column * 3 + row] += left.m[inner * 3 + row] * right.m[column * 3 + inner];
        }
    }
    return result;
}

fn Matrix3 analytic_test_axis_matrix(double[<3>] axis, double angle) @local {
    Matrix3 skew = { .m = { 0, axis.z, -axis.y, -axis.z, 0, axis.x, axis.y, -axis.x, 0 } };
    Matrix3 squared = analytic_test_matrix_product(skew, skew);
    Matrix3 identity = { .m = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } };
    return { .m = identity.m + skew.m * math::sin(angle) + squared.m * (1 - math::cos(angle)) };
}

fn Matrix3 analytic_test_axis_matrix_rate(double[<3>] axis, double angle, double rate) @local {
    Matrix3 skew = { .m = { 0, axis.z, -axis.y, -axis.z, 0, axis.x, axis.y, -axis.x, 0 } };
    Matrix3 squared = analytic_test_matrix_product(skew, skew);
    return { .m = (skew.m * math::cos(angle) + squared.m * math::sin(angle)) * rate };
}

fn Matrix3 analytic_test_quaternion_matrix(double[] value) @local {
    double x = value[0];
    double y = value[1];
    double z = value[2];
    double w = value[3];
    return {
        .m = {
            1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w),
            2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w),
            2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y),
        },
    };
}

fn Matrix3 analytic_test_quaternion_matrix_rate(double[] value, double[] rate) @local {
    double x = value[0];
    double y = value[1];
    double z = value[2];
    double w = value[3];
    double dx = rate[0];
    double dy = rate[1];
    double dz = rate[2];
    double dw = rate[3];
    return {
        .m = {
            -4 * (y * dy + z * dz),
            2 * (dx * y + x * dy + dz * w + z * dw),
            2 * (dx * z + x * dz - dy * w - y * dw),
            2 * (dx * y + x * dy - dz * w - z * dw),
            -4 * (x * dx + z * dz),
            2 * (dy * z + y * dz + dx * w + x * dw),
            2 * (dx * z + x * dz + dy * w + y * dw),
            2 * (dy * z + y * dz - dx * w - x * dw),
            -4 * (x * dx + y * dy),
        },
    };
}

fn void analytic_test_rotation(
    double[] value,
    double[] rate,
    double[<3>] axis,
    double angle,
    double angle_rate,
) @local {
    Matrix3 actual = analytic_test_quaternion_matrix(value);
    Matrix3 derivative = analytic_test_quaternion_matrix_rate(value, rate);
    Matrix3 expected = analytic_test_axis_matrix(axis, angle);
    Matrix3 expected_rate = analytic_test_axis_matrix_rate(axis, angle, angle_rate);
    double norm;
    double tangent;
    for (uint component = 0; component < 4; component++) {
        assert(math::is_finite(value[component]) && math::is_finite(rate[component]));
        norm += value[component] * value[component];
        tangent += value[component] * rate[component];
    }
    assert(math::abs(norm - 1) <= ANALYTIC_TEST_VALUE_EPSILON);
    assert(math::abs(tangent) <= ANALYTIC_TEST_RATE_EPSILON * (1 + math::abs(angle_rate)));
    for (uint index = 0; index < 9; index++) {
        assert(math::abs(actual.m[index] - expected.m[index]) <= ANALYTIC_TEST_VALUE_EPSILON);
        assert(math::abs(derivative.m[index] - expected_rate.m[index])
          <= ANALYTIC_TEST_RATE_EPSILON * (1 + math::abs(angle_rate)));
    }
}

fn void test_animation_analytic_sample_step_sides_keys_endpoints_and_normal_cursor() @test {
    float[3] times = { 0, 0.5f, 1 };
    float[9] values = { 0, 0, 0, 10, 20, -5, 30, 40, -10 };
    float[3] saved_times = times;
    float[9] saved_values = values;
    Track track = { .path = TargetPath.TRANSLATION, .interpolation = Interpolation.STEP,
        .times = times[..], .values = values[..] };
    foreach (StepSampleSide side : { StepSampleSide.EXACT, StepSampleSide.LEFT, StepSampleSide.RIGHT }) {
        for (uint key = 0; key < 3; key++) {
            uint cursor = uint::max;
            float time = times[key];
            uint time_bits = bitcast(time, uint);
            double[3] actual;
            double[3] rate = { double::nan, double::nan, double::nan };
            anim::sample_track_analytic(
                track: &track,
                time: time,
                cursor: &cursor,
                value: actual[..],
                rate: rate[..],
                side: side,
            );
            uint sampled = side == StepSampleSide.LEFT && key ? key - 1 : key;
            for (uint channel = 0; channel < 3; channel++) {
                assert(actual[channel] == values[sampled * 3 + channel] && rate[channel] == 0);
            }
            assert(cursor == key && bitcast(time, uint) == time_bits);
        }
        foreach (float time : { -1.0f, 0.25f, 0.75f, 2.0f }) {
            uint cursor = 2;
            double[3] actual;
            double[3] rate;
            anim::sample_track_analytic(
                track: &track,
                time: time,
                cursor: &cursor,
                value: actual[..],
                rate: rate[..],
                side: side,
            );
            uint key = time < 0.5f ? 0 : time < 1 ? 1 : 2;
            assert(cursor == key);
            for (uint channel = 0; channel < 3; channel++) {
                assert(actual[channel] == values[key * 3 + channel] && rate[channel] == 0);
            }
        }
    }
    assert(times == saved_times && values == saved_values);
}

fn void test_animation_analytic_sample_linear_full_morph_width_and_sided_key_derivatives() @test {
    float[3] times = { 0, 0.5f, 2 };
    float[15] values = { 0, 2, -1, 4, 10, 2, 0, 3, 8, -5, 8, 6, 0, -4, 5 };
    Track track = { .path = TargetPath.MORPH_WEIGHTS, .interpolation = Interpolation.LINEAR,
        .times = times[..], .values = values[..] };
    double[5] actual;
    double[5] rate;
    uint cursor;
    anim::sample_track_analytic(
        track: &track,
        time: 0.25f,
        cursor: &cursor,
        value: actual[..],
        rate: rate[..],
    );
    double[5] expected = { 1, 1, 1, 6, 2.5 };
    double[5] first_rates = { 4, -4, 8, 8, -30 };
    foreach (index, value : expected) assert(actual[index] == value && rate[index] == first_rates[index]);
    foreach (StepSampleSide side : { StepSampleSide.EXACT, StepSampleSide.LEFT, StepSampleSide.RIGHT }) {
        anim::sample_track_analytic(
            track: &track,
            time: 0.5f,
            cursor: &cursor,
            value: actual[..],
            rate: rate[..],
            side: side,
        );
        assert(cursor == 1);
        double[5] next_rates = { 4, 4, -2, -8, 20.0 / 3 };
        for (uint channel = 0; channel < 5; channel++) {
            assert(actual[channel] == values[5 + channel]);
            double expected_rate = side == StepSampleSide.LEFT ? first_rates[channel] : next_rates[channel];
            assert(math::abs(rate[channel] - expected_rate) < 1e-12);
        }
    }
    foreach (float time : { -1.0f, 3.0f }) {
        anim::sample_track_analytic(
            track: &track,
            time: time,
            cursor: &cursor,
            value: actual[..],
            rate: rate[..],
        );
        uint key = time < 0 ? 0 : 2;
        assert(cursor == key);
        for (uint channel = 0; channel < 5; channel++) assert(actual[channel] == values[key * 5 + channel]);
        foreach (derivative : rate) assert(derivative == 0);
    }
}

fn void test_animation_analytic_sample_cubic_matches_independent_power_polynomials() @test {
    float[2] times = { -1, 1 };
    float[18] values = { 99, 99, 99, 1, -2, 0, 1, 0.25f, 0, 4, 0.75f, 1.5f, 4, -0.5f, 1, -99, -99, -99 };
    Track track = { .path = TargetPath.TRANSLATION, .interpolation = Interpolation.CUBIC_SPLINE,
        .times = times[..], .values = values[..] };
    foreach (float time : { -1.0f, -0.5f, 0.0f, 0.5f, 1.0f }) {
        uint cursor = uint::max;
        double[3] actual;
        double[3] rate;
        anim::sample_track_analytic(
            track: &track,
            time: time,
            cursor: &cursor,
            value: actual[..],
            rate: rate[..],
        );
        double u = ((double)time + 1) / 2;
        double[3] expected = { ((4 * u - 3) * u + 2) * u + 1,
            ((-u + 2) * u + 0.5) * u - 2, u * u * u };
        double[3] expected_rate = { ((12 * u - 6) * u + 2) / 2,
            ((-3 * u + 4) * u + 0.5) / 2, 1.5 * u * u };
        for (uint channel = 0; channel < 3; channel++) {
            assert(math::abs(actual[channel] - expected[channel]) < 1e-12);
            assert(math::abs(rate[channel] - expected_rate[channel]) < 1e-12);
        }
        assert(cursor == (time == 1 ? 1u : 0u));
    }
}

fn void test_animation_analytic_sample_linear_rotation_matches_matrix_values_and_derivatives() @test {
    double[<3>] axis = { 2.0 / 3, -1.0 / 3, 2.0 / 3 };
    float[2] times = { 0, 2 };
    foreach (double angle : { 0.2, 0.4, 1.2, math::PI }) {
        Quaternion endpoint = quaternion::from_axis_angle{double}(axis, angle);
        for (uint sign = 0; sign < 2; sign++) {
            float[8] values = { 0, 0, 0, 1, 0, 0, 0, 0 };
            for (uint component = 0; component < 4; component++) {
                values[4 + component] = (float)endpoint.v[component] * (sign ? -1 : 1);
            }
            Track track = { .path = TargetPath.ROTATION, .interpolation = Interpolation.LINEAR,
                .times = times[..], .values = values[..] };
            double[<3>] stored_axis = { values[4], values[5], values[6] };
            double stored_w = values[7];
            if (stored_w < 0) {
                stored_axis = -stored_axis;
                stored_w = -stored_w;
            }
            double length = stored_axis.length();
            double magnitude = math::sqrt(length * length + stored_w * stored_w);
            double sine = length / magnitude;
            double cosine = stored_w / magnitude;
            double complete_angle = 2 * math::atan2(length, stored_w);
            double[<3>] expected_axis = stored_axis / length;
            foreach (float time : { 0.0f, 0.5f, 1.0f, 1.5f, 2.0f }) {
                uint cursor = uint::max;
                double[4] value;
                double[4] rate;
                anim::sample_track_analytic(
                    track: &track,
                    time: time,
                    cursor: &cursor,
                    value: value[..],
                    rate: rate[..],
                );
                double u = (double)time / 2;
                double expected_angle;
                double expected_rate;
                if (cosine > (double)0.95f) {
                    double numerator = u * sine;
                    double denominator = 1 - u + u * cosine;
                    expected_angle = 2 * math::atan2(numerator, denominator);
                    expected_rate = sine / (numerator * numerator + denominator * denominator);
                } else {
                    expected_angle = complete_angle * u;
                    expected_rate = complete_angle / 2;
                }
                analytic_test_rotation(
                    value: value[..],
                    rate: rate[..],
                    axis: expected_axis,
                    angle: expected_angle,
                    angle_rate: expected_rate,
                );
                assert(cursor == (time == 2 ? 1u : 0u));
            }
        }
    }
}

fn void test_animation_analytic_sample_tiny_huge_rotation_keys_remain_normalized() @test {
    float[3] magnitudes = { 0x1p-140f, 1, 0x1p120f };
    float[2] times = { 0, 2 };
    foreach (uint index, first : magnitudes) {
        float second = magnitudes[(index + 1) % 3];
        float[8] values = { 0, 0, 0, first, 0, second * 0.6f, 0, second * 0.8f };
        Track track = { .path = TargetPath.ROTATION, .interpolation = Interpolation.LINEAR,
            .times = times[..], .values = values[..] };
        double complete_angle = 2 * math::atan2((double)values[5], (double)values[7]);
        uint cursor;
        double[4] value;
        double[4] rate;
        anim::sample_track_analytic(
            track: &track,
            time: 0.75f,
            cursor: &cursor,
            value: value[..],
            rate: rate[..],
        );
        analytic_test_rotation(
            value: value[..],
            rate: rate[..],
            axis: { 0, 1, 0 },
            angle: complete_angle * 0.375,
            angle_rate: complete_angle / 2,
        );
        track.interpolation = Interpolation.STEP;
        foreach (StepSampleSide side : { StepSampleSide.EXACT, StepSampleSide.LEFT, StepSampleSide.RIGHT }) {
            anim::sample_track_analytic(
                track: &track,
                time: 2,
                cursor: &cursor,
                value: value[..],
                rate: rate[..],
                side: side,
            );
            analytic_test_rotation(
                value: value[..],
                rate: rate[..],
                axis: { 0, 1, 0 },
                angle: side == StepSampleSide.LEFT ? 0 : complete_angle,
                angle_rate: 0,
            );
            assert(cursor == 1);
        }
    }
}

fn void test_animation_analytic_sample_cubic_rotation_matches_normalized_polynomial_matrix_rate() @test {
    float[2] times = { 0, 2 };
    foreach (float magnitude : { 0x1p-140f, 1.0f, 0x1p120f }) {
        float[24] values;
        values[7] = magnitude;
        values[10] = magnitude * 0.5f;
        values[15] = magnitude * -0.25f;
        values[18] = magnitude;
        Track track = { .path = TargetPath.ROTATION, .interpolation = Interpolation.CUBIC_SPLINE,
            .times = times[..], .values = values[..] };
        foreach (float time : { 0.0f, 0.5f, 1.0f, 1.5f, 2.0f }) {
            uint cursor;
            double[4] value;
            double[4] rate;
            anim::sample_track_analytic(
                track: &track,
                time: time,
                cursor: &cursor,
                value: value[..],
                rate: rate[..],
            );
            double u = (double)time / 2;
            double z = ((-u + 1) * u + 1) * u;
            double w = (1.5 * u - 2.5) * u * u + 1;
            double dz = ((-3 * u + 2) * u + 1) / 2;
            double dw = (4.5 * u - 5) * u / 2;
            double angle = 2 * math::atan2(z, w);
            double angle_rate = 2 * (w * dz - z * dw) / (z * z + w * w);
            analytic_test_rotation(
                value: value[..],
                rate: rate[..],
                axis: { 0, 0, 1 },
                angle: angle,
                angle_rate: angle_rate,
            );
        }
    }
}

fn void test_animation_analytic_sample_single_key_and_held_values_have_zero_rate() @test {
    float[1] times = { 0.5f };
    float[3] values = { -2, 3, 5 };
    Track track = { .path = TargetPath.SCALE, .interpolation = Interpolation.LINEAR,
        .times = times[..], .values = values[..] };
    foreach (float time : { -1.0f, 0.5f, 2.0f }) {
        uint cursor = uint::max;
        double[3] value;
        double[3] rate = { double::nan, double::nan, double::nan };
        anim::sample_track_analytic(
            track: &track,
            time: time,
            cursor: &cursor,
            value: value[..],
            rate: rate[..],
            side: StepSampleSide.LEFT,
        );
        assert(cursor == 0);
        for (uint component = 0; component < 3; component++) {
            assert(value[component] == values[component] && rate[component] == 0);
        }
    }
    float[2] rotation_times = { 0, 1 };
    float[8] rotation_values = { 0, 0, 0, 0x1p-140f, 0, 0x1p120f, 0, 0 };
    Track rotation = { .path = TargetPath.ROTATION, .interpolation = Interpolation.LINEAR,
        .times = rotation_times[..], .values = rotation_values[..] };
    foreach (float time : { -1.0f, 2.0f }) {
        uint cursor;
        double[4] value;
        double[4] rate;
        anim::sample_track_analytic(
            track: &rotation,
            time: time,
            cursor: &cursor,
            value: value[..],
            rate: rate[..],
        );
        analytic_test_rotation(
            value: value[..],
            rate: rate[..],
            axis: { 0, 1, 0 },
            angle: time < 0 ? 0 : math::PI,
            angle_rate: 0,
        );
    }
}
