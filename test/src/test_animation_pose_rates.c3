module c3d::test::anim;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import c3d::pool;
import c3d::scene;
import std::math;

const double ANALYTIC_TEST_VALUE_EPSILON @local = 1e-10;
const double ANALYTIC_TEST_RATE_EPSILON @local = 1e-9;
const double POSE_FADE_TEST_STEP @local = 1.0 / 64;
const double POSE_FADE_TEST_RATE_EPSILON @local = 5e-4;
const double POSE_FADE_TEST_VALUE_EPSILON @local = 2e-6;

struct PoseFadeSample @local {
    double[<3>] translation;
    Quaternion rotation;
    double[<3>] scale;
    double[2] morph;
}

struct PoseFadeFixture @local {
    Transform[1] base;
    float[2] base_weights;
    float[][1] morph_rows;
    uint[1] mesh_nodes;
    float[2] times;
    float[6] positions;
    float[8] rotations;
    float[6] scales;
    float[4] morphs;
    Track[4] tracks;
    uint[4] targets;
    uint[4] first_cursors;
    uint[4] second_cursors;
    bool[1] mask;
    float[1] weighted_mask;
    float[12] reference;
    AssetStore assets;
    Pool{Action, AnimationActionId} actions;
    AnimationActionId[2] order;
    uint action_count;
    PlaybackView playback;
    PoseStorage* pose;
    double[2] expected_weight_rate;
}

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
    foreach (index, double angle : { 0.2, math::PI }) {
        Quaternion endpoint = quaternion::from_axis_angle{double}(axis, angle);
        float negation = index == 0 ? 1 : -1;
        float[8] values = { 0, 0, 0, 1, 0, 0, 0, 0 };
        for (uint component = 0; component < 4; component++) {
            values[4 + component] = (float)endpoint.v[component] * negation;
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
    foreach (float magnitude : { 0x1p-140f, 1.0f }) {
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

fn void test_animation_analytic_composition_layers_masks_speed_and_paused_rates() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId clip = inertial_owner_translation(&fixture, {}, { 4, 8, -2 });
    AnimationActionId regular = fixture.animator.play(&fixture.assets, clip)!!;
    Action* first = fixture.animator.action(regular);
    first.time = 0.25f;
    first.weight = 0.5f;
    first.speed = 2;
    AnimationActionId additive = fixture.animator.play(&fixture.assets, clip, { .layer = 1, .additive = true })!!;
    Action* second = fixture.animator.action(additive);
    second.time = 0.5f;
    second.weight = 0.25f;
    second.speed = -1;
    PlaybackView playback = fixture.animator.playback();
    PoseStorage* storage = fixture.animator.pose_storage;
    anim::blend_pose(
        playback: &playback,
        assets: &fixture.assets,
        destination: storage.destination,
        scratch: storage.scratch,
    );
    double[<3>] expected = { 3, 6, -1.5 };
    assert((storage.scratch.derivative.velocity[3].translation - expected).length() < 1e-12);
    first.playing = second.playing = false;
    anim::blend_pose(
        playback: &playback,
        assets: &fixture.assets,
        destination: storage.destination,
        scratch: storage.scratch,
    );
    assert(storage.scratch.derivative.velocity[3].translation == (double[<3>]){});
}

fn void test_animation_analytic_composition_rotation_rate_matches_independent_axis_angle() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    float[2] times = { 0, 1 };
    float[8] values = { 0, 0, 0, 1, 0, 1, 0, 0 };
    ClipId clip = inertial_owner_clip(
        owner: &fixture,
        path: TargetPath.ROTATION,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: values[..],
        node: 3,
    );
    AnimationActionId id = fixture.animator.play(&fixture.assets, clip)!!;
    Action* action = fixture.animator.action(id);
    action.time = 0.25f;
    action.speed = -2;
    PlaybackView playback = fixture.animator.playback();
    PoseStorage* storage = fixture.animator.pose_storage;
    anim::blend_pose(
        playback: &playback,
        assets: &fixture.assets,
        destination: storage.destination,
        scratch: storage.scratch,
    );
    double[<3>] expected = { 0, -2 * math::PI, 0 };
    assert((storage.scratch.derivative.velocity[3].angular - expected).length() < 1e-7);
}

fn void create_pose_fade_fixture(PoseFadeFixture* fixture, Allocator allocator = mem) @local {
    fixture.base[0] = {
        .position = { -1, 0.5f, 2 },
        .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.3f),
        .scale = { 0.8f, 1.3f, -0.5f },
    };
    fixture.base_weights = { 0.2f, 0.4f };
    fixture.morph_rows = { fixture.base_weights[..] };
    fixture.times = { 0, 2 };
    fixture.positions = { 1, -2, 0.5f, 5, 2, -1.5f };
    fixture.rotations = { 0, 0, 0, 1, 0, 0, 0.70710677f, 0.70710677f };
    fixture.scales = { 1, 2, 0.5f, 3, 4, 1.5f };
    fixture.morphs = { 0.1f, 0.3f, 0.9f, 0.7f };
    fixture.tracks = {
        { .target = 0, .path = TargetPath.TRANSLATION, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.positions[..] },
        { .target = 1, .path = TargetPath.ROTATION, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.rotations[..] },
        { .target = 2, .path = TargetPath.SCALE, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.scales[..] },
        { .target = 3, .path = TargetPath.MORPH_WEIGHTS, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.morphs[..] },
    };
    fixture.reference = { 1, -2, 0.5f, 0, 0, 0, 1, 1, 2, 0.5f, 0.1f, 0.3f };
    fixture.mask[0] = true;
    fixture.weighted_mask[0] = 1;
    fixture.assets.clips = pool::create_pool{ClipAsset, ClipId}(mem, 1);
    ClipId clip = fixture.assets.clips.add({
        .data = { .duration = 2, .tracks = fixture.tracks[..], .targets = fixture.targets[..] },
    })!!;
    fixture.actions = pool::create_pool{Action, AnimationActionId}(mem, 2);
    Action action = {
        .clip = clip,
        .cursors = fixture.first_cursors[..],
        .mask = fixture.mask[..],
        .time = 0.8f,
        .speed = 1,
        .weight = 1,
        .fade_target = 1,
        .playing = true,
        .translation_track = anim::NO_MOTION_TRACK,
        .rotation_track = anim::NO_MOTION_TRACK,
    };
    fixture.order[0] = fixture.actions.add(action)!!;
    action.cursors = fixture.second_cursors[..];
    action.time = 1.2f;
    fixture.order[1] = fixture.actions.add(action)!!;
    fixture.action_count = 2;
    fixture.playback = {
        .allocator = allocator,
        .actions = &fixture.actions,
        .order = fixture.order[..],
        .action_count = &fixture.action_count,
        .root_node = 0,
    };
    fixture.pose = anim::create_pose_storage(
        allocator: allocator,
        base_pose: fixture.base[..],
        mesh_nodes: fixture.mesh_nodes[..],
        base_morph_weights: fixture.morph_rows[..],
        event_capacity: 0,
        inertia_enabled: true,
    );
}

fn void destroy_pose_fade_fixture(PoseFadeFixture* fixture, Allocator allocator = mem) @local {
    anim::destroy_pose_storage(allocator, fixture.pose);
    pool::destroy_pool{Action, AnimationActionId}(&fixture.actions);
    pool::destroy_pool{ClipAsset, ClipId}(&fixture.assets.clips);
}

fn PoseFadeSample pose_fade_sample(PoseFadeFixture* fixture, double shift) @local {
    float[2] times;
    float[2] weights;
    foreach (index, id : fixture.order[:fixture.action_count]) {
        Action* action = fixture.actions.get(id);
        times[index] = action.time;
        weights[index] = action.weight;
        double speed = action.blend_space ? action.analytic_speed : action.playing ? action.speed : 0;
        action.time = (float)((double)action.time + speed * shift);
        action.weight = (float)((double)action.weight + fixture.expected_weight_rate[index] * shift);
    }
    anim::blend_pose(
        playback: &fixture.playback,
        assets: &fixture.assets,
        destination: fixture.pose.destination,
        scratch: fixture.pose.scratch,
        onset: true,
    );
    foreach (index, id : fixture.order[:fixture.action_count]) {
        Action* action = fixture.actions.get(id);
        action.time = times[index];
        action.weight = weights[index];
    }

    Transform pose = fixture.pose.destination.pose[0];
    float[] morph = fixture.pose.destination.morph_weights[0];
    return {
        .translation = { pose.position.x, pose.position.y, pose.position.z },
        .rotation = { .v = { pose.rotation.v.x, pose.rotation.v.y, pose.rotation.v.z, pose.rotation.v.w } },
        .scale = { pose.scale.x, pose.scale.y, pose.scale.z },
        .morph = { morph[0], morph[1] },
    };
}

fn void pose_fade_compare_rate(double actual, double expected) @local {
    assert(math::is_finite(actual));
    assert(math::abs(actual - expected) <= POSE_FADE_TEST_RATE_EPSILON * (1 + math::abs(expected)));
}

// One-sided differences keep every sample on the side of a fade the analytic rate describes.
fn void pose_fade_check_rates(PoseFadeFixture* fixture) @local {
    PoseFadeSample first = pose_fade_sample(fixture, 0);
    PoseFadeSample second = pose_fade_sample(fixture, POSE_FADE_TEST_STEP);
    PoseFadeSample third = pose_fade_sample(fixture, 2 * POSE_FADE_TEST_STEP);
    double scale = 1 / (2 * POSE_FADE_TEST_STEP);
    anim::blend_pose(
        playback: &fixture.playback,
        assets: &fixture.assets,
        destination: fixture.pose.destination,
        scratch: fixture.pose.scratch,
        onset: true,
    );

    PoseVelocity actual = fixture.pose.scratch.derivative.velocity[0];
    double[<3>] translation = (4 * second.translation - 3 * first.translation - third.translation) * scale;
    double[<3>] stretch = (4 * second.scale - 3 * first.scale - third.scale) * scale;
    Quaternion turn = { .v = (4 * second.rotation.v - 3 * first.rotation.v - third.rotation.v) * scale };
    double[<4>] spin = turn.mul(first.rotation.conjugate()).v;
    for (uint axis = 0; axis < 3; axis++) {
        pose_fade_compare_rate(actual.translation[axis], translation[axis]);
        pose_fade_compare_rate(actual.scale[axis], stretch[axis]);
        pose_fade_compare_rate(actual.angular[axis], 2 * spin[axis]);
    }
    for (uint morph = 0; morph < 2; morph++) {
        pose_fade_compare_rate(
            actual: fixture.pose.scratch.derivative.morph_rates[morph],
            expected: (4 * second.morph[morph] - 3 * first.morph[morph] - third.morph[morph]) * scale,
        );
    }
}

fn void test_animation_pose_rate_fades_zero_onset_has_literal_weight_derivatives() @test {
    PoseFadeFixture fixture;
    create_pose_fade_fixture(&fixture);
    defer destroy_pose_fade_fixture(&fixture);
    fixture.action_count = 1;
    Action* action = fixture.actions.get(fixture.order[0]);
    action.weight = 0;
    action.fade_target = 1;
    action.fade_rate = 0.8f;
    action.speed = 0;
    fixture.expected_weight_rate[0] = action.fade_rate;
    pose_fade_check_rates(&fixture);
    PoseVelocity rate = fixture.pose.scratch.derivative.velocity[0];
    pose_fade_compare_rate(rate.translation.x, 2.88);
    pose_fade_compare_rate(rate.translation.y, -0.72);
    pose_fade_compare_rate(rate.translation.z, -1.84);
    pose_fade_compare_rate(rate.scale.x, 0.8);
    pose_fade_compare_rate(rate.scale.y, 1.2);
    pose_fade_compare_rate(rate.scale.z, 1.12);
    assert(fixture.pose.destination.pose[0].position == fixture.base[0].position);
    assert(fixture.pose.destination.pose[0].scale == fixture.base[0].scale);
}

fn void test_animation_pose_rate_fades_regular_residual_denominator_and_weighted_mask() @test {
    float[2][2] weights = { { 0.75f, 0.9f }, { 0.4f, 0.3f } };
    foreach (index, pair : weights) {
        PoseFadeFixture fixture;
        create_pose_fade_fixture(&fixture);
        defer destroy_pose_fade_fixture(&fixture);
        Action* first = fixture.actions.get(fixture.order[0]);
        Action* second = fixture.actions.get(fixture.order[1]);
        first.weight = pair[0];
        second.weight = pair[1];
        first.speed = 0.5f;
        second.speed = -0.75f;
        first.fade_rate = 0.7f;
        first.fade_target = 1;
        second.fade_rate = 0.2f;
        second.fade_target = 0;
        fixture.expected_weight_rate = { first.fade_rate, -(double)second.fade_rate };
        if (index == 1) {
            fixture.weighted_mask[0] = 0.5f;
            first.weighted_mask = fixture.weighted_mask[..];
        }
        pose_fade_check_rates(&fixture);
    }
}

fn void test_animation_pose_rate_fades_additive_difference_product_rotation_and_morph() @test {
    foreach (AdditiveScaleMode mode : { AdditiveScaleMode.DIFFERENCE, AdditiveScaleMode.MULTIPLICATIVE }) {
        float weight = mode == AdditiveScaleMode.DIFFERENCE ? 0.4f : 0;
        PoseFadeFixture fixture;
        create_pose_fade_fixture(&fixture);
        defer destroy_pose_fade_fixture(&fixture);
        Action* first = fixture.actions.get(fixture.order[0]);
        Action* second = fixture.actions.get(fixture.order[1]);
        first.weight = 0.6f;
        first.fade_rate = 0.3f;
        first.fade_target = 1;
        first.speed = 0.5f;
        second.layer = 1;
        second.additive = true;
        second.additive_scale = mode;
        second.reference = fixture.reference[..];
        second.weight = weight;
        second.fade_rate = 0.2f;
        second.fade_target = weight == 0 ? 1 : 0;
        second.speed = -0.5f;
        fixture.expected_weight_rate = { first.fade_rate, weight == 0 ? 0.2 : -0.2 };
        pose_fade_check_rates(&fixture);
    }
}

fn void test_animation_pose_rate_fades_group_phase_member_rates_while_paused_and_no_update_allocations() @test {
    MotionTestAllocator allocator = { .backing = mem };
    {
        PoseFadeFixture fixture;
        create_pose_fade_fixture(&fixture, &allocator);
        defer destroy_pose_fade_fixture(&fixture, &allocator);
        Action* first = fixture.actions.get(fixture.order[0]);
        Action* second = fixture.actions.get(fixture.order[1]);
        first.blend_space = 1;
        second.blend_space = 1;
        uint acquisitions = allocator.acquisitions;
        uint resizes = allocator.resizes;
        foreach (float group_weight : { 0.0f, 0.5f }) {
            anim::write_blend_space_member(
                action: first,
                phase: { .start = 0.4, .phase = 0.4, .clock_rate = 0 },
                duration: 2,
                normalized: 0.3f,
                weight: group_weight,
                weight_rate: 0.6,
                derivatives_enabled: true,
            );
            anim::write_blend_space_member(
                action: second,
                phase: { .start = 0.4, .phase = 0.4, .clock_rate = 0 },
                duration: 2,
                normalized: 0.7f,
                weight: group_weight,
                weight_rate: 0.6,
                derivatives_enabled: true,
            );
            fixture.expected_weight_rate = { 0.6 * (double)0.3f, 0.6 * (double)0.7f };
            for (uint repetition = 0; repetition < 2; repetition++) pose_fade_check_rates(&fixture);
            assert(allocator.acquisitions == acquisitions && allocator.resizes == resizes);
            assert(first.analytic_speed == 0 && second.analytic_speed == 0);
            if (group_weight == 0) {
                pose_fade_compare_rate(fixture.pose.scratch.derivative.velocity[0].translation.x, 2.16);
                pose_fade_compare_rate(fixture.pose.scratch.derivative.morph_rates[0], 0.132);
            }
        }
    }
    assert(allocator.outstanding == 0);
}

fn void test_animation_pose_rate_fades_consumed_keep_rotation_is_safe_without_pose_derivatives() @test {
    foreach (float magnitude : { 1e-30f, 1e30f }) {
        PoseFadeFixture fixture;
        create_pose_fade_fixture(&fixture);
        defer destroy_pose_fade_fixture(&fixture);
        fixture.base[0].scale = { 1, 1, 1 };
        fixture.scales = { 1, 1, 1, 2, 2, 2 };
        fixture.rotations = {
            magnitude, 2 * magnitude, 3 * magnitude, 4 * magnitude,
            magnitude, 2 * magnitude, 3 * magnitude, 4 * magnitude,
        };
        NodeTemplate[1] nodes = {
            { .parent = -1, .name = "motion", .local = fixture.base[0] },
        };
        ModelTemplate model = { .nodes = nodes[..] };
        AnimationClip* clip = &fixture.assets.clip(fixture.actions.get(fixture.order[0]).clip).data;
        CapturedMotionChain chain = anim::create_captured_motion_chain(
            allocator: mem,
            template: &model,
            clip: clip,
            root: 0,
            extraction: { .generalized = true, .translation_axes = { true, true, true }, .up = { 0, 0, 1 } },
        )!!;
        defer anim::destroy_captured_motion_chain(&chain);
        chain.pose_scale_sums = alloc::new_array(mem, double[<3>], nodes.len);
        Action* extracted = fixture.actions.get(fixture.order[0]);
        extracted.weight = 0;
        extracted.motion_chain = &chain;
        extracted.extraction = chain.extraction;
        extracted.root_motion = RootMotion.EXTRACT;
        Action* kept = fixture.actions.get(fixture.order[1]);
        kept.root_motion = RootMotion.KEEP;
        assert(kept.motion_chain == null && fixture.playback.inertial == null);
        PoseDerivativeScratch* derivative = fixture.pose.scratch.derivative;
        defer fixture.pose.scratch.derivative = derivative;
        fixture.pose.scratch.derivative = null;
        anim::blend_pose(
            playback: &fixture.playback,
            assets: &fixture.assets,
            destination: fixture.pose.destination,
            scratch: fixture.pose.scratch,
            consumed_chain: &chain,
        );
        double[<4>] expected = {
            fixture.rotations[0], fixture.rotations[1], fixture.rotations[2], fixture.rotations[3],
        };
        expected /= expected.length();
        Quat actual = fixture.pose.destination.pose[0].rotation;
        for (uint component = 0; component < 4; component++) {
            assert(math::is_finite(actual.v[component]));
            assert(math::abs((double)actual.v[component] - expected[component]) < POSE_FADE_TEST_VALUE_EPSILON);
        }
        for (uint axis = 0; axis < 3; axis++) {
            assert(math::abs(fixture.pose.destination.pose[0].scale[axis] - 1.6f) < POSE_FADE_TEST_VALUE_EPSILON);
        }
    }
}
