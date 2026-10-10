module c3d::test::animation_motion_domain;

import c3d;
import c3d::anim @public;
import std::math;

const uint MOTION_DOMAIN_CORPUS_SEED @local = 3532026;
const uint MOTION_DOMAIN_CORPUS_COUNT @local = 2000;

fn Track motion_rotation_track(Interpolation interpolation, float[] times, float[] values) @local {
    return { .path = TargetPath.ROTATION, .interpolation = interpolation, .times = times, .values = values };
}

fn Track motion_scale_track(Interpolation interpolation, float[] times, float[] values) @local {
    return { .path = TargetPath.SCALE, .interpolation = interpolation, .times = times, .values = values };
}

fn float[24] motion_rotation_cubic_values(
    float start,
    float end,
    float outgoing,
    float incoming,
) @local {
    return { 0, 0, 0, 0, 0, 0, 0, start, 0, 0, 0, outgoing,
        0, 0, 0, incoming, 0, 0, 0, end, 0, 0, 0, 0 };
}

fn float[18] motion_scale_cubic_values(
    float start,
    float end,
    float outgoing,
    float incoming,
) @local {
    return { 0, 0, 0, start, start, start, outgoing, outgoing, outgoing,
        incoming, incoming, incoming, end, end, end, 0, 0, 0 };
}

fn void expect_motion_rotation_fault(Track* track, fault expected) @local {
    bool caught;
    if (catch excuse = anim::validate_motion_rotation_track(track)) {
        assert(excuse == expected);
        caught = true;
    }
    assert(caught, "uncertified rotation domain was admitted");
}

fn void expect_motion_scale_invalid(Track* track, bool additive = false) @local {
    bool caught;
    if (catch excuse = anim::classify_consumed_scale_track(track, additive)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
        caught = true;
    }
    assert(caught, "invalid consumed scale domain was admitted");
}

fn uint motion_domain_random(uint* state) @local {
    *state ^= *state << 13;
    *state ^= *state >> 17;
    *state ^= *state << 5;
    return *state;
}

fn void test_animation_motion_rotation_step_linear_without_magnitude_limits() @test {
    float[2] times = { 0, 1 };
    float[4] magnitudes = { 0x1p-149, 1e-7, 1e16, 0x1.fffffep127 };
    Interpolation[2] modes = { Interpolation.STEP, Interpolation.LINEAR };
    foreach (mode : modes) {
        float[8] values;
        Track track = motion_rotation_track(mode, times[..], values[..]);
        foreach (magnitude : magnitudes) {
            values[3] = magnitude;
            values[7] = -magnitude;
            anim::validate_motion_rotation_track(&track)!!;
        }
        values = { 1, 0, 0, 0, 0, 1, 0, 0 };
        anim::validate_motion_rotation_track(&track)!!;
        values = {};
        expect_motion_rotation_fault(&track, c3d::INVALID_ARGUMENT);
        values[3] = 1;
        values[7] = bitcast(0x7fc00000u, float);
        expect_motion_rotation_fault(&track, c3d::INVALID_ARGUMENT);
        values[7] = bitcast(0x7f800000u, float);
        expect_motion_rotation_fault(&track, c3d::INVALID_ARGUMENT);
    }
}

fn void test_animation_motion_rotation_cubic_exact_zero_and_bounded_uncertainty() @test {
    float[2] times = { 0, 1 };
    float[24] values = motion_rotation_cubic_values(
        start: 1,
        end: 1,
        outgoing: -4,
        incoming: 4,
    );
    Track track = motion_rotation_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    // The scalar component is (1 - 2t)^2 and the other components vanish identically.
    expect_motion_rotation_fault(&track, c3d::INVALID_ARGUMENT);
    values[4] = values[16] = 1e-12;
    expect_motion_rotation_fault(&track, c3d::UNSUPPORTED);
    values[4] = values[16] = 0.01;
    anim::validate_motion_rotation_track(&track)!!;
    values = motion_rotation_cubic_values(
        start: -1,
        end: 2,
        outgoing: 3,
        incoming: 3,
    );
    // The raw scalar vanishes at 1/3; the finite dyadic subdivision cannot certify it.
    expect_motion_rotation_fault(&track, c3d::UNSUPPORTED);
    values[11] = bitcast(0x7fc00000u, float);
    expect_motion_rotation_fault(&track, c3d::INVALID_ARGUMENT);
}

fn void test_animation_motion_rotation_cubic_constants_and_timestamp_provenance() @test {
    float[2] times = { 0, 1 };
    float[3] magnitudes = { 0x1p-149, 1e-7, 1e16 };
    float[24] values;
    Track track = motion_rotation_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    foreach (magnitude : magnitudes) {
        values = motion_rotation_cubic_values(
            start: magnitude,
            end: magnitude,
            outgoing: 0,
            incoming: 0,
        );
        anim::validate_motion_rotation_track(&track)!!;
    }
    values = motion_rotation_cubic_values(
        start: 1,
        end: 1,
        outgoing: -4,
        incoming: 4,
    );
    times[0] = 0x1p-149;
    expect_motion_rotation_fault(&track, c3d::UNSUPPORTED);
    times[0] = times[1];
    expect_motion_rotation_fault(&track, c3d::INVALID_ARGUMENT);
}

fn void test_animation_motion_rotation_invalid_segment_precedes_unproven_segment() @test {
    float[3] times = { 0x1p-149, 1, 2 };
    float[36] values;
    for (uint key = 0; key < 3; key++) {
        values[key * 12 + 3] = 4;
        values[key * 12 + 7] = 1;
        values[key * 12 + 11] = -4;
    }
    Track track = motion_rotation_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    // First segment is positive but uncertain; the second has the exact zero at t=1.5.
    expect_motion_rotation_fault(&track, c3d::INVALID_ARGUMENT);
}

fn void test_animation_motion_rotation_seeded_analytic_positive_quadratics() @test {
    uint state = MOTION_DOMAIN_CORPUS_SEED;
    float[2] times = { 0, 1 };
    float[24] values;
    Track track = motion_rotation_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    for (uint sample = 0; sample < MOTION_DOMAIN_CORPUS_COUNT; sample++) {
        double floor = (double)(1 + motion_domain_random(&state) % 127) / 128;
        double curvature = (double)(1 + motion_domain_random(&state) % 127) / 64;
        double vertex = (double)(motion_domain_random(&state) % 64) / 64;
        // These dyadic values fit binary32 exactly: floor + curvature*(t-vertex)^2 is strictly positive.
        values = motion_rotation_cubic_values(
            start: (float)(floor + curvature * vertex * vertex),
            end: (float)(floor + curvature * (1 - vertex) * (1 - vertex)),
            outgoing: (float)(-2 * curvature * vertex),
            incoming: (float)(2 * curvature * (1 - vertex)),
        );
        assert(floor > 0 && vertex >= 0 && vertex < 1);
        assert((double)values[7] == floor + curvature * vertex * vertex);
        assert((double)values[19] == floor + curvature * (1 - vertex) * (1 - vertex));
        anim::validate_motion_rotation_track(&track)!!;
    }
}

fn void test_animation_motion_scale_step_linear_uniform_positive_domains() @test {
    float[2] times = { -1, 1 };
    Interpolation[2] modes = { Interpolation.STEP, Interpolation.LINEAR };
    float[6] values = { 0.5, 0.5, 0.5, 2, 2, 2 };
    foreach (mode : modes) {
        Track track = motion_scale_track(mode, times[..], values[..]);
        assert(anim::classify_consumed_scale_track(&track, false)!! == ConsumedScaleDomain.ADMITTED);
        values = { 0x1p-149, 0x1p-149, 0x1p-149, 0x1p-148, 0x1p-148, 0x1p-148 };
        assert(anim::classify_consumed_scale_track(&track, false)!! == ConsumedScaleDomain.ADMITTED);
        values = { 1, 1, 1, 1, 2, 1 };
        expect_motion_scale_invalid(&track);
        values = { 1, 1, 1, 0, 0, 0 };
        expect_motion_scale_invalid(&track);
        values = { 1, 1, 1, -1, -1, -1 };
        expect_motion_scale_invalid(&track);
        values = { 0.5, 0.5, 0.5, 2, 2, 2 };
    }
}

fn void test_animation_motion_scale_cubic_original_uniformity_and_exact_positivity() @test {
    float[2] times = { 0, 1 };
    float[18] values = motion_scale_cubic_values(
        start: 0.5,
        end: 2,
        outgoing: 1,
        incoming: 2,
    );
    Track track = motion_scale_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    assert(anim::classify_consumed_scale_track(&track, false)!! == ConsumedScaleDomain.ADMITTED);
    for (uint slot = 0; slot < 6; slot++) values[slot * 3 + 1] *= 0.9999975f;
    assert(anim::classify_consumed_scale_track(&track, false)!! == ConsumedScaleDomain.ADMITTED);
    values = motion_scale_cubic_values(
        start: 1,
        end: 1,
        outgoing: 0,
        incoming: 0,
    );
    values[7] = 0.01;
    expect_motion_scale_invalid(&track);
    values = motion_scale_cubic_values(
        start: 1,
        end: 1,
        outgoing: -4,
        incoming: 4,
    );
    expect_motion_scale_invalid(&track);
    values = motion_scale_cubic_values(
        start: 1,
        end: 1,
        outgoing: -8,
        incoming: 8,
    );
    expect_motion_scale_invalid(&track);
}

fn void test_animation_motion_scale_cubic_sampling_band_and_literal_shifted_controls() @test {
    float[2] times = { 0x1p-149, 1 };
    float[18] values = motion_scale_cubic_values(
        start: 1,
        end: 1,
        outgoing: -4,
        incoming: 4,
    );
    Track track = motion_scale_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    assert(anim::classify_consumed_scale_track(&track, false)!! == ConsumedScaleDomain.SAMPLING_UNPROVEN);
    values = motion_scale_cubic_values(
        start: 2,
        end: 2,
        outgoing: -4,
        incoming: 4,
    );
    assert(anim::classify_consumed_scale_track(&track, false)!! == ConsumedScaleDomain.ADMITTED);
    uint cursor;
    Vec3 sampled = anim::sample_multiplicative_scale(&track, 0.5, &cursor);
    assert(sampled.x == 1 && sampled.y == 1 && sampled.z == 1);
    times[0] = 0;
    values = motion_scale_cubic_values(
        start: 0x1p-126,
        end: 0x1p-126,
        outgoing: -bitcast(0x017fffffu, float),
        incoming: 0x1p-124,
    );
    assert(anim::classify_consumed_scale_track(&track, false)!! == ConsumedScaleDomain.SAMPLING_UNPROVEN);
    values[3] = values[4] = values[5] = values[12] = values[13] = values[14] = 0x1p-125;
    assert(anim::classify_consumed_scale_track(&track, false)!! == ConsumedScaleDomain.ADMITTED);
    sampled = anim::sample_multiplicative_scale(&track, 0.5, &cursor);
    assert(sampled.x == 0x1p-126 && sampled.y == 0x1p-126 && sampled.z == 0x1p-126);
}

fn void test_animation_motion_scale_exact_sampling_floor_equality_and_adjacent_keys() @test {
    float[2] times = { 0, 1 };
    float[18] values = motion_scale_cubic_values(
        start: 0x1p-125,
        end: 0x1p-125,
        outgoing: 0x1p-86,
        incoming: -0x1p-86,
    );
    Track track = motion_scale_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    // M=2^-86, so the floor is exactly 2^-126 + 2^-40*M = 2^-125.
    assert(anim::classify_consumed_scale_track(&track, false)!! == ConsumedScaleDomain.ADMITTED);
    values[3] = values[4] = values[5] = values[12] = values[13] = values[14] = bitcast(0x00ffffffu, float);
    assert(anim::classify_consumed_scale_track(&track, false)!! == ConsumedScaleDomain.SAMPLING_UNPROVEN);
    values[3] = values[4] = values[5] = values[12] = values[13] = values[14] = bitcast(0x01000001u, float);
    assert(anim::classify_consumed_scale_track(&track, false)!! == ConsumedScaleDomain.ADMITTED);
}

fn void test_animation_motion_scale_invalid_uniformity_precedes_pending_sampling_band() @test {
    float[3] times = { 0x1p-149, 1, 2 };
    float[27] values;
    for (uint key = 0; key < 3; key++) {
        for (uint component = 0; component < 3; component++) {
            values[key * 9 + component] = 4;
            values[key * 9 + 3 + component] = 1;
            values[key * 9 + 6 + component] = -4;
        }
    }
    values[15] = values[16] = values[17] = 0;
    values[18] = values[19] = values[20] = 0;
    values[16] = 0.01;
    Track track = motion_scale_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    expect_motion_scale_invalid(&track);
}

fn void test_animation_motion_scale_additive_neutrality_is_full_domain_and_difference_band_exempt() @test {
    float[2] times = { -1, 1 };
    Interpolation[2] modes = { Interpolation.STEP, Interpolation.LINEAR };
    float[6] values = { -1, 0, 2, -1, 0, 2 };
    foreach (mode : modes) {
        Track track = motion_scale_track(mode, times[..], values[..]);
        assert(anim::classify_consumed_scale_track(&track, true)!! == ConsumedScaleDomain.ADMITTED);
        values[4] = 0x1p-149;
        expect_motion_scale_invalid(&track, true);
        values[4] = 0;
    }
    float[18] cubic_values = { 0, 0, 0, -1, 0, 2, 0, 0, 0, 0, 0, 0, -1, 0, 2, 0, 0, 0 };
    Track cubic = motion_scale_track(Interpolation.CUBIC_SPLINE, times[..], cubic_values[..]);
    assert(anim::classify_consumed_scale_track(&cubic, true)!! == ConsumedScaleDomain.ADMITTED);
    cubic_values[6] = 0x1p-149;
    expect_motion_scale_invalid(&cubic, true);
    cubic_values[6] = 0;
    cubic_values[9] = 0x1p-149;
    expect_motion_scale_invalid(&cubic, true);
}
