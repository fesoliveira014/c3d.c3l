module c3d::test::pose_rate_fades;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import c3d::pool;
import std::math;

const double POSE_FADE_TEST_STEP @local = 1e-6;
const double POSE_FADE_TEST_RATE_EPSILON @local = 2e-5;
const double POSE_FADE_TEST_VALUE_EPSILON @local = 2e-6;

struct PoseFadeExpected @local {
    double[<3>] translation;
    double[<4>] rotation;
    double[<3>] scale;
    double[2] morph;
}

struct PoseFadeAllocator (Allocator) @local {
    Allocator backing;
    uint acquisitions;
    uint resizes;
    uint outstanding;
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

fn void*? PoseFadeAllocator.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    self.acquisitions++;
    void* pointer = self.backing.acquire(size, init_type, alignment)!;
    self.outstanding++;
    return pointer;
}

fn void*? PoseFadeAllocator.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    self.resizes++;
    return self.backing.resize(pointer, size, alignment);
}

fn void PoseFadeAllocator.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
    self.outstanding--;
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

fn double[<4>] pose_fade_oracle_product(double[<4>] left, double[<4>] right) @local {
    return {
        left.w*right.x + left.x*right.w + left.y*right.z - left.z*right.y,
        left.w*right.y - left.x*right.z + left.y*right.w + left.z*right.x,
        left.w*right.z + left.x*right.y - left.y*right.x + left.z*right.w,
        left.w*right.w - left.x*right.x - left.y*right.y - left.z*right.z,
    };
}

fn PoseFadeExpected pose_fade_oracle_sample(PoseFadeFixture* fixture, double time) @local {
    PoseFadeExpected sample;
    for (uint axis = 0; axis < 3; axis++) {
        sample.translation[axis] = (double)fixture.positions[axis]
          + ((double)fixture.positions[axis + 3] - fixture.positions[axis]) * (time / 2);
        sample.scale[axis] = (double)fixture.scales[axis]
          + ((double)fixture.scales[axis + 3] - fixture.scales[axis]) * (time / 2);
    }
    sample.rotation = { 0, 0, math::sin(math::PI * time / 8), math::cos(math::PI * time / 8) };
    for (uint index = 0; index < 2; index++) {
        sample.morph[index] = (double)fixture.morphs[index]
          + ((double)fixture.morphs[index + 2] - fixture.morphs[index]) * (time / 2);
    }
    return sample;
}

fn PoseFadeExpected pose_fade_oracle(PoseFadeFixture* fixture, double shift) @local {
    Transform base = fixture.base[0];
    PoseFadeExpected result = {
        .translation = { base.position.x, base.position.y, base.position.z },
        .rotation = { base.rotation.v.x, base.rotation.v.y, base.rotation.v.z, base.rotation.v.w },
        .scale = { base.scale.x, base.scale.y, base.scale.z },
        .morph = { fixture.base_weights[0], fixture.base_weights[1] },
    };
    result.rotation /= result.rotation.length();
    for (uint layer = 0; layer < anim::MAX_ANIMATION_LAYERS; layer++) {
        PoseFadeExpected sums;
        double total;
        foreach (index, id : fixture.order[:fixture.action_count]) {
            Action* action = fixture.actions.get(id);
            if (action.layer != layer || action.additive) continue;
            double speed = action.blend_space ? action.analytic_speed : action.playing ? action.speed : 0;
            double weight = (double)action.weight + fixture.expected_weight_rate[index] * shift;
            if (action.weighted_mask.len) weight *= action.weighted_mask[0];
            PoseFadeExpected sample = pose_fade_oracle_sample(fixture, (double)action.time + speed * shift);
            sums.translation += sample.translation * weight;
            sums.scale += sample.scale * weight;
            if (sample.rotation.dot(result.rotation) < 0) sample.rotation = -sample.rotation;
            sums.rotation += sample.rotation * weight;
            for (uint morph = 0; morph < 2; morph++) sums.morph[morph] += sample.morph[morph] * weight;
            total += weight;
        }
        double remainder = math::max(0.0, 1 - total);
        double denominator = math::max(1.0, total);
        result.translation = (sums.translation + result.translation * remainder) / denominator;
        result.scale = (sums.scale + result.scale * remainder) / denominator;
        result.rotation = sums.rotation + result.rotation * remainder;
        result.rotation /= result.rotation.length();
        for (uint morph = 0; morph < 2; morph++) {
            result.morph[morph] = (sums.morph[morph] + result.morph[morph] * remainder) / denominator;
        }
        foreach (index, id : fixture.order[:fixture.action_count]) {
            Action* action = fixture.actions.get(id);
            if (action.layer != layer || !action.additive) continue;
            double speed = action.blend_space ? action.analytic_speed : action.playing ? action.speed : 0;
            double weight = (double)action.weight + fixture.expected_weight_rate[index] * shift;
            if (action.weighted_mask.len) weight *= action.weighted_mask[0];
            PoseFadeExpected sample = pose_fade_oracle_sample(fixture, (double)action.time + speed * shift);
            for (uint axis = 0; axis < 3; axis++) {
                result.translation[axis] += weight * (sample.translation[axis] - fixture.reference[axis]);
                if (action.additive_scale == AdditiveScaleMode.MULTIPLICATIVE) {
                    result.scale[axis] *= 1 + weight * (sample.scale[axis] / fixture.reference[axis + 7] - 1);
                } else {
                    result.scale[axis] += weight * (sample.scale[axis] - fixture.reference[axis + 7]);
                }
            }
            double[<4>] delta = sample.rotation;
            if (delta.w < 0) delta = -delta;
            double[<4>] mixed = delta * weight;
            mixed.w += 1 - weight;
            mixed /= mixed.length();
            result.rotation = pose_fade_oracle_product(result.rotation, mixed);
            result.rotation /= result.rotation.length();
            for (uint morph = 0; morph < 2; morph++) {
                result.morph[morph] += weight * (sample.morph[morph] - fixture.reference[morph + 10]);
            }
        }
    }
    return result;
}

fn void pose_fade_compare_rate(double actual, double expected) @local {
    assert(math::is_finite(actual));
    assert(math::abs(actual - expected) <= POSE_FADE_TEST_RATE_EPSILON * (1 + math::abs(expected)),
        "actual=%f expected=%f", actual, expected);
}

fn void pose_fade_check_oracle(PoseFadeFixture* fixture) @local {
    anim::blend_pose(
        playback: &fixture.playback,
        assets: &fixture.assets,
        destination: fixture.pose.destination,
        scratch: fixture.pose.scratch,
        onset: true,
    );
    PoseFadeExpected first = pose_fade_oracle(fixture, 0);
    PoseFadeExpected next = pose_fade_oracle(fixture, POSE_FADE_TEST_STEP);
    PoseVelocity actual = fixture.pose.scratch.derivative.velocity[0];
    for (uint axis = 0; axis < 3; axis++) {
        pose_fade_compare_rate(actual.translation[axis],
            (next.translation[axis] - first.translation[axis]) / POSE_FADE_TEST_STEP);
        pose_fade_compare_rate(actual.scale[axis], (next.scale[axis] - first.scale[axis]) / POSE_FADE_TEST_STEP);
    }
    double[<4>] difference = (next.rotation - first.rotation) / POSE_FADE_TEST_STEP;
    double[<4>] conjugate = { -first.rotation.x, -first.rotation.y, -first.rotation.z, first.rotation.w };
    double[<4>] angular = pose_fade_oracle_product(difference, conjugate);
    for (uint axis = 0; axis < 3; axis++) pose_fade_compare_rate(actual.angular[axis], 2 * angular[axis]);
    for (uint morph = 0; morph < 2; morph++) {
        pose_fade_compare_rate(fixture.pose.scratch.derivative.morph_rates[morph],
            (next.morph[morph] - first.morph[morph]) / POSE_FADE_TEST_STEP);
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
    pose_fade_check_oracle(&fixture);
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
    float[2][5] weights = { { 0.2f, 0.25f }, { 0.75f, 0.9f }, { 0.25f, 0.75f },
        { 0.25f, 0.75f }, { 0.4f, 0.3f } };
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
        first.fade_rate = index == 3 ? 0.2f : 0.7f;
        first.fade_target = index == 3 ? 0 : 1;
        second.fade_rate = index == 3 ? 0.7f : 0.2f;
        second.fade_target = 0;
        fixture.expected_weight_rate = {
            index == 3 ? -(double)first.fade_rate : (double)first.fade_rate, -(double)second.fade_rate,
        };
        if (index == 4) {
            fixture.weighted_mask[0] = 0.5f;
            first.weighted_mask = fixture.weighted_mask[..];
        }
        pose_fade_check_oracle(&fixture);
    }
}

fn void test_animation_pose_rate_fades_additive_difference_product_rotation_and_morph() @test {
    foreach (AdditiveScaleMode mode : { AdditiveScaleMode.DIFFERENCE, AdditiveScaleMode.MULTIPLICATIVE }) {
        foreach (float weight : { 0.0f, 0.4f }) {
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
            pose_fade_check_oracle(&fixture);
        }
    }
}

fn void test_animation_pose_rate_fades_group_phase_member_rates_while_paused_and_no_update_allocations() @test {
    PoseFadeAllocator allocator = { .backing = mem };
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
            );
            anim::write_blend_space_member(
                action: second,
                phase: { .start = 0.4, .phase = 0.4, .clock_rate = 0 },
                duration: 2,
                normalized: 0.7f,
                weight: group_weight,
                weight_rate: 0.6,
            );
            fixture.expected_weight_rate = { 0.6 * (double)0.3f, 0.6 * (double)0.7f };
            for (uint repetition = 0; repetition < 16; repetition++) pose_fade_check_oracle(&fixture);
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
