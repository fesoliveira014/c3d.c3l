module c3d::test::anim;

import c3d;
import c3d::anim @public;
import c3d::asset;
import std::math;

const double ONSET_RATE_TEST_EPSILON @local = 1e-3;

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
            anim::sample_track_analytic(
                track: &track,
                time: time,
                cursor: &cursor,
                value: actual[..],
                side: side,
            );
            uint sampled = side == StepSampleSide.LEFT && key ? key - 1 : key;
            for (uint channel = 0; channel < 3; channel++) assert(actual[channel] == values[sampled * 3 + channel]);
            assert(cursor == key && bitcast(time, uint) == time_bits);
        }
        foreach (float time : { -1.0f, 0.25f, 0.75f, 2.0f }) {
            uint cursor = 2;
            double[3] actual;
            anim::sample_track_analytic(
                track: &track,
                time: time,
                cursor: &cursor,
                value: actual[..],
                side: side,
            );
            uint key = time < 0.5f ? 0 : time < 1 ? 1 : 2;
            assert(cursor == key);
            for (uint channel = 0; channel < 3; channel++) assert(actual[channel] == values[key * 3 + channel]);
        }
    }
    assert(times == saved_times && values == saved_values);
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
        anim::sample_track_analytic(
            track: &track,
            time: 0.75f,
            cursor: &cursor,
            value: value[..],
        );
        double[<4>] sampled = { value[0], value[1], value[2], value[3] };
        assert(math::abs(sampled.length() - 1) < 1e-12);
        assert(math::abs(2 * math::atan2(value[1], value[3]) - complete_angle * 0.375) < 1e-12);
        track.interpolation = Interpolation.STEP;
        foreach (StepSampleSide side : { StepSampleSide.EXACT, StepSampleSide.LEFT, StepSampleSide.RIGHT }) {
            anim::sample_track_analytic(
                track: &track,
                time: 2,
                cursor: &cursor,
                value: value[..],
                side: side,
            );
            double expected = side == StepSampleSide.LEFT ? 0 : complete_angle;
            assert(math::abs(2 * math::atan2(value[1], value[3]) - expected) < 1e-12);
            assert(cursor == 1);
        }
    }
}

fn void test_animation_inertial_onset_target_velocity_follows_the_target_clock() @test {
    foreach (bool playing : { true, false }) {
        LayerFixture fixture;
        create_inertial_owner(&fixture);
        defer destroy_layer_fixture(&fixture);
        Quat turned = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 1);
        float[2] times = { 0, 1 };
        float[6] positions = { 0, 0, 0, 4, 8, -2 };
        float[8] rotations = { 0, 0, 0, 1, turned.v.x, turned.v.y, turned.v.z, turned.v.w };
        Track[2] tracks = {
            make_track(
                path: TargetPath.TRANSLATION,
                interpolation: Interpolation.LINEAR,
                times: times[..],
                values: positions[..],
            ),
            make_track(
                path: TargetPath.ROTATION,
                interpolation: Interpolation.LINEAR,
                times: times[..],
                values: rotations[..],
            ),
        };
        uint[1] targets = { 3 };
        ClipId clip = add_clip(
            assets: &fixture.assets,
            key: "",
            tracks: tracks[..],
            targets: targets[..],
            duration: 1,
        );
        AnimationActionId source = fixture.animator.play(&fixture.assets, clip)!!;
        fixture.animator.action(source).time = 0.25f;
        fixture.animator.action(source).playing = false;
        anim::update(&fixture.assets, &fixture.scene, 0);

        AnimationTargetDesc[1] request = { anim::ANIMATION_TARGET_DEFAULT };
        request[0].clip = clip;
        request[0].start_time = 0.25f;
        request[0].speed = -2;
        request[0].playing = playing;
        fixture.animator.inertialize(&fixture.assets, { .duration = 0.5f, .actions = request[..] })!!;

        PoseVelocity offset_rate = inertial_owner_row(&fixture).offset_velocity[3];
        double[<3>] translation = playing ? (double[<3>]){ 8, 16, -4 } : (double[<3>]){};
        double[<3>] angular = playing ? (double[<3>]){ 0, 2, 0 } : (double[<3>]){};
        assert((offset_rate.translation - translation).length() < ONSET_RATE_TEST_EPSILON);
        assert((offset_rate.angular - angular).length() < ONSET_RATE_TEST_EPSILON);
    }
}
