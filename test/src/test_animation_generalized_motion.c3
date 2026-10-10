module c3d::test::generalized_motion;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import std::math;

const double GENERALIZED_POINT_EPSILON @local = 1e-5;

struct GeneralizedTestMatrix @local {
    double[4][4] values;
}

struct GeneralizedTestFixture @local {
    NodeTemplate[7] nodes;
    Track[5] tracks;
    uint[5] targets;
    float[2] times;
    float[6] ancestor_positions;
    float[8] ancestor_rotations;
    float[6] ancestor_scales;
    float[6] motion_positions;
    float[8] motion_rotations;
    ModelTemplate model;
    AnimationClip clip;
    CapturedMotionChain chain;
    GeneralizedMotionReference reference;
}

fn GeneralizedTestMatrix generalized_test_identity() @local {
    GeneralizedTestMatrix matrix;
    for (uint axis = 0; axis < 4; axis++) matrix.values[axis][axis] = 1;
    return matrix;
}

fn GeneralizedTestMatrix generalized_test_multiply(GeneralizedTestMatrix left, GeneralizedTestMatrix right) @local {
    GeneralizedTestMatrix matrix;
    for (uint row = 0; row < 4; row++) {
        for (uint column = 0; column < 4; column++) {
            for (uint axis = 0; axis < 4; axis++) {
                matrix.values[row][column] += left.values[row][axis] * right.values[axis][column];
            }
        }
    }
    return matrix;
}

fn double[<3>] generalized_test_point(GeneralizedTestMatrix matrix, double[<3>] point) @local {
    double[<3>] result;
    for (uint row = 0; row < 3; row++) {
        result[row] = matrix.values[row][3];
        for (uint column = 0; column < 3; column++) result[row] += matrix.values[row][column] * point[column];
    }
    return result;
}

fn GeneralizedTestMatrix generalized_test_rodrigues(double[<3>] axis, double angle) @local {
    GeneralizedTestMatrix matrix = generalized_test_identity();
    double[3][3] skew = {
        { 0, -axis.z, axis.y },
        { axis.z, 0, -axis.x },
        { -axis.y, axis.x, 0 },
    };
    double cosine = math::cos(angle);
    double sine = math::sin(angle);
    for (uint row = 0; row < 3; row++) {
        for (uint column = 0; column < 3; column++) {
            matrix.values[row][column] = (row == column ? cosine : 0)
              + (1 - cosine) * axis[row] * axis[column] + sine * skew[row][column];
        }
    }
    return matrix;
}

fn GeneralizedTestMatrix generalized_test_local_matrix(Transform local) @local {
    double[<4>] rotation = { local.rotation.v.x, local.rotation.v.y, local.rotation.v.z, local.rotation.v.w };
    rotation /= rotation.length();
    double x = rotation.x;
    double y = rotation.y;
    double z = rotation.z;
    double w = rotation.w;
    GeneralizedTestMatrix matrix = { .values = {
        { 1 - 2*y*y - 2*z*z, 2*x*y - 2*z*w, 2*x*z + 2*y*w, local.position.x },
        { 2*x*y + 2*z*w, 1 - 2*x*x - 2*z*z, 2*y*z - 2*x*w, local.position.y },
        { 2*x*z - 2*y*w, 2*y*z + 2*x*w, 1 - 2*x*x - 2*y*y, local.position.z },
        { 0, 0, 0, 1 },
    } };
    for (uint row = 0; row < 3; row++) {
        for (uint column = 0; column < 3; column++) matrix.values[row][column] *= local.scale[column];
    }
    return matrix;
}

fn GeneralizedTestMatrix generalized_test_frame_matrix(GeneralizedMotionFrame frame) @local {
    double[<3>] axis = { frame.rotation.v.x, frame.rotation.v.y, frame.rotation.v.z };
    double length = axis.length();
    GeneralizedTestMatrix matrix = length == 0 ? generalized_test_identity()
      : generalized_test_rodrigues(axis / length, 2 * math::atan2(length, frame.rotation.v.w));
    for (uint row = 0; row < 3; row++) {
        for (uint column = 0; column < 3; column++) matrix.values[row][column] *= frame.scale;
        matrix.values[row][3] = frame.position[row];
    }
    return matrix;
}

fn void generalized_test_worlds(ModelTemplate* model, Transform[] pose, GeneralizedTestMatrix[] worlds) @local {
    foreach (index, node : model.nodes) {
        GeneralizedTestMatrix local = generalized_test_local_matrix(pose[index]);
        worlds[index] = node.parent < 0 ? local : generalized_test_multiply(worlds[node.parent], local);
    }
}

fn void create_generalized_test_fixture(GeneralizedTestFixture* fixture) @local {
    int[7] parents = { -1, 0, 1, 0, -1, 4, 1 };
    String[7] names = { "base", "ancestor", "motion", "sibling", "rigid", "morph", "ik_target" };
    foreach (index, &node : fixture.nodes) {
        *node = { .parent = parents[index], .name = names[index], .local = maths::TRANSFORM_IDENTITY };
        node.local.position = { 0.1f * (float)index, 0.05f * (float)index, -0.15f * (float)index };
    }
    fixture.nodes[0].local.position = { 1, 0.5f, -0.25f };
    fixture.nodes[0].local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.15f);
    fixture.nodes[0].local.scale = { 1.25f, 1.25f, 1.25f };
    fixture.nodes[5].local.scale = { -1, 2, 1 };
    fixture.model = { .nodes = fixture.nodes[..] };
    fixture.times = { 0, 1 };
    fixture.targets = { 1, 1, 1, 2, 2 };
    fixture.ancestor_positions = { 0.1f, 0.2f, -0.1f, 0.4f, 0.5f, 0.2f };
    fixture.ancestor_scales = { 0.5f, 0.5f, 0.5f, 2, 2, 2 };
    fixture.motion_positions = { 2, 1, -0.5f, 2.8f, 1.2f, -0.2f };
    Quat ancestor_end = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.4f);
    Quat motion_end = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.3f)
      .mul(quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.2f));
    fixture.ancestor_rotations = { 0, 0, 0, 1,
        ancestor_end.v.x, ancestor_end.v.y, ancestor_end.v.z, ancestor_end.v.w };
    fixture.motion_rotations = { 0, 0, 0, 1,
        motion_end.v.x, motion_end.v.y, motion_end.v.z, motion_end.v.w };
    fixture.tracks = {
        { .target = 0, .path = TargetPath.TRANSLATION, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.ancestor_positions[..] },
        { .target = 1, .path = TargetPath.ROTATION, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.ancestor_rotations[..] },
        { .target = 2, .path = TargetPath.SCALE, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.ancestor_scales[..] },
        { .target = 3, .path = TargetPath.TRANSLATION, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.motion_positions[..] },
        { .target = 4, .path = TargetPath.ROTATION, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.motion_rotations[..] },
    };
    fixture.clip = { .duration = 1, .tracks = fixture.tracks[..], .targets = fixture.targets[..] };
    Vec3 up = (Vec3){ 1, 2, 3 }.normalize();
    fixture.chain = anim::create_captured_motion_chain(
        allocator: mem,
        template: &fixture.model,
        clip: &fixture.clip,
        root: 2,
        extraction: { .generalized = true, .translation_axes = { true, true, true }, .up = up, .twist = true },
    )!!;
    fixture.reference = anim::capture_generalized_motion_reference(&fixture.chain, &fixture.clip);
}

fn void generalized_test_pose(GeneralizedTestFixture* fixture, float time, Transform[] pose) @local {
    foreach (index, node : fixture.nodes) pose[index] = node.local;
    foreach (&track : fixture.tracks) {
        double[4] value;
        double[4] rate;
        uint cursor;
        anim::sample_track_analytic(
            track: track,
            time: time,
            cursor: &cursor,
            value: value[:track.stride()],
            rate: rate[:track.stride()],
        );
        Transform* local = &pose[fixture.targets[track.target]];
        switch (track.path) {
            case TRANSLATION:
                local.position = { (float)value[0], (float)value[1], (float)value[2] };
            case ROTATION:
                local.rotation = { .v = { (float)value[0], (float)value[1], (float)value[2], (float)value[3] } };
            case SCALE:
                local.scale = { (float)value[0], (float)value[1], (float)value[2] };
            case MORPH_WEIGHTS:
                continue;
        }
    }
}

fn void test_animation_generalized_motion_composes_animated_ancestors_and_compensates_all_branches_once() @test {
    GeneralizedTestFixture fixture;
    create_generalized_test_fixture(&fixture);
    defer anim::destroy_captured_motion_chain(&fixture.chain);
    float[5] times = { 0, 0.25f, 0.5f, 0.75f, 1 };
    double[<3>][4] corners = { {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
    foreach (time : times) {
        Transform[7] pose;
        generalized_test_pose(&fixture, time, pose[..]);
        GeneralizedTestMatrix[7] keep;
        generalized_test_worlds(&fixture.model, pose[..], keep[..]);
        GeneralizedMotionFrame endpoint = anim::sample_generalized_endpoint(&fixture.chain, &fixture.clip, time);
        assert((endpoint.position - generalized_test_point(keep[2], {})).length() <= GENERALIZED_POINT_EPSILON);
        assert(math::abs(endpoint.scale - 1.25 * (0.5 + 1.5 * (double)time)) < 1e-7);
        GeneralizedMotion motion = anim::generalized_motion_delta(
            chain: &fixture.chain,
            clip: &fixture.clip,
            reference: &fixture.reference,
            begin: 0,
            end: time,
            loop: false,
        );
        GeneralizedMotionFrame carrier = anim::generalized_frame_from_motion(motion, fixture.reference.up);
        GeneralizedMotionFrame correction = anim::generalized_branch_correction(carrier);
        Transform[7] original = pose;
        anim::compensate_generalized_branches(&fixture.chain, pose[..], correction);
        assert(pose[2].position == original[2].position && pose[2].scale == original[2].scale);
        assert(pose[6].position == original[6].position && pose[5].scale == (Vec3){ -1, 2, 1 });
        GeneralizedTestMatrix[7] corrected;
        generalized_test_worlds(&fixture.model, pose[..], corrected[..]);
        GeneralizedTestMatrix carrier_matrix = generalized_test_frame_matrix(carrier);
        for (uint node = 0; node < 7; node++) {
            GeneralizedTestMatrix consumed = generalized_test_multiply(carrier_matrix, corrected[node]);
            foreach (corner : corners) {
                double[<3>] actual = generalized_test_point(consumed, corner);
                double[<3>] expected = generalized_test_point(keep[node], corner);
                double error = (actual - expected).length();
                assert(error <= GENERALIZED_POINT_EPSILON);
            }
        }
    }
}

fn void test_animation_generalized_motion_reference_pivot_and_small_angle_are_literal() @test {
    CapturedMotionNode[1] nodes = { {
        .model_node = 0,
        .translation_track = anim::NO_MOTION_TRACK,
        .rotation_track = 0,
        .scale_track = anim::NO_MOTION_TRACK,
        .baseline = { .position = { 2, 1, -0.5f }, .rotation = quaternion::IDENTITY, .scale = { 1, 1, 1 } },
    } };
    float[2] times = { 0, 1 };
    float[8] values = { 0, 0, 0, 1, 0, 0.70710677f, 0, 0.70710677f };
    Track[1] tracks = { { .path = TargetPath.ROTATION, .interpolation = Interpolation.LINEAR,
        .times = times[..], .values = values[..] } };
    AnimationClip clip = { .duration = 1, .tracks = tracks[..] };
    CapturedMotionChain chain = { .nodes = nodes[..],
        .extraction = { .generalized = true, .up = { 0, 1, 0 }, .twist = true } };
    GeneralizedMotionReference reference = anim::capture_generalized_motion_reference(&chain, &clip);
    GeneralizedMotion delta = anim::generalized_motion_delta(
        chain: &chain,
        clip: &clip,
        reference: &reference,
        begin: 0,
        end: 1,
        loop: false,
    );
    assert((delta.translation - (double[<3>]){ 2.5, 0, 1.5 }).length() < 1e-12);
    assert(math::abs(delta.twist - math::PI / 2) < 1e-12);
    GeneralizedMotionFrame carrier = anim::generalized_frame_from_motion(delta, reference.up);
    double[<3>] pivot_world = carrier.position + carrier.rotation.rotate_vec3(reference.frame.position);
    assert((pivot_world - reference.frame.position).length() < 1e-12);
    double angle = 1e-8;
    double[<3>] small = anim::generalized_pivot_displacement(reference.up, angle, reference.frame.position);
    double[<3>] expected = { angle * 0.5 + angle * angle, 0, angle * 2 - angle * angle * 0.25 };
    assert((small - expected).length() < 1e-23);
}

fn void test_animation_generalized_motion_xyz_selection_and_unselected_channels() @test {
    CapturedMotionNode[1] nodes = { {
        .model_node = 0,
        .translation_track = 0,
        .rotation_track = anim::NO_MOTION_TRACK,
        .scale_track = anim::NO_MOTION_TRACK,
        .baseline = maths::TRANSFORM_IDENTITY,
    } };
    float[2] times = { 0, 1 };
    float[6] values = { 2, 1, -0.5f, 3, 2, 1.5f };
    Track[1] tracks = { { .path = TargetPath.TRANSLATION, .interpolation = Interpolation.LINEAR,
        .times = times[..], .values = values[..] } };
    AnimationClip clip = { .duration = 1, .tracks = tracks[..] };
    CapturedMotionChain chain = { .nodes = nodes[..], .extraction = { .generalized = true, .up = { 0, 0, 1 } } };
    for (uint selected = 0; selected < 4; selected++) {
        for (uint axis = 0; axis < 3; axis++) {
            chain.extraction.translation_axes[axis] = selected == 3 || selected == axis;
        }
        GeneralizedMotionReference reference = anim::capture_generalized_motion_reference(&chain, &clip);
        GeneralizedMotion delta = anim::generalized_motion_delta(
            chain: &chain,
            clip: &clip,
            reference: &reference,
            begin: 0,
            end: 1,
            loop: false,
        );
        double[<3>] literal = { 1, 1, 2 };
        for (uint axis = 0; axis < 3; axis++) {
            assert(delta.translation[axis] == (chain.extraction.translation_axes[axis] ? literal[axis] : 0));
        }
        assert(delta.twist == 0);
    }
}

fn GeneralizedTestMatrix test_generalized_cycle_matrix(
    double time,
    double[<3>] pivot,
    double[<2>] endpoint,
) @local {
    int cycles = (int)math::floor(time);
    double phase = time - cycles;
    double[<3>] up = { 0, 1, 0 };
    endpoint /= endpoint.length();
    double cycle_angle = 2 * math::atan2(endpoint.x, endpoint.y);
    GeneralizedTestMatrix cycle = generalized_test_rodrigues(up, cycles < 0 ? -cycle_angle : cycle_angle);
    GeneralizedTestMatrix forward = generalized_test_rodrigues(up, cycle_angle);
    double[<3>] full = (double[<3>]){ 0.8, 0.2, 0.3 } + pivot - generalized_test_point(forward, pivot);
    if (cycles < 0) full = generalized_test_point(cycle, -full);
    for (uint axis = 0; axis < 3; axis++) cycle.values[axis][3] = full[axis];
    GeneralizedTestMatrix accumulated = generalized_test_identity();
    for (int index = 0; index < math::abs(cycles); index++) accumulated = generalized_test_multiply(accumulated, cycle);
    // LINEAR chooses normalized interpolation for this close pair, so angle is not proportional to time.
    double partial_angle = 2 * math::atan2(phase * endpoint.x, 1 - phase + phase * endpoint.y);
    GeneralizedTestMatrix partial = generalized_test_rodrigues(up, partial_angle);
    double[<3>] displacement = (double[<3>]){ 0.8, 0.2, 0.3 } * phase
      + pivot - generalized_test_point(partial, pivot);
    for (uint axis = 0; axis < 3; axis++) partial.values[axis][3] = displacement[axis];
    return generalized_test_multiply(accumulated, partial);
}

fn void test_animation_generalized_motion_loops_reverse_subdivision_and_zero_identity() @test {
    CapturedMotionNode[1] nodes = { {
        .model_node = 0,
        .translation_track = 0,
        .rotation_track = 1,
        .scale_track = anim::NO_MOTION_TRACK,
        .baseline = maths::TRANSFORM_IDENTITY,
    } };
    float[2] times = { 0, 1 };
    float[6] positions = { 2, 1, -0.5f, 2.8f, 1.2f, -0.2f };
    Quat end = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.5f);
    float[8] rotations = { 0, 0, 0, 1, end.v.x, end.v.y, end.v.z, end.v.w };
    Track[2] tracks = {
        { .path = TargetPath.TRANSLATION, .interpolation = Interpolation.LINEAR,
            .times = times[..], .values = positions[..] },
        { .path = TargetPath.ROTATION, .interpolation = Interpolation.LINEAR,
            .times = times[..], .values = rotations[..] },
    };
    AnimationClip clip = { .duration = 1, .tracks = tracks[..] };
    CapturedMotionChain chain = { .nodes = nodes[..], .extraction = {
        .generalized = true, .translation_axes = { true, true, true }, .up = { 0, 1, 0 }, .twist = true,
    } };
    GeneralizedMotionReference reference = anim::capture_generalized_motion_reference(&chain, &clip);
    double[2] ends = { 2.4, -2.4 };
    uint[3] divisions = { 2, 7, 60 };
    foreach (finish : ends) {
        GeneralizedMotion full = anim::generalized_motion_delta(
            chain: &chain,
            clip: &clip,
            reference: &reference,
            begin: 0,
            end: finish,
            loop: true,
        );
        GeneralizedTestMatrix expected = test_generalized_cycle_matrix(
            time: finish,
            pivot: reference.frame.position,
            endpoint: { end.v.y, end.v.w },
        );
        assert((full.translation - generalized_test_point(expected, {})).length() < 1e-6);
        foreach (count : divisions) {
            GeneralizedMotion accumulated;
            for (uint step = 0; step < count; step++) {
                GeneralizedMotion delta = anim::generalized_motion_delta(
                    chain: &chain,
                    clip: &clip,
                    reference: &reference,
                    begin: finish * (double)step / (double)count,
                    end: finish * (double)(step + 1) / (double)count,
                    loop: true,
                );
                accumulated = anim::compose_generalized_motion(accumulated, delta, reference.up);
            }
            assert((accumulated.translation - full.translation).length() < 1e-10);
            assert(math::abs(math::sin((accumulated.twist - full.twist) * 0.5)) < 1e-12);
        }
    }
    GeneralizedMotion zero = anim::generalized_motion_delta(
        chain: &chain,
        clip: &clip,
        reference: &reference,
        begin: 2.4,
        end: 2.4,
        loop: true,
    );
    assert(zero.translation == (double[<3>]){} && zero.twist == 0);
}

fn void test_animation_generalized_motion_reference_anchor_preserves_reference_and_every_branch() @test {
    GeneralizedTestFixture fixture;
    create_generalized_test_fixture(&fixture);
    defer anim::destroy_captured_motion_chain(&fixture.chain);
    GeneralizedMotionFrame immutable = fixture.reference.frame;
    GeneralizedMotionFrame consumed = {
        .position = { 3, 2, -1 },
        .rotation = quaternion::from_axis_angle{double}({ 0, 0, 1 }, 0.7),
        .scale = 1,
    };
    GeneralizedMotionFrame anchor = anim::generalized_reference_anchor(consumed, fixture.reference.frame);
    GeneralizedMotionFrame rebased = anim::compose_generalized_frames(anchor, fixture.reference.frame);
    assert((rebased.position - consumed.position).length() < 1e-12);
    assert(math::abs(rebased.scale - 1) < 1e-12);
    assert(fixture.reference.frame.position == immutable.position);
    assert(fixture.reference.frame.rotation.v == immutable.rotation.v);
    Transform[7] pose;
    generalized_test_pose(&fixture, 0.5f, pose[..]);
    GeneralizedTestMatrix[7] keep;
    generalized_test_worlds(&fixture.model, pose[..], keep[..]);
    anim::compensate_generalized_branches(
        chain: &fixture.chain,
        pose: pose[..],
        correction: anim::generalized_branch_correction(consumed, anchor),
    );
    GeneralizedTestMatrix[7] corrected;
    generalized_test_worlds(&fixture.model, pose[..], corrected[..]);
    GeneralizedTestMatrix carrier_matrix = generalized_test_frame_matrix(consumed);
    GeneralizedTestMatrix anchor_matrix = generalized_test_frame_matrix(anchor);
    for (uint node = 0; node < 7; node++) {
        GeneralizedTestMatrix actual = generalized_test_multiply(carrier_matrix, corrected[node]);
        GeneralizedTestMatrix expected = generalized_test_multiply(anchor_matrix, keep[node]);
        assert((generalized_test_point(actual, {}) - generalized_test_point(expected, {})).length()
          <= GENERALIZED_POINT_EPSILON);
    }
}
