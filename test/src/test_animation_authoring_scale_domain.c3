module c3d::test::animation_scale_domain;

import c3d;
import c3d::anim @public;
import std::math;

fn Track scale_domain_track(Interpolation interpolation, float[] times, float[] values) @local {
    return { .path = TargetPath.SCALE, .interpolation = interpolation, .times = times, .values = values };
}

fn void? validate_scale_domain_track(Track* track) @local {
    Track[1] tracks = { *track };
    uint[1] targets;
    AnimationClip clip = { .tracks = tracks[..], .targets = targets[..] };
    return anim::validate_multiplicative_scale(&clip);
}

fn void expect_scale_domain_invalid(Track* track) @local {
    bool caught;
    if (catch excuse = validate_scale_domain_track(track)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
        caught = true;
    }
    assert(caught, "invalid scale domain was admitted");
}

fn float[18] scale_domain_cubic_values(
    float start,
    float end,
    float outgoing,
    float incoming,
) @local {
    return { 0, 0, 0, start, start, start, outgoing, outgoing, outgoing,
        incoming, incoming, incoming, end, end, end, 0, 0, 0 };
}

fn void test_animation_scale_domain_step_linear_and_unrelated_channels() @test {
    float[3] times = { 0, 1, 2 };
    float[9] values = { 0x1p-149, 1, 0x1.fffffep127, 2, 3, 4, 5, 6, 7 };
    Interpolation[2] modes = { Interpolation.STEP, Interpolation.LINEAR };
    foreach (mode : modes) {
        Track track = scale_domain_track(mode, times[..], values[..]);
        validate_scale_domain_track(&track)!!;
        Vec3 reference = anim::sample_multiplicative_scale_reference(&track);
        assert(reference.x == values[0] && reference.y == values[1] && reference.z == values[2]);
        values[4] = 0;
        expect_scale_domain_invalid(&track);
        values[4] = -1;
        expect_scale_domain_invalid(&track);
        values[4] = bitcast(0x7f800000u, float);
        expect_scale_domain_invalid(&track);
        values[4] = bitcast(0x7fc00000u, float);
        expect_scale_domain_invalid(&track);
        values[4] = 3;
    }
    Track unrelated = scale_domain_track(Interpolation.LINEAR, times[..], values[..]);
    unrelated.path = TargetPath.TRANSLATION;
    values[0] = -1;
    values[1] = bitcast(0x7fc00000u, float);
    validate_scale_domain_track(&unrelated)!!;
}

fn void test_animation_scale_domain_cubic_interior_zero_negative_and_adjacent_positive() @test {
    float[2] times = { 0, 1 };
    float[18] values = scale_domain_cubic_values(start: 1, end: 1, outgoing: -4, incoming: 4);
    Track track = scale_domain_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    expect_scale_domain_invalid(&track);
    uint cursor;
    Vec3 at_minimum = anim::sample_multiplicative_scale(&track, 0.5, &cursor);
    assert(at_minimum.x == 0);
    values = scale_domain_cubic_values(start: 1, end: 1, outgoing: -8, incoming: 8);
    expect_scale_domain_invalid(&track);
    at_minimum = anim::sample_multiplicative_scale(&track, 0.5, &cursor);
    assert(at_minimum.x == -1);
    float adjacent = bitcast(0x3f800001u, float);
    values = scale_domain_cubic_values(start: adjacent, end: adjacent, outgoing: -4, incoming: 4);
    validate_scale_domain_track(&track)!!;
    at_minimum = anim::sample_multiplicative_scale(&track, 0.5, &cursor);
    assert(at_minimum.x == 0x1p-23 && at_minimum.y == 0x1p-23 && at_minimum.z == 0x1p-23);
    float below = bitcast(0x3f7fffffu, float);
    values = scale_domain_cubic_values(start: below, end: below, outgoing: -4, incoming: 4);
    expect_scale_domain_invalid(&track);
}

fn void test_animation_scale_domain_exact_binary32_timestamp_and_endpoint_provenance() @test {
    float[2] times = { 0x1p-149, 1 };
    float[18] values = scale_domain_cubic_values(start: 1, end: 1, outgoing: -4, incoming: 4);
    Track track = scale_domain_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    validate_scale_domain_track(&track)!!;
    times[0] = 0;
    expect_scale_domain_invalid(&track);
    values = scale_domain_cubic_values(start: 1, end: 0x1p-63, outgoing: 0x1p60, incoming: 1);
    expect_scale_domain_invalid(&track);
    values = scale_domain_cubic_values(start: 1, end: 0x1p-149, outgoing: 0, incoming: 0);
    validate_scale_domain_track(&track)!!;
    values = scale_domain_cubic_values(start: 1, end: 0, outgoing: 0x1p60, incoming: -0x1p60);
    expect_scale_domain_invalid(&track);
}

fn void test_animation_scale_domain_cubic_two_extrema_and_off_center_zero_touch() @test {
    float[2] times = { 0, 1 };
    float[18] values = scale_domain_cubic_values(start: 1, end: 2, outgoing: 6, incoming: 6);
    Track track = scale_domain_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    validate_scale_domain_track(&track)!!;
    double root_offset = math::sqrt(0.05);
    double[2] extrema = { 0.5 - root_offset, 0.5 + root_offset };
    uint cursor;
    foreach (fraction : extrema) {
        double expected = 1 + fraction * (6 + fraction * (-15 + fraction * 10));
        Vec3 actual = anim::sample_multiplicative_scale(&track, (float)fraction, &cursor);
        assert(expected > 1 && expected < 2);
        assert(math::abs((double)actual.x - expected) < 1e-6);
    }
    values = scale_domain_cubic_values(start: 0.0625, end: 1.125, outgoing: -0.4375, incoming: 3.5625);
    expect_scale_domain_invalid(&track);
    Vec3 touch = anim::sample_multiplicative_scale(&track, 0.25, &cursor);
    assert(touch.x == 0);
    values = scale_domain_cubic_values(
        start: 0.05859375,
        end: 1.12109375,
        outgoing: -0.4375,
        incoming: 3.5625,
    );
    expect_scale_domain_invalid(&track);
    touch = anim::sample_multiplicative_scale(&track, 0.25, &cursor);
    assert(touch.x == -0.00390625);
}

fn void test_animation_scale_domain_has_no_magnitude_floor_or_ceiling() @test {
    float[2] times = { -0x1.fffffep127, 0x1.fffffep127 };
    float[3] magnitudes = { 0x1p-149, 0x1p-120, 0x1.fffffep127 };
    uint cursor;
    foreach (magnitude : magnitudes) {
        float[18] values = scale_domain_cubic_values(
            start: magnitude,
            end: magnitude,
            outgoing: 0,
            incoming: 0,
        );
        Track track = scale_domain_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
        validate_scale_domain_track(&track)!!;
        Vec3 sample = anim::sample_multiplicative_scale(&track, 0, &cursor);
        assert(sample.x == magnitude && sample.y == magnitude && sample.z == magnitude);
        Vec3 reference = anim::sample_multiplicative_scale_reference(&track);
        assert(reference.x == magnitude && reference.y == magnitude && reference.z == magnitude);
        times[0] = 0;
        times[1] = 0x1p-149;
        validate_scale_domain_track(&track)!!;
        sample = anim::sample_multiplicative_scale(&track, times[1], &cursor);
        assert(sample.x == magnitude);
        times[0] = -0x1.fffffep127;
        times[1] = 0x1.fffffep127;
    }
}

fn void test_animation_scale_domain_reference_is_the_interpolated_time_zero_sample() @test {
    float[2] times = { -1, 1 };
    float[6] linear_values = { 2, 4, 8, 4, 8, 16 };
    Track linear = scale_domain_track(Interpolation.LINEAR, times[..], linear_values[..]);
    validate_scale_domain_track(&linear)!!;
    Vec3 linear_reference = anim::sample_multiplicative_scale_reference(&linear);
    assert(linear_reference.x == 3 && linear_reference.y == 6 && linear_reference.z == 12);
    Track step = scale_domain_track(Interpolation.STEP, times[..], linear_values[..]);
    validate_scale_domain_track(&step)!!;
    Vec3 step_reference = anim::sample_multiplicative_scale_reference(&step);
    assert(step_reference.x == 2 && step_reference.y == 4 && step_reference.z == 8);
    float[18] cubic_values = scale_domain_cubic_values(start: 2, end: 4, outgoing: 1, incoming: 1);
    Track cubic = scale_domain_track(Interpolation.CUBIC_SPLINE, times[..], cubic_values[..]);
    validate_scale_domain_track(&cubic)!!;
    Vec3 cubic_reference = anim::sample_multiplicative_scale_reference(&cubic);
    assert(cubic_reference.x == 3 && cubic_reference.y == 3 && cubic_reference.z == 3);
    times[0] = 1;
    times[1] = 2;
    cubic_reference = anim::sample_multiplicative_scale_reference(&cubic);
    assert(cubic_reference.x == 2);
    times[0] = -2;
    times[1] = -1;
    cubic_reference = anim::sample_multiplicative_scale_reference(&cubic);
    assert(cubic_reference.x == 4);
}

fn void test_animation_scale_domain_sampling_matches_independent_quadratic_and_cursor_rules() @test {
    float[3] times = { -1, 1, 3 };
    float[27] values = {
        0, 0, 0, 1.0625, 1.0625, 1.0625, -1.25, -1.25, -1.25,
        0.75, 0.75, 0.75, 0.5625, 0.5625, 0.5625, 0, 0, 0,
        0, 0, 0, 0.5625, 0.5625, 0.5625, 0, 0, 0,
    };
    Track track = scale_domain_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    validate_scale_domain_track(&track)!!;
    uint cursor = uint::max;
    float[7] probes = { 0.25, -0.5, 0.5, -1, 3, 1, 2 };
    foreach (time : probes) {
        Vec3 actual = anim::sample_multiplicative_scale(&track, time, &cursor);
        double fraction = ((double)time + 1) / 2;
        double expected = time <= 1 ? 0.28125 + 2 * (fraction - 0.625) * (fraction - 0.625) : 0.5625;
        assert(math::abs((double)actual.x - expected) < 1e-7);
        assert(actual.x == actual.y && actual.y == actual.z);
        assert(cursor == (time >= 3 ? 2u : (time >= 1 ? 1u : 0u)));
    }
}

fn void test_animation_scale_domain_rejects_nonfinite_tangents_and_bad_time_or_width() @test {
    float[2] times = { 0, 1 };
    float[18] values = scale_domain_cubic_values(start: 1, end: 2, outgoing: 0, incoming: 0);
    Track track = scale_domain_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    values[6] = bitcast(0x7f800000u, float);
    expect_scale_domain_invalid(&track);
    values[6] = 0;
    times[1] = 0;
    expect_scale_domain_invalid(&track);
    times[1] = bitcast(0x7fc00000u, float);
    expect_scale_domain_invalid(&track);
    times[1] = 1;
    track.values = values[:17];
    expect_scale_domain_invalid(&track);
    track.values = values[..];
    track.times = times[:0];
    expect_scale_domain_invalid(&track);
}
