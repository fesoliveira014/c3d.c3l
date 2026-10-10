module c3d::test::cycle_rate;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import c3d::pool;
import std::math;

const double CYCLE_RATE_TEST_STEP @local = 1e-5;
const double CYCLE_RATE_TEST_EPSILON @local = 2e-7;
const double CYCLE_RATE_TEST_MIN_NONZERO_RATE @local = 0.01;

struct CycleRateMatrix @local {
    double[4][4] cells;
}

struct CycleRateAllocationProbe (Allocator) @local {
    Allocator backing;
    uint acquisitions;
    uint resizes;
    uint outstanding;
}

struct CycleRateFixture @local {
    NodeTemplate[3] nodes;
    Transform[3] base;
    bool[3] mask;
    float[3][2] weighted_masks;
    float[2] times;
    float[6][2] positions;
    float[8][2] rotations;
    Track[2][2] tracks;
    uint[2] targets;
    uint[2][2] cursors;
    AssetStore assets;
    Pool{Action, AnimationActionId} actions;
    CapturedMotionChain[2] chains;
    AnimationActionId[2] order;
    uint action_count;
    PlaybackView playback;
    PoseStorage* pose;
    GeneralizedPlaybackState state;
    double[2] expected_weight_rate;
    CycleRateMatrix consumed;
    CycleRateMatrix reference_anchor;
}

fn void*? CycleRateAllocationProbe.acquire(
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

fn void*? CycleRateAllocationProbe.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    self.resizes++;
    return self.backing.resize(pointer, size, alignment);
}

fn void CycleRateAllocationProbe.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
    self.outstanding--;
}

fn CycleRateMatrix cycle_rate_identity() @local {
    CycleRateMatrix result;
    for (uint axis = 0; axis < 4; axis++) result.cells[axis][axis] = 1;
    return result;
}

fn CycleRateMatrix cycle_rate_product(CycleRateMatrix left, CycleRateMatrix right) @local {
    CycleRateMatrix result;
    for (uint row = 0; row < 4; row++) for (uint column = 0; column < 4; column++) {
        for (uint axis = 0; axis < 4; axis++) {
            result.cells[row][column] += left.cells[row][axis] * right.cells[axis][column];
        }
    }
    return result;
}

fn CycleRateMatrix cycle_rate_inverse_rigid(CycleRateMatrix matrix) @local {
    CycleRateMatrix result = cycle_rate_identity();
    for (uint row = 0; row < 3; row++) for (uint column = 0; column < 3; column++) {
        result.cells[row][column] = matrix.cells[column][row];
        result.cells[row][3] -= matrix.cells[column][row] * matrix.cells[column][3];
    }
    return result;
}

fn CycleRateMatrix cycle_rate_rodrigues(double[<3>] up, double angle) @local {
    CycleRateMatrix result = cycle_rate_identity();
    double[3][3] skew = {
        { 0, -up.z, up.y },
        { up.z, 0, -up.x },
        { -up.y, up.x, 0 },
    };
    double cosine = math::cos(angle);
    double sine = math::sin(angle);
    for (uint row = 0; row < 3; row++) for (uint column = 0; column < 3; column++) {
        result.cells[row][column] = (row == column ? cosine : 0)
          + (1 - cosine) * up[row] * up[column] + sine * skew[row][column];
    }
    return result;
}

fn double[<3>] cycle_rate_point(CycleRateMatrix matrix, double[<3>] point) @local {
    double[<3>] result;
    for (uint row = 0; row < 3; row++) {
        result[row] = matrix.cells[row][3];
        for (uint column = 0; column < 3; column++) result[row] += matrix.cells[row][column] * point[column];
    }
    return result;
}

fn CycleRateMatrix cycle_rate_local(Transform transform) @local {
    double[<4>] rotation = {
        transform.rotation.v.x, transform.rotation.v.y, transform.rotation.v.z, transform.rotation.v.w,
    };
    rotation /= rotation.length();
    double x = rotation.x;
    double y = rotation.y;
    double z = rotation.z;
    double w = rotation.w;
    CycleRateMatrix result = { .cells = {
        { 1-2*y*y-2*z*z, 2*x*y-2*z*w, 2*x*z+2*y*w, transform.position.x },
        { 2*x*y+2*z*w, 1-2*x*x-2*z*z, 2*y*z-2*x*w, transform.position.y },
        { 2*x*z-2*y*w, 2*y*z+2*x*w, 1-2*x*x-2*y*y, transform.position.z },
        { 0, 0, 0, 1 },
    } };
    for (uint row = 0; row < 3; row++) for (uint column = 0; column < 3; column++) {
        result.cells[row][column] *= transform.scale[column];
    }
    return result;
}

fn GeneralizedMotion cycle_rate_literal_cycle(CycleRateFixture* fixture, uint clip) @local {
    double angle = 2 * math::atan2((double)fixture.rotations[clip][5], (double)fixture.rotations[clip][7]);
    CycleRateMatrix rotation = cycle_rate_rodrigues({ 0, 1, 0 }, angle);
    double[<3>] pivot = {
        fixture.positions[clip][0], fixture.positions[clip][1], fixture.positions[clip][2],
    };
    double[<3>] displacement = {
        (double)fixture.positions[clip][3] - pivot.x,
        (double)fixture.positions[clip][4] - pivot.y,
        (double)fixture.positions[clip][5] - pivot.z,
    };
    return { .translation = displacement + pivot - cycle_rate_point(rotation, pivot), .twist = angle };
}

fn CycleRateMatrix cycle_rate_motion_matrix(GeneralizedMotion motion) @local {
    CycleRateMatrix result = cycle_rate_rodrigues({ 0, 1, 0 }, motion.twist);
    for (uint axis = 0; axis < 3; axis++) result.cells[axis][3] = motion.translation[axis];
    return result;
}

fn void create_cycle_rate_fixture(CycleRateFixture* fixture, Allocator allocator) @local {
    fixture.nodes = {
        { .parent = -1, .name = "motion", .local = {
            .position = { 2, 0.25f, -0.5f }, .rotation = quaternion::IDENTITY, .scale = { 1, 1, 1 },
        } },
        { .parent = -1, .name = "sibling", .local = {
            .position = { -1, 0.5f, 1.2f },
            .rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.2f),
            .scale = { -1, 2, 1 },
        } },
        { .parent = 0, .name = "child", .local = maths::TRANSFORM_IDENTITY },
    };
    foreach (index, node : fixture.nodes) fixture.base[index] = node.local;
    fixture.times = { 0, 1 };
    fixture.positions = {
        { 2, 0.25f, -0.5f, 2.8f, 0.45f, -0.2f },
        { 2, 0.25f, -0.5f, 1.6f, 0.35f, 0.2f },
    };
    foreach (uint index : { 0, 1 }) {
        Quat end = quaternion::from_axis_angle{float}({ 0, 1, 0 }, index == 0 ? 0.5f : -0.3f);
        fixture.rotations[index] = { 0, 0, 0, 1, end.v.x, end.v.y, end.v.z, end.v.w };
        fixture.tracks[index] = {
            { .target = 0, .path = TargetPath.TRANSLATION, .interpolation = Interpolation.LINEAR,
                .times = fixture.times[..], .values = fixture.positions[index][..] },
            { .target = 1, .path = TargetPath.ROTATION, .interpolation = Interpolation.LINEAR,
                .times = fixture.times[..], .values = fixture.rotations[index][..] },
        };
    }
    fixture.mask[..] = true;
    fixture.weighted_masks[0][..] = 1;
    fixture.weighted_masks[1][..] = 1;
    fixture.assets.clips = pool::create_pool{ClipAsset, ClipId}(allocator, 2);
    fixture.actions = pool::create_pool{Action, AnimationActionId}(allocator, 2);
    ModelTemplate template = { .nodes = fixture.nodes[..] };
    foreach (uint index : { 0, 1 }) {
        AnimationClip clip = {
            .duration = 1, .tracks = fixture.tracks[index][..], .targets = fixture.targets[..],
        };
        ClipId clip_id = fixture.assets.clips.add({ .data = clip })!!;
        fixture.chains[index] = anim::create_captured_motion_chain(
            allocator: allocator,
            template: &template,
            clip: &clip,
            root: 0,
            extraction: {
                .generalized = true, .translation_axes = { true, true, true }, .up = { 0, 1, 0 }, .twist = true,
            },
        )!!;
        fixture.order[index] = fixture.actions.add({
            .clip = clip_id,
            .cursors = fixture.cursors[index][..],
            .mask = fixture.mask[..],
            .speed = 1,
            .weight = 1,
            .fade_target = 1,
            .playing = true,
            .loop = true,
            .root_motion = RootMotion.EXTRACT,
            .extraction = fixture.chains[index].extraction,
            .motion_chain = &fixture.chains[index],
            .motion_reference = anim::capture_generalized_motion_reference(&fixture.chains[index], &clip),
            .translation_track = anim::NO_MOTION_TRACK,
            .rotation_track = anim::NO_MOTION_TRACK,
        })!!;
    }
    fixture.action_count = 2;
    fixture.playback = {
        .allocator = allocator,
        .actions = &fixture.actions,
        .order = fixture.order[..],
        .action_count = &fixture.action_count,
        .root_node = 0,
        .generalized = &fixture.state,
    };
    fixture.pose = anim::create_pose_storage(
        allocator: allocator,
        base_pose: fixture.base[..],
        mesh_nodes: {},
        base_morph_weights: {},
        event_capacity: 0,
        inertia_enabled: true,
    );
    anim::initialize_generalized_playback(&fixture.state, &fixture.playback);
    foreach (id : fixture.order) anim::advance_clock(fixture.actions.get(id), 1, 1);
    anim::blend_pose(
        playback: &fixture.playback,
        assets: &fixture.assets,
        destination: fixture.pose.destination,
        scratch: fixture.pose.scratch,
    );
    GeneralizedMotion prime = anim::evaluate_generalized_playback_motion(
        playback: &fixture.playback,
        assets: &fixture.assets,
        destination: fixture.pose.destination,
        state: &fixture.state,
        dt: 1,
    );
    anim::finish_generalized_playback(
        state: &fixture.state,
        playback: &fixture.playback,
        destination: fixture.pose.destination,
        final_motion: prime,
        dt: 1,
        velocity: fixture.pose.scratch.derivative.velocity,
    );
    GeneralizedMotion first = cycle_rate_literal_cycle(fixture, 0);
    GeneralizedMotion second = cycle_rate_literal_cycle(fixture, 1);
    fixture.consumed = cycle_rate_motion_matrix(
        motion: {
            .translation = (first.translation + second.translation) / 2,
            .twist = (first.twist + second.twist) / 2,
        },
    );
    fixture.state.anchor = {
        .position = { 0.2, -0.3, 0.1 },
        .rotation = quaternion::from_axis_angle{double}({ 1, 0, 0 }, 0.3),
        .scale = 1,
    };
    fixture.reference_anchor = cycle_rate_rodrigues({ 1, 0, 0 }, 0.3);
    fixture.reference_anchor.cells[0][3] = 0.2;
    fixture.reference_anchor.cells[1][3] = -0.3;
    fixture.reference_anchor.cells[2][3] = 0.1;
    foreach (id : fixture.order) {
        Action* action = fixture.actions.get(id);
        action.playing = false;
        action.clock_delta = 0;
    }
}

fn void destroy_cycle_rate_fixture(CycleRateFixture* fixture, Allocator allocator) @local {
    anim::destroy_pose_storage(allocator, fixture.pose);
    foreach (&chain : fixture.chains) anim::destroy_captured_motion_chain(chain);
    pool::destroy_pool{Action, AnimationActionId}(&fixture.actions);
    pool::destroy_pool{ClipAsset, ClipId}(&fixture.assets.clips);
}

fn CycleRateMatrix cycle_rate_oracle(CycleRateFixture* fixture, double shift, uint node) @local {
    GeneralizedMotion folded;
    for (uint layer = 0; layer < anim::MAX_ANIMATION_LAYERS; layer++) {
        GeneralizedMotion sum;
        double total;
        foreach (index, id : fixture.order) {
            Action* action = fixture.actions.get(id);
            if (action.layer != layer) continue;
            double weight = (double)action.weight + fixture.expected_weight_rate[index] * shift;
            if (action.weighted_mask.len) weight *= action.weighted_mask[0];
            GeneralizedMotion cycle = cycle_rate_literal_cycle(fixture, (uint)index);
            sum.translation += cycle.translation * weight;
            sum.twist += cycle.twist * weight;
            total += weight;
        }
        double remainder = math::max(0.0, 1 - total);
        double denominator = math::max(1.0, total);
        folded.translation = (sum.translation + folded.translation * remainder) / denominator;
        folded.twist = (sum.twist + folded.twist * remainder) / denominator;
    }
    CycleRateMatrix correction = cycle_rate_product(
        left: cycle_rate_inverse_rigid(fixture.consumed),
        right: cycle_rate_product(fixture.reference_anchor, cycle_rate_motion_matrix(folded)),
    );
    return cycle_rate_product(correction, cycle_rate_local(fixture.base[node]));
}

fn void cycle_rate_near(double actual, double expected) @local {
    assert(math::is_finite(actual));
    assert(math::abs(actual - expected) <= CYCLE_RATE_TEST_EPSILON * (1 + math::abs(expected)),
        "actual=%f expected=%f", actual, expected);
}

fn void cycle_rate_check(CycleRateFixture* fixture, bool forward_boundary = false) @local {
    anim::blend_pose(
        playback: &fixture.playback,
        assets: &fixture.assets,
        destination: fixture.pose.destination,
        scratch: fixture.pose.scratch,
    );
    GeneralizedMotion delta = anim::evaluate_generalized_playback_motion(
        playback: &fixture.playback,
        assets: &fixture.assets,
        destination: fixture.pose.destination,
        state: &fixture.state,
        dt: 0.125,
    );
    assert(delta.translation == (double[<3>]){} && delta.twist == 0);
    anim::finish_generalized_playback(
        state: &fixture.state,
        playback: &fixture.playback,
        destination: fixture.pose.destination,
        final_motion: delta,
        dt: 0.125,
        velocity: fixture.pose.scratch.derivative.velocity,
    );
    for (uint node = 0; node < 2; node++) {
        CycleRateMatrix center = cycle_rate_oracle(fixture, 0, node);
        CycleRateMatrix next = cycle_rate_oracle(fixture, CYCLE_RATE_TEST_STEP, node);
        CycleRateMatrix other = cycle_rate_oracle(
            fixture, forward_boundary ? 2 * CYCLE_RATE_TEST_STEP : -CYCLE_RATE_TEST_STEP, node);
        CycleRateMatrix derivative;
        for (uint row = 0; row < 3; row++) for (uint column = 0; column < 4; column++) {
            derivative.cells[row][column] = forward_boundary
              ? (-3 * center.cells[row][column] + 4 * next.cells[row][column] - other.cells[row][column])
              / (2 * CYCLE_RATE_TEST_STEP)
              : (next.cells[row][column] - other.cells[row][column]) / (2 * CYCLE_RATE_TEST_STEP);
        }
        PoseVelocity actual = fixture.pose.scratch.derivative.velocity[node];
        for (uint axis = 0; axis < 3; axis++) {
            cycle_rate_near(actual.translation[axis], derivative.cells[axis][3]);
            cycle_rate_near(actual.scale[axis], 0);
        }
        double[3][3] angular;
        for (uint row = 0; row < 3; row++) for (uint column = 0; column < 3; column++) {
            for (uint axis = 0; axis < 3; axis++) {
                double scale = fixture.base[node].scale[axis];
                angular[row][column] += derivative.cells[row][axis] * center.cells[column][axis] / (scale * scale);
            }
        }
        cycle_rate_near(actual.angular.x, (angular[2][1] - angular[1][2]) / 2);
        cycle_rate_near(actual.angular.y, (angular[0][2] - angular[2][0]) / 2);
        cycle_rate_near(actual.angular.z, (angular[1][0] - angular[0][1]) / 2);
    }
    PoseVelocity descendant = fixture.pose.scratch.derivative.velocity[2];
    assert(descendant.translation == (double[<3>]){} && descendant.angular == (double[<3>]){});
    assert(fixture.pose.destination.pose[2].position == fixture.base[2].position);
}

fn void test_animation_cycle_rate_paused_full_cycles_follow_fades_below_above_and_at_normalization() @test {
    float[2][4] weights = { { 0.2f, 0.3f }, { 0.8f, 0.7f }, { 0.25f, 0.75f }, { 0.25f, 0.75f } };
    foreach (index, pair : weights) {
        CycleRateAllocationProbe allocator = { .backing = mem };
        {
            CycleRateFixture fixture;
            create_cycle_rate_fixture(&fixture, &allocator);
            defer destroy_cycle_rate_fixture(&fixture, &allocator);
            Action* first = fixture.actions.get(fixture.order[0]);
            Action* second = fixture.actions.get(fixture.order[1]);
            first.weight = pair[0];
            second.weight = pair[1];
            first.fade_target = index == 3 ? 0 : 1;
            first.fade_rate = 0.4f;
            second.fade_target = 0;
            second.fade_rate = 0.2f;
            fixture.expected_weight_rate = {
                index == 3 ? -(double)first.fade_rate : (double)first.fade_rate, -(double)second.fade_rate,
            };
            uint acquisitions = allocator.acquisitions;
            uint resizes = allocator.resizes;
            cycle_rate_check(&fixture, index >= 2);
            assert(allocator.acquisitions == acquisitions && allocator.resizes == resizes);
            assert(fixture.state.cycle_rate.translation.length() > CYCLE_RATE_TEST_MIN_NONZERO_RATE);
        }
        assert(allocator.outstanding == 0);
    }
}

fn void test_animation_cycle_rate_paused_group_fade_includes_zero_weight_members() @test {
    foreach (float weight : { 0.0f, 0.6f }) {
        CycleRateAllocationProbe allocator = { .backing = mem };
        {
            CycleRateFixture fixture;
            create_cycle_rate_fixture(&fixture, &allocator);
            defer destroy_cycle_rate_fixture(&fixture, &allocator);
            Action* first = fixture.actions.get(fixture.order[0]);
            Action* second = fixture.actions.get(fixture.order[1]);
            first.blend_space = 1;
            second.blend_space = 1;
            anim::write_blend_space_member(
                action: first,
                phase: { .phase = 0, .clock_rate = 0 },
                duration: 1,
                normalized: 0.25f,
                weight: weight,
                weight_rate: 0.8,
            );
            anim::write_blend_space_member(
                action: second,
                phase: { .phase = 0, .clock_rate = 0 },
                duration: 1,
                normalized: 0.75f,
                weight: weight,
                weight_rate: 0.8,
            );
            fixture.expected_weight_rate = { 0.2, 0.6 };
            uint acquisitions = allocator.acquisitions;
            uint resizes = allocator.resizes;
            cycle_rate_check(&fixture, weight == 0);
            assert(allocator.acquisitions == acquisitions && allocator.resizes == resizes);
            assert(first.clock_delta == 0 && second.clock_delta == 0);
            assert(fixture.state.cycle_rate.translation.length() > CYCLE_RATE_TEST_MIN_NONZERO_RATE);
        }
        assert(allocator.outstanding == 0);
    }
}

fn void test_animation_cycle_rate_weighted_masked_layers_transport_reference_anchor_rates() @test {
    CycleRateAllocationProbe allocator = { .backing = mem };
    {
        CycleRateFixture fixture;
        create_cycle_rate_fixture(&fixture, &allocator);
        defer destroy_cycle_rate_fixture(&fixture, &allocator);
        Action* first = fixture.actions.get(fixture.order[0]);
        Action* second = fixture.actions.get(fixture.order[1]);
        first.weight = 0.5f;
        first.fade_rate = 0.2f;
        first.fade_target = 1;
        second.layer = 1;
        second.weight = 0.3f;
        second.fade_rate = 0.1f;
        second.fade_target = 0;
        fixture.weighted_masks[0][..] = 0.5f;
        fixture.weighted_masks[1][..] = 0.75f;
        first.weighted_mask = fixture.weighted_masks[0][..];
        second.weighted_mask = fixture.weighted_masks[1][..];
        fixture.expected_weight_rate = { first.fade_rate, -(double)second.fade_rate };
        uint acquisitions = allocator.acquisitions;
        uint resizes = allocator.resizes;
        cycle_rate_check(&fixture);
        assert(allocator.acquisitions == acquisitions && allocator.resizes == resizes);
        assert(fixture.state.cycle_rate.translation.length() > CYCLE_RATE_TEST_MIN_NONZERO_RATE);
    }
    assert(allocator.outstanding == 0);
}
