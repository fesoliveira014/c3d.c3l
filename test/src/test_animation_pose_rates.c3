module c3d::test::anim;

import c3d;
import c3d::anim @public;
import c3d::asset;
import std::math;

const double ONSET_RATE_TEST_EPSILON @local = 1e-3;

struct OnsetRateCase @local {
    float start;
    bool playing;
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

fn void test_animation_analytic_sample_cubic_value_at_segment_midpoint() @test {
    float[2] times = { -1, 1 };
    float[18] values = { 99, 99, 99, 1, -2, 0, 1, 0.25f, 0, 4, 0.75f, 1.5f, 4, -0.5f, 1, -99, -99, -99 };
    Track track = { .path = TargetPath.TRANSLATION, .interpolation = Interpolation.CUBIC_SPLINE,
        .times = times[..], .values = values[..] };
    uint cursor;
    double[3] actual;
    anim::sample_track_analytic(
        track: &track,
        time: 0,
        cursor: &cursor,
        value: actual[..],
    );
    assert(actual == (double[3]){ 1.75, -1.375, 0.125 });
}

fn void test_animation_inertial_onset_target_velocity_follows_the_target_clock() @test {
    OnsetRateCase[3] cases = {
        { .start = 0.25f, .playing = true },
        { .start = 0, .playing = true },
        { .start = 0.25f, .playing = false },
    };
    foreach (sample : cases) {
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
        float[4] step_times = { 0, 0.499f, 0.501f, 1 };
        float[12] step_positions = { 0, 0, 0, 5, 0, 0, 10, 0, 0, 10, 0, 0 };
        ClipId stepped = inertial_owner_clip(
            owner: &fixture,
            path: TargetPath.TRANSLATION,
            interpolation: Interpolation.STEP,
            times: step_times[..],
            values: step_positions[..],
            node: 1,
        );
        ClipId held = inertial_owner_translation(&fixture, { 0, 4, 0 }, { 0, 4, 0 }, 2);
        AnimationActionId source = fixture.animator.play(&fixture.assets, clip)!!;
        fixture.animator.action(source).time = sample.start;
        fixture.animator.action(source).playing = false;
        anim::update(&fixture.assets, &fixture.scene, 0);

        AnimationTargetDesc[3] request = { anim::ANIMATION_TARGET_DEFAULT, anim::ANIMATION_TARGET_DEFAULT,
            anim::ANIMATION_TARGET_DEFAULT };
        request[0].clip = clip;
        request[0].start_time = sample.start;
        request[0].speed = -2;
        request[0].playing = sample.playing;
        request[1].clip = held;
        request[1].weight = 0.5f;
        request[1].play.fade_in = 0.25f;
        request[2].clip = stepped;
        request[2].start_time = 0.5f;
        fixture.animator.inertialize(&fixture.assets, { .duration = 0.5f, .actions = request[..] })!!;

        InertialRow* row = inertial_owner_row(&fixture);
        double[<3>] translation = sample.playing ? (double[<3>]){ 8, 16, -4 } : (double[<3>]){};
        double[<3>] angular = sample.playing ? (double[<3>]){ 0, 2, 0 } : (double[<3>]){};
        assert((row.offset_velocity[3].translation - translation).length() < ONSET_RATE_TEST_EPSILON);
        assert((row.offset_velocity[3].angular - angular).length() < ONSET_RATE_TEST_EPSILON);
        assert(row.offset_velocity[1].translation == (double[<3>]){});

        Vec3 base = fixture.scene.get(fixture.root, ModelInstance).base_pose[2].position;
        double[<3>] fading = ((double[<3>]){ 0, 4, 0 } - (double[<3>]){ base.x, base.y, base.z }) * -4;
        assert((row.offset_velocity[2].translation - fading).length() < ONSET_RATE_TEST_EPSILON);
    }
}

fn void test_animation_inertial_onset_lead_takes_each_clock_from_its_own_side() @test {
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
    ClipId looping = add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
    AnimationActionId source = fixture.animator.play(&fixture.assets, looping)!!;
    fixture.animator.action(source).time = 0.999f;
    fixture.animator.action(source).playing = false;
    anim::update(&fixture.assets, &fixture.scene, 0);

    AnimationTargetDesc[4] request = { anim::ANIMATION_TARGET_DEFAULT, anim::ANIMATION_TARGET_DEFAULT,
        anim::ANIMATION_TARGET_DEFAULT, anim::ANIMATION_TARGET_DEFAULT };
    request[0].clip = looping;
    request[0].start_time = 0.999f;
    request[1].clip = inertial_owner_translation(&fixture, {}, { 4, 0, 0 }, 1);
    request[1].loop = false;
    request[2].clip = inertial_owner_translation(&fixture, { 0, 4, 0 }, { 0, 4, 0 }, 2);
    request[2].weight = 0;
    request[2].play.fade_in = 0.25f;
    request[3].clip = inertial_owner_translation(&fixture, { 0, 4, 0 }, { 0, 4, 0 }, 0);
    request[3].start_time = 0.999f;
    request[3].play.fade_in = 0.25f;
    fixture.animator.inertialize(&fixture.assets, { .duration = 0.5f, .actions = request[..] })!!;

    InertialRow* row = inertial_owner_row(&fixture);
    Vec3 base = fixture.scene.get(fixture.root, ModelInstance).base_pose[2].position;
    double[<3>] fading = ((double[<3>]){ 0, 4, 0 } - (double[<3>]){ base.x, base.y, base.z }) * -4;
    assert((row.offset_velocity[3].translation - (double[<3>]){ -4, -8, 2 }).length() < ONSET_RATE_TEST_EPSILON);
    assert((row.offset_velocity[3].angular - (double[<3>]){ 0, -1, 0 }).length() < ONSET_RATE_TEST_EPSILON);
    assert((row.offset_velocity[1].translation - (double[<3>]){ -4, 0, 0 }).length() < ONSET_RATE_TEST_EPSILON);
    assert((row.offset_velocity[2].translation - fading).length() < ONSET_RATE_TEST_EPSILON);
    assert(row.offset_velocity[0].translation.length() < ONSET_RATE_TEST_EPSILON);
}
