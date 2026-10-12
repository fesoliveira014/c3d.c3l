module c3d::test::animation_motion_domain;

import c3d;
import c3d::anim @public;

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
    assert(caught, "invalid rotation domain was admitted");
}

fn void expect_motion_scale_invalid(Track* track, bool additive = false) @local {
    bool caught;
    if (catch excuse = anim::validate_consumed_scale_track(track, additive)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
        caught = true;
    }
    assert(caught, "invalid consumed scale domain was admitted");
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

fn void test_animation_motion_rotation_cubic_crossing_zero_is_admitted_and_samples_identity() @test {
    float[2] times = { 0, 1 };
    float[24] values = motion_rotation_cubic_values(
        start: 1,
        end: 1,
        outgoing: -4,
        incoming: 4,
    );
    Track track = motion_rotation_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    anim::validate_motion_rotation_track(&track)!!;
    uint cursor;
    double[4] sampled;
    // The scalar component is (1 - 2t)^2 and the other components vanish identically.
    anim::sample_track_double(
        track: &track,
        time: 0.5f,
        cursor: &cursor,
        value: sampled[..],
    );
    assert(sampled == (double[4]){ 0, 0, 0, 1 });
}

fn void test_animation_motion_scale_step_linear_uniform_positive_domains() @test {
    float[2] times = { -1, 1 };
    Interpolation[2] modes = { Interpolation.STEP, Interpolation.LINEAR };
    float[6] values = { 0.5, 0.5, 0.5, 2, 2, 2 };
    foreach (mode : modes) {
        Track track = motion_scale_track(mode, times[..], values[..]);
        assert(!anim::validate_consumed_scale_track(&track, false)!!);
        values = { 0x1p-149, 0x1p-149, 0x1p-149, 0x1p-148, 0x1p-148, 0x1p-148 };
        assert(!anim::validate_consumed_scale_track(&track, false)!!);
        values = { 0.5, 0.5f * 0.9999975f, 0.5, 2, 2 * 0.9999975f, 2 };
        assert(!anim::validate_consumed_scale_track(&track, false)!!);
        values = { 1, 1, 1, 1, 2, 1 };
        expect_motion_scale_invalid(&track);
        values = { 1, 1, 1, 0, 0, 0 };
        expect_motion_scale_invalid(&track);
        values = { 1, 1, 1, -1, -1, -1 };
        expect_motion_scale_invalid(&track);
        values = { 0.5, 0.5, 0.5, 2, 2, 2 };
    }
}

fn void test_animation_motion_scale_step_linear_additive_neutrality_covers_every_key() @test {
    float[2] times = { -1, 1 };
    Interpolation[2] modes = { Interpolation.STEP, Interpolation.LINEAR };
    float[6] values = { -1, 0, 2, -1, 0, 2 };
    foreach (mode : modes) {
        Track track = motion_scale_track(mode, times[..], values[..]);
        assert(!anim::validate_consumed_scale_track(&track, true)!!);
        values[4] = 0x1p-149;
        expect_motion_scale_invalid(&track, true);
        values[4] = 0;
    }
}

fn void test_animation_motion_scale_cubic_is_unsupported_after_key_checks() @test {
    float[2] times = { 0, 1 };
    float[18] values = motion_scale_cubic_values(
        start: 2,
        end: 2,
        outgoing: 0,
        incoming: 0,
    );
    Track track = motion_scale_track(Interpolation.CUBIC_SPLINE, times[..], values[..]);
    assert(anim::validate_consumed_scale_track(&track, false)!!);
    assert(anim::validate_consumed_scale_track(&track, true)!!);
    values[4] = 1;
    expect_motion_scale_invalid(&track);
    expect_motion_scale_invalid(&track, true);
}
