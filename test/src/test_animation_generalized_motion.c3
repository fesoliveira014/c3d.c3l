module c3d::test::anim;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::pool;
import c3d::scene;
import std::math;

const double GENERALIZED_POINT_EPSILON @local = 1e-5;
const double GENERALIZED_MOTION_EPSILON @local = 2e-6;
const uint GENERALIZED_SUBDIVISIONS @local = 7;

enum AdmissionMutation @local {
    ROOT_OUTSIDE_MODEL,
    FORWARD_PARENT,
    CLIP_TARGET_OUTSIDE_MODEL,
    TRACK_TARGET_OUTSIDE_CLIP,
    MISSING_UP,
    FOREIGN_PARENT_SPACE,
    NONUNIFORM_INSTANCE,
    NONUNIFORM_BASELINE,
    NEGATIVE_BASELINE,
    SHEARED_BASELINE,
    DUPLICATE_TRACK_PATH,
    ZERO_QUATERNION,
}

struct MotionAdmissionFixture @local {
    NodeTemplate[7] nodes;
    Track[6] tracks;
    uint[6] targets;
    float[2] times;
    float[6] translations;
    float[8] rotations;
    float[6] scales;
    float[6] excluded_scales;
    ModelTemplate model;
    AnimationClip clip;
    RootExtractionDesc extraction;
    MotionBasis basis;
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

struct GeneralizedPlaybackFixture @local {
    NodeTemplate[5] nodes;
    Transform[5] base_pose;
    Transform[5] reference_pose;
    Track[5] tracks;
    uint[5] targets;
    float[2] times;
    float[6] ancestor_positions;
    float[8] ancestor_rotations;
    float[6] ancestor_scales;
    float[6] motion_positions;
    float[8] motion_rotations;
    uint[5] cursors;
    uint[5] second_cursors;
    bool[5] mask;
    AssetStore assets;
    Pool{Action, AnimationActionId} actions;
    CapturedMotionChain chain;
    AnimationActionId[2] order;
    uint action_count;
    PlaybackView view;
    PoseStorage* pose;
    RootExtractionDesc extraction;
}

fn void create_motion_admission_fixture(MotionAdmissionFixture* fixture) @local {
    int[7] parents = { -1, 0, 1, 0, -1, 4, 1 };
    String[7] names = { "base", "spine", "motion", "arm", "independent", "extra", "leaf" };
    foreach (index, &node : fixture.nodes) {
        *node = {
            .parent = parents[index],
            .name = names[index],
            .local = maths::TRANSFORM_IDENTITY,
        };
        node.local.position = { (float)index, (float)index * 0.5f, -(float)index };
    }
    fixture.nodes[0].local.scale = { 2, 2, 2 };
    fixture.nodes[1].local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.4f);
    fixture.nodes[2].local.scale = { 0.5f, 0.5f, 0.5f };
    fixture.model = { .nodes = fixture.nodes[..] };
    fixture.times = { -1, 1 };
    fixture.translations = { -2, 1, 3, 6, 5, 7 };
    fixture.rotations = { 0, 0, 0, 1, 0, 0.70710677f, 0, 0.70710677f };
    fixture.scales = { 0.5f, 0.5f, 0.5f, 2, 2, 2 };
    fixture.excluded_scales = { 1, 2, 1, 1, 2, 1 };
    fixture.targets = { 2, 1, 0, 2, 2, 5 };
    fixture.tracks = {
        { .target = 0, .path = TargetPath.TRANSLATION, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.translations[..] },
        { .target = 1, .path = TargetPath.ROTATION, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.rotations[..] },
        { .target = 2, .path = TargetPath.SCALE, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.scales[..] },
        { .target = 3, .path = TargetPath.ROTATION, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.rotations[..] },
        { .target = 4, .path = TargetPath.SCALE, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.scales[..] },
        { .target = 5, .path = TargetPath.SCALE, .interpolation = Interpolation.LINEAR,
            .times = fixture.times[..], .values = fixture.excluded_scales[..] },
    };
    fixture.clip = { .duration = 1, .tracks = fixture.tracks[..], .targets = fixture.targets[..] };
    fixture.extraction = {
        .generalized = true,
        .translation_axes = { true, false, true },
        .up = { 0, 1, 0 },
        .twist = true,
    };
    fixture.basis = {
        .root_present = true,
        .parent_space = true,
        .ancestors_parent_space = true,
        .basis = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.7f).to_matrix(),
        .instance_scale = { 2, 2, 2 },
    };
}

fn void? validate_admission_fixture(MotionAdmissionFixture* fixture, uint root = 2, bool additive = false) @local {
    return anim::validate_generalized_motion(
        template: &fixture.model,
        clip: &fixture.clip,
        root: root,
        extraction: fixture.extraction,
        motion_basis: fixture.basis,
        additive: additive,
        additive_scale: AdditiveScaleMode.DIFFERENCE,
    );
}

fn CapturedMotionChain capture_admission_fixture(
    MotionAdmissionFixture* fixture,
    Allocator allocator = mem,
    uint root = 2,
) @local {
    return anim::create_captured_motion_chain(
        allocator: allocator,
        template: &fixture.model,
        clip: &fixture.clip,
        root: root,
        extraction: fixture.extraction,
    )!!;
}

fn void test_animation_motion_admission_captures_full_chain_and_all_top_level_branches() @test {
    MotionAdmissionFixture fixture;
    create_motion_admission_fixture(&fixture);
    validate_admission_fixture(&fixture)!!;
    CapturedMotionChain captured = capture_admission_fixture(&fixture);
    defer anim::destroy_captured_motion_chain(&captured);
    assert(captured.root_node == 2 && captured.clip_track_count == 6);
    assert(captured.nodes.len == 3 && captured.model_names.len == 7 && captured.model_parents.len == 7);
    assert(captured.nodes[0].model_node == 2 && captured.nodes[1].model_node == 1 && captured.nodes[2].model_node == 0);
    assert(captured.top_level_nodes == (uint[2]){ 0, 4 }[..]);
    assert(captured.nodes[0].translation_track == 0 && captured.nodes[0].rotation_track == 3);
    assert(captured.nodes[0].scale_track == 4 && captured.nodes[1].rotation_track == 1);
    assert(captured.nodes[1].translation_track == anim::NO_MOTION_TRACK);
    assert(captured.nodes[1].scale_track == anim::NO_MOTION_TRACK);
    assert(captured.nodes[2].scale_track == 2 && captured.nodes[2].rotation_track == anim::NO_MOTION_TRACK);
    assert(captured.nodes[0].reference.position == (Vec3){ 2, 3, 5 });
    assert(captured.nodes[0].reference.scale == (Vec3){ 1.25f, 1.25f, 1.25f });
    assert(captured.nodes[0].reference_scale == 1.25 && captured.nodes[2].reference_scale == 1.25);
    assert(math::abs((double)captured.nodes[0].reference.rotation.v.y - math::sin(math::PI * 0.125)) < 1e-6);
    assert(math::abs((double)captured.nodes[0].reference.rotation.v.w - math::cos(math::PI * 0.125)) < 1e-6);
    foreach (index, node : fixture.nodes) {
        assert(captured.model_names[index] == node.name && captured.model_parents[index] == node.parent);
    }
    assert(captured.extraction.translation_axes == (bool[3]){ true, false, true });
    assert(captured.extraction.up == (Vec3){ 0, 1, 0 } && captured.extraction.twist);
    fixture.nodes[0].name = "changed";
    fixture.nodes[1].parent = -1;
    fixture.nodes[2].local.position = {};
    fixture.extraction.translation_axes[..] = false;
    assert(captured.model_names[0] == "base" && captured.model_parents[1] == 0);
    assert(captured.nodes[0].baseline.position == (Vec3){ 2, 1, -2 });
    assert(captured.nodes[0].reference.position == (Vec3){ 2, 3, 5 });
    assert(captured.extraction.translation_axes[0] && captured.extraction.translation_axes[2]);
}

fn void test_animation_motion_admission_changed_root_maps_its_own_ancestors() @test {
    MotionAdmissionFixture fixture;
    create_motion_admission_fixture(&fixture);
    validate_admission_fixture(&fixture, 6)!!;
    CapturedMotionChain leaf = capture_admission_fixture(&fixture, mem, 6);
    defer anim::destroy_captured_motion_chain(&leaf);
    assert(leaf.nodes.len == 3 && leaf.nodes[0].model_node == 6 && leaf.nodes[1].model_node == 1);
    assert(leaf.nodes[0].translation_track == anim::NO_MOTION_TRACK);
    assert(leaf.nodes[0].rotation_track == anim::NO_MOTION_TRACK && leaf.nodes[0].scale_track == anim::NO_MOTION_TRACK);
    assert(leaf.nodes[1].rotation_track == 1 && leaf.nodes[2].scale_track == 2);
    CapturedMotionChain independent = capture_admission_fixture(&fixture, mem, 4);
    defer anim::destroy_captured_motion_chain(&independent);
    assert(independent.nodes.len == 1 && independent.nodes[0].model_node == 4);
    assert(independent.top_level_nodes == (uint[2]){ 0, 4 }[..]);
    assert(@catch(validate_admission_fixture(&fixture, 5)) == c3d::INVALID_ARGUMENT);
}

fn void test_animation_motion_admission_rejects_each_invalid_input_with_its_fault() @test {
    foreach (mutation : AdmissionMutation::values) {
        MotionAdmissionFixture fixture;
        create_motion_admission_fixture(&fixture);
        float[2] times = { 0, 1 };
        float[24] rotations = { 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, -4,
            0, 0, 0, 4, 0, 0, 0, 1, 0, 0, 0, 0 };
        uint root = 2;
        fault expected = c3d::INVALID_ARGUMENT;
        switch (mutation) {
            case ROOT_OUTSIDE_MODEL:
                root = 7;
            case FORWARD_PARENT:
                fixture.nodes[1].parent = 2;
            case CLIP_TARGET_OUTSIDE_MODEL:
                fixture.targets[4] = 7;
            case TRACK_TARGET_OUTSIDE_CLIP:
                fixture.tracks[4].target = 6;
            case MISSING_UP:
                fixture.extraction.up = {};
            case FOREIGN_PARENT_SPACE:
                fixture.basis.parent_space = false;
            case NONUNIFORM_INSTANCE:
                fixture.basis.instance_scale = { 2, 0.5f, 2 };
            case NONUNIFORM_BASELINE:
                fixture.nodes[1].local.scale = { 1, 2, 1 };
            case NEGATIVE_BASELINE:
                fixture.nodes[1].local.scale = { -1, 1, 1 };
            case SHEARED_BASELINE:
                fixture.nodes[1].local.rotation = { .v = { 0.3f, 0.2f, 0.1f, 1 } };
            case DUPLICATE_TRACK_PATH:
                fixture.tracks[4].path = TargetPath.ROTATION;
            case ZERO_QUATERNION:
                rotations[7] = 0;
                fixture.tracks[3].interpolation = Interpolation.CUBIC_SPLINE;
                fixture.tracks[3].times = times[..];
                fixture.tracks[3].values = rotations[..];
        }
        assert(@catch(validate_admission_fixture(&fixture, root)) == expected);
    }
}

fn void test_animation_motion_admission_cubic_scale_defers_to_invalid_faults() @test {
    MotionAdmissionFixture fixture;
    create_motion_admission_fixture(&fixture);
    float[2] times = { 0, 1 };
    float[18] values = { 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0 };
    fixture.tracks[4].interpolation = Interpolation.CUBIC_SPLINE;
    fixture.tracks[4].times = times[..];
    fixture.tracks[4].values = values[..];
    assert(@catch(validate_admission_fixture(&fixture)) == c3d::UNSUPPORTED);
    fixture.nodes[0].local.scale = { 1, 2, 1 };
    assert(@catch(validate_admission_fixture(&fixture)) == c3d::INVALID_ARGUMENT);
    fixture.nodes[0].local.scale = { 2, 2, 2 };
    fixture.tracks[2].values = fixture.excluded_scales[..];
    assert(@catch(validate_admission_fixture(&fixture)) == c3d::INVALID_ARGUMENT);
}

fn void test_animation_motion_admission_neutral_difference_zero_and_signed_scales() @test {
    MotionAdmissionFixture fixture;
    create_motion_admission_fixture(&fixture);
    fixture.scales = { -1, 0, 2, -1, 0, 2 };
    validate_admission_fixture(&fixture, 2, true)!!;
    fixture.scales[3] = -2;
    assert(@catch(validate_admission_fixture(&fixture, 2, true)) == c3d::INVALID_ARGUMENT);
}

fn void test_animation_motion_capture_failure_releases_every_partial_allocation() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    MotionTestAllocator allocator = { .backing = &tracker };
    MotionAdmissionFixture fixture;
    create_motion_admission_fixture(&fixture);
    uint acquisitions;
    {
        CapturedMotionChain completed = capture_admission_fixture(&fixture, &allocator);
        defer anim::destroy_captured_motion_chain(&completed);
        acquisitions = allocator.attempts;
        assert(acquisitions > 0);
    }
    assert(allocator.outstanding == 0 && !tracker.has_leaks());
    for (uint failure = 1; failure <= acquisitions; failure++) {
        allocator.attempts = 0;
        allocator.failure = failure;
        bool caught;
        if (catch excuse = anim::create_captured_motion_chain(
            allocator: &allocator,
            template: &fixture.model,
            clip: &fixture.clip,
            root: 2,
            extraction: fixture.extraction,
        )) {
            assert(excuse == c3d::CAPACITY_EXCEEDED);
            caught = true;
        }
        assert(caught && allocator.attempts == failure);
        assert(allocator.outstanding == 0 && !tracker.has_leaks());
        assert(fixture.nodes[1].parent == 0 && fixture.nodes[0].name == "base");
        assert(fixture.targets[4] == 2 && fixture.tracks[4].values.ptr == &fixture.scales[0]);
    }
    allocator.attempts = 0;
    allocator.failure = 1;
    bool caught;
    if (catch excuse = anim::create_captured_motion_chain(
        allocator: &allocator,
        template: &fixture.model,
        clip: &fixture.clip,
        root: 7,
        extraction: fixture.extraction,
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT);
        caught = true;
    }
    assert(caught && allocator.attempts == 0 && allocator.outstanding == 0);
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
        uint cursor;
        anim::sample_track_analytic(
            track: track,
            time: time,
            cursor: &cursor,
            value: value[:track.stride()],
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
        MotionTestMatrix[7] keep;
        motion_test_worlds(fixture.nodes[..], pose[..], keep[..]);
        GeneralizedMotionFrame endpoint = anim::sample_generalized_endpoint(
            chain: &fixture.chain,
            clip: &fixture.clip,
            time: anim::fixed_clip_time(time),
        );
        assert((endpoint.position - motion_test_point(keep[2], {})).length() <= GENERALIZED_POINT_EPSILON);
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
        GeneralizedMotionFrame correction = anim::inverse_generalized_frame(carrier);
        Transform[7] original = pose;
        anim::compensate_generalized_branches(&fixture.chain, pose[..], correction);
        assert(pose[2].position == original[2].position && pose[2].scale == original[2].scale);
        assert(pose[6].position == original[6].position && pose[5].scale == (Vec3){ -1, 2, 1 });
        MotionTestMatrix[7] corrected;
        motion_test_worlds(fixture.nodes[..], pose[..], corrected[..]);
        MotionTestMatrix carrier_matrix = motion_test_frame(carrier);
        for (uint node = 0; node < 7; node++) {
            MotionTestMatrix consumed = motion_test_product(carrier_matrix, corrected[node]);
            foreach (corner : corners) {
                double[<3>] actual = motion_test_point(consumed, corner);
                double[<3>] expected = motion_test_point(keep[node], corner);
                assert((actual - expected).length() <= GENERALIZED_POINT_EPSILON);
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

fn MotionTestMatrix generalized_cycle_matrix(
    double time,
    double[<3>] pivot,
    double[<2>] endpoint,
) @local {
    int cycles = (int)math::floor(time);
    double phase = time - cycles;
    double[<3>] up = { 0, 1, 0 };
    endpoint /= endpoint.length();
    double cycle_angle = 2 * math::atan2(endpoint.x, endpoint.y);
    MotionTestMatrix cycle = motion_test_rodrigues(up, cycles < 0 ? -cycle_angle : cycle_angle);
    MotionTestMatrix forward = motion_test_rodrigues(up, cycle_angle);
    double[<3>] full = (double[<3>]){ 0.8, 0.2, 0.3 } + pivot - motion_test_point(forward, pivot);
    if (cycles < 0) full = motion_test_point(cycle, -full);
    for (uint axis = 0; axis < 3; axis++) cycle.cells[axis][3] = full[axis];
    MotionTestMatrix accumulated = motion_test_identity();
    for (int index = 0; index < math::abs(cycles); index++) accumulated = motion_test_product(accumulated, cycle);
    // LINEAR chooses normalized interpolation for this close pair, so angle is not proportional to time.
    double partial_angle = 2 * math::atan2(phase * endpoint.x, 1 - phase + phase * endpoint.y);
    MotionTestMatrix partial = motion_test_rodrigues(up, partial_angle);
    double[<3>] displacement = (double[<3>]){ 0.8, 0.2, 0.3 } * phase
      + pivot - motion_test_point(partial, pivot);
    for (uint axis = 0; axis < 3; axis++) partial.cells[axis][3] = displacement[axis];
    return motion_test_product(accumulated, partial);
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
    foreach (finish : ends) {
        GeneralizedMotion full = anim::generalized_motion_delta(
            chain: &chain,
            clip: &clip,
            reference: &reference,
            begin: 0,
            end: finish,
            loop: true,
        );
        MotionTestMatrix expected = generalized_cycle_matrix(
            time: finish,
            pivot: reference.frame.position,
            endpoint: { end.v.y, end.v.w },
        );
        assert((full.translation - motion_test_point(expected, {})).length() < 1e-6);
        GeneralizedMotion accumulated;
        for (uint step = 0; step < GENERALIZED_SUBDIVISIONS; step++) {
            GeneralizedMotion delta = anim::generalized_motion_delta(
                chain: &chain,
                clip: &clip,
                reference: &reference,
                begin: finish * (double)step / (double)GENERALIZED_SUBDIVISIONS,
                end: finish * (double)(step + 1) / (double)GENERALIZED_SUBDIVISIONS,
                loop: true,
            );
            accumulated = anim::compose_generalized_motion(accumulated, delta, reference.up);
        }
        assert((accumulated.translation - full.translation).length() < 1e-10);
        assert(math::abs(math::sin((accumulated.twist - full.twist) * 0.5)) < 1e-12);
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

fn double[<4>] playback_test_quaternion_product(double[<4>] left, double[<4>] right) @local {
    return {
        left.w*right.x + left.x*right.w + left.y*right.z - left.z*right.y,
        left.w*right.y - left.x*right.z + left.y*right.w + left.z*right.x,
        left.w*right.z + left.x*right.y - left.y*right.x + left.z*right.w,
        left.w*right.w - left.x*right.x - left.y*right.y - left.z*right.z,
    };
}

fn double[<4>] playback_test_chain_rotation(Transform[] pose) @local {
    double[<4>] result = { 0, 0, 0, 1 };
    for (uint index = 0; index < 3; index++) {
        Quat rotation = pose[index].rotation;
        double[<4>] value = { rotation.v.x, rotation.v.y, rotation.v.z, rotation.v.w };
        result = playback_test_quaternion_product(result, value / value.length());
    }
    return result;
}

fn double[<3>] playback_test_up(GeneralizedPlaybackFixture* fixture) @local {
    Vec3 value = fixture.extraction.up;
    double[<3>] up = { value.x, value.y, value.z };
    return up / up.length();
}

fn GeneralizedMotion playback_test_expected_endpoint(
    GeneralizedPlaybackFixture* fixture,
    Transform[] pose,
) @local {
    MotionTestMatrix[5] reference;
    MotionTestMatrix[5] current;
    motion_test_worlds(fixture.nodes[..], fixture.reference_pose[..], reference[..]);
    motion_test_worlds(fixture.nodes[..], pose, current[..]);
    double[<3>] pivot = motion_test_point(reference[2], {});
    double[<3>] translation = motion_test_point(current[2], {}) - pivot;
    for (uint axis = 0; axis < 3; axis++) {
        if (!fixture.extraction.translation_axes[axis]) translation[axis] = 0;
    }
    double[<3>] up = playback_test_up(fixture);
    double twist;
    if (fixture.extraction.twist) {
        double[<4>] begin = playback_test_chain_rotation(fixture.reference_pose[..]);
        double[<4>] end = playback_test_chain_rotation(pose);
        double initial = 2 * math::atan2(begin.x*up.x + begin.y*up.y + begin.z*up.z, begin.w);
        double final = 2 * math::atan2(end.x*up.x + end.y*up.y + end.z*up.z, end.w);
        twist = math::atan2(math::sin(final - initial), math::cos(final - initial));
    }
    MotionTestMatrix rotation = motion_test_rodrigues(up, twist);
    return { .translation = translation + pivot - motion_test_point(rotation, pivot), .twist = twist };
}

fn void playback_test_raw_pose(GeneralizedPlaybackFixture* fixture, float time, Transform[] output) @local {
    Action* action = fixture.actions.get(fixture.order[0]);
    float saved = action.time;
    action.time = time;
    anim::blend_pose(
        playback: &fixture.view,
        assets: &fixture.assets,
        destination: fixture.pose.destination,
        scratch: fixture.pose.scratch,
        consumed_chain: anim::generalized_playback_chain(&fixture.view),
    );
    output[..] = fixture.pose.destination.pose[..];
    action.time = saved;
}

fn void create_generalized_playback_fixture(
    GeneralizedPlaybackFixture* fixture,
    RootExtractionDesc extraction,
) @local {
    int[5] parents = { -1, 0, 1, 0, -1 };
    String[5] names = { "base", "ancestor", "motion", "sibling", "rigid_branch" };
    foreach (index, &node : fixture.nodes) {
        *node = { .parent = parents[index], .name = names[index], .local = maths::TRANSFORM_IDENTITY };
        node.local.position = { 0.1f * (float)index, 0.05f * (float)index, -0.15f * (float)index };
    }
    fixture.nodes[0].local.position = { 1, 0.5f, -0.25f };
    fixture.nodes[0].local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.15f);
    fixture.nodes[0].local.scale = { 1.25f, 1.25f, 1.25f };
    fixture.nodes[4].local.scale = { -1, 2, 1 };
    foreach (index, node : fixture.nodes) fixture.base_pose[index] = node.local;
    fixture.times = { 0, 1 };
    fixture.targets = { 1, 1, 1, 2, 2 };
    fixture.ancestor_positions = { 0.1f, 0.2f, -0.1f, 0.4f, 0.5f, 0.2f };
    fixture.ancestor_scales = { 0.5f, 0.5f, 0.5f, 2, 2, 2 };
    fixture.motion_positions = { 2, 1, -0.5f, 2.8f, 1.2f, -0.2f };
    Quat ancestor_end = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.4f);
    Quat motion_end = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.3f)
      .mul(quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.2f));
    fixture.ancestor_rotations = {
        0, 0, 0, 1, ancestor_end.v.x, ancestor_end.v.y, ancestor_end.v.z, ancestor_end.v.w,
    };
    fixture.motion_rotations = { 0, 0, 0, 1, motion_end.v.x, motion_end.v.y, motion_end.v.z, motion_end.v.w };
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
    ModelTemplate model = { .nodes = fixture.nodes[..] };
    AnimationClip clip = { .duration = 1, .tracks = fixture.tracks[..], .targets = fixture.targets[..] };
    fixture.chain = anim::create_captured_motion_chain(
        allocator: mem,
        template: &model,
        clip: &clip,
        root: 2,
        extraction: extraction,
    )!!;
    fixture.chain.pose_scale_sums = alloc::new_array(mem, double[<3>], fixture.nodes.len);
    fixture.assets.clips = pool::create_pool{ClipAsset, ClipId}(mem, 1);
    ClipId clip_id = fixture.assets.clips.add({ .data = clip })!!;
    fixture.actions = pool::create_pool{Action, AnimationActionId}(mem, 2);
    fixture.mask[..] = true;
    fixture.order[0] = fixture.actions.add({
        .clip = clip_id,
        .cursors = fixture.cursors[..],
        .mask = fixture.mask[..],
        .speed = 1,
        .weight = 1,
        .fade_target = 1,
        .playing = true,
        .loop = true,
        .root_motion = RootMotion.EXTRACT,
        .extraction = extraction,
        .motion_chain = &fixture.chain,
        .motion_reference = anim::capture_generalized_motion_reference(&fixture.chain, &clip),
        .translation_track = anim::NO_MOTION_TRACK,
        .rotation_track = anim::NO_MOTION_TRACK,
    })!!;
    fixture.action_count = 1;
    fixture.view = {
        .allocator = mem,
        .actions = &fixture.actions,
        .order = fixture.order[..],
        .action_count = &fixture.action_count,
        .root_node = 2,
    };
    fixture.pose = anim::create_pose_storage_try(
        allocator: mem,
        base_pose: fixture.base_pose[..],
        mesh_nodes: {},
        base_morph_weights: {},
        event_capacity: 0,
    )!!;
    fixture.extraction = extraction;
    playback_test_raw_pose(fixture, 0, fixture.reference_pose[..]);
}

fn void destroy_generalized_playback_fixture(GeneralizedPlaybackFixture* fixture) @local {
    anim::destroy_pose_storage(mem, fixture.pose);
    pool::destroy_pool{Action, AnimationActionId}(&fixture.actions);
    pool::destroy_pool{ClipAsset, ClipId}(&fixture.assets.clips);
    anim::destroy_captured_motion_chain(&fixture.chain);
}

fn void playback_test_compare_worlds(
    GeneralizedPlaybackFixture* fixture,
    MotionTestMatrix consumed,
    Transform[] keep,
) @local {
    MotionTestMatrix[5] expected;
    MotionTestMatrix[5] actual;
    motion_test_worlds(fixture.nodes[..], keep, expected[..]);
    motion_test_worlds(fixture.nodes[..], fixture.pose.destination.pose, actual[..]);
    double[<3>][4] corners = { {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
    for (uint node = 0; node < 5; node++) {
        MotionTestMatrix reconstructed = motion_test_product(consumed, actual[node]);
        foreach (corner : corners) {
            assert((motion_test_point(reconstructed, corner) - motion_test_point(expected[node], corner)).length()
              <= GENERALIZED_POINT_EPSILON);
        }
    }
}

fn void test_animation_generalized_playback_axes_weighted_layers_and_exact_emitted_motion() @test {
    for (uint selected = 0; selected < 4; selected++) {
        GeneralizedPlaybackFixture fixture;
        RootExtractionDesc extraction = { .generalized = true, .up = { 0, 0, 1 } };
        for (uint axis = 0; axis < 3; axis++) extraction.translation_axes[axis] = selected == 3 || selected == axis;
        create_generalized_playback_fixture(&fixture, extraction);
        defer destroy_generalized_playback_fixture(&fixture);
        Action* first = fixture.actions.get(fixture.order[0]);
        first.weight = selected == 3 ? 1 : 0.25f;
        Action second = *first;
        second.weight = 0.75f;
        second.layer = selected == 3 ? 1 : 0;
        second.cursors = fixture.second_cursors[..];
        fixture.order[1] = fixture.actions.add(second)!!;
        fixture.action_count = 2;
        Action* last = fixture.actions.get(fixture.order[1]);
        anim::advance_clock(first, 1, 0.25);
        anim::advance_clock(last, 1, 0.25);
        anim::blend_pose(
            playback: &fixture.view,
            assets: &fixture.assets,
            destination: fixture.pose.destination,
            scratch: fixture.pose.scratch,
            consumed_chain: anim::generalized_playback_chain(&fixture.view),
        );
        Transform[5] keep;
        keep[..] = fixture.pose.destination.pose[..];
        GeneralizedMotion expected = playback_test_expected_endpoint(&fixture, keep[..]);
        GeneralizedMotion delta = anim::evaluate_generalized_playback_motion(
            playback: &fixture.view,
            assets: &fixture.assets,
            destination: fixture.pose.destination,
            chain: anim::generalized_playback_chain(&fixture.view),
            dt: 0.25,
        );
        assert(delta.twist == 0);
        for (uint axis = 0; axis < 3; axis++) {
            assert(math::abs(delta.translation[axis] - expected.translation[axis]) < GENERALIZED_MOTION_EPSILON);
            if (!extraction.translation_axes[axis]) assert(delta.translation[axis] == 0);
        }
        playback_test_compare_worlds(
            fixture: &fixture,
            consumed: motion_test_motion(delta, playback_test_up(&fixture)),
            keep: keep[..],
        );
    }
}

fn AnimationClip playback_test_owned_clip(GeneralizedPlaybackFixture* fixture) @local {
    AnimationClip clip = {
        .duration = 1,
        .tracks = alloc::new_array(mem, Track, fixture.tracks.len),
        .targets = alloc::new_array(mem, uint, fixture.targets.len),
    };
    clip.targets[..] = fixture.targets[..];
    foreach (index, track : fixture.tracks) {
        clip.tracks[index] = track;
        clip.tracks[index].times = alloc::new_array(mem, float, track.times.len);
        clip.tracks[index].times[..] = track.times[..];
        clip.tracks[index].values = alloc::new_array(mem, float, track.values.len);
        clip.tracks[index].values[..] = track.values[..];
    }
    return clip;
}

fn void test_animation_generalized_playback_animator_consumption_matches_keep_without_history_allocation() @test {
    for (uint mode = 0; mode < 3; mode++) {
        GeneralizedPlaybackFixture fixture;
        create_generalized_playback_fixture(&fixture, {
            .generalized = true,
            .translation_axes = { true, true, true },
            .up = (Vec3){ 1, 2, 3 }.normalize(),
            .twist = true,
        });
        defer destroy_generalized_playback_fixture(&fixture);
        AssetStore assets = asset::create_asset_store(mem, {
            .max_geometries = 1,
            .max_textures = 8,
            .max_materials = 1,
            .max_samplers = 8,
            .max_models = 1,
            .max_skeletons = 1,
            .max_clips = 1,
        });
        defer asset::destroy_asset_store(&assets);
        ModelTemplate template = { .nodes = alloc::new_array(mem, NodeTemplate, fixture.nodes.len) };
        template.nodes[..] = fixture.nodes[..];
        foreach (&node : template.nodes) node.name = node.name.copy(mem);
        ModelId model_id = assets.add_model_owned(&template)!!;
        AnimationClip clip = playback_test_owned_clip(&fixture);
        ClipId clip_id = assets.add_clip_owned(&clip)!!;
        MotionTestAllocator allocator = { .backing = mem };
        Scene scene = scene::create_scene(&allocator, { .max_nodes = 20 });
        defer scene::destroy_scene(&scene);
        Node* kept_root = model::instantiate(&assets, &scene, model_id)!!;
        Node* extracted_root = model::instantiate(&assets, &scene, model_id)!!;
        Animator* kept = anim::add_animator(&scene, kept_root);
        Animator* extracted = anim::add_animator(&scene, extracted_root);
        extracted.root_node = 2;
        AnimationActionId kept_id = kept.play(&assets, clip_id)!!;
        AnimationActionId extracted_id = extracted.play(
            assets: &assets,
            clip: clip_id,
            desc: { .root_motion = RootMotion.EXTRACT, .extraction = fixture.extraction },
        )!!;
        kept.action(kept_id).loop = mode != 0;
        extracted.action(extracted_id).loop = mode != 0;
        kept.action(kept_id).speed = mode == 2 ? -1 : 1;
        extracted.action(extracted_id).speed = mode == 2 ? -1 : 1;
        assert(extracted.inertial_storage == null && extracted.pose_storage.scratch.inertial == null);
        Transform[5] endpoint;
        playback_test_raw_pose(&fixture, 1, endpoint[..]);
        MotionTestMatrix cycle = motion_test_motion(
            motion: playback_test_expected_endpoint(&fixture, endpoint[..]),
            up: playback_test_up(&fixture),
        );
        MotionTestMatrix reverse_cycle = motion_test_rigid_inverse(cycle);
        uint frames = mode == 0 ? 8 : 20;
        uint acquisitions = allocator.acquisitions;
        uint resizes = allocator.resizes;
        for (uint frame = 0; frame < frames; frame++) {
            anim::update(&assets, &scene, 0.125f);
            anim::apply_root_motion(extracted_root, extracted.root_motion);
            scene.update_world();
            int cycles = mode == 0 ? 0 : (int)math::floor((mode == 2 ? -1.0 : 1.0) * (double)(frame + 1) * 0.125);
            MotionTestMatrix anchor = motion_test_identity();
            for (int index = 0; index < math::abs(cycles); index++) {
                anchor = motion_test_product(anchor, cycles < 0 ? reverse_cycle : cycle);
            }
            ModelInstance* kept_instance = scene.get(kept_root, ModelInstance);
            ModelInstance* extracted_instance = scene.get(extracted_root, ModelInstance);
            Transform[5] keep;
            foreach (index, &local : keep) *local = kept_instance.present_node((uint)index).local;
            MotionTestMatrix[5] expected_worlds;
            motion_test_worlds(fixture.nodes[..], keep[..], expected_worlds[..]);
            double[<3>][4] corners = { {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
            for (uint node = 0; node < 5; node++) {
                MotionTestMatrix expected = motion_test_product(anchor, expected_worlds[node]);
                Mat4 actual = extracted_instance.present_node(node).world;
                foreach (corner : corners) {
                    Vec3 point = { (float)corner.x, (float)corner.y, (float)corner.z };
                    Vec3 actual_point = maths::transform_point(actual, point);
                    double[<3>] observed = { actual_point.x, actual_point.y, actual_point.z };
                    assert((observed - motion_test_point(expected, corner)).length() <= GENERALIZED_POINT_EPSILON);
                }
            }
            assert(extracted.inertial_storage == null && extracted.pose_storage.scratch.inertial == null);
            assert(allocator.acquisitions == acquisitions && allocator.resizes == resizes);
        }
        RootMotionDelta previous = extracted.root_motion;
        anim::update(&assets, &scene, 0);
        assert(extracted.root_motion.translation == (Vec3){});
        assert(extracted.root_motion.rotation.v == (Vec4){ 0, 0, 0, 1 });
        assert(previous.translation.length() > 0 || previous.rotation.v != (Vec4){ 0, 0, 0, 1 });
    }
}

fn void playback_test_owner_world_snapshot(Scene* scene, Node* owner, Mat4[] snapshot) @local {
    scene.update_world();
    ModelInstance* instance = scene.get(owner, ModelInstance);
    foreach (index, &world : snapshot) *world = instance.present_node((uint)index).world;
}

fn void playback_test_owner_world_unchanged(Scene* scene, Node* owner, Mat4[] expected) @local {
    scene.update_world();
    ModelInstance* instance = scene.get(owner, ModelInstance);
    Vec3[4] corners = { {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
    foreach (index, reference : expected) {
        Mat4 actual = instance.present_node((uint)index).world;
        foreach (corner : corners) {
            assert((maths::transform_point(actual, corner) - maths::transform_point(reference, corner)).length()
              <= (float)GENERALIZED_POINT_EPSILON);
        }
    }
}

fn void test_animation_generalized_playback_request_onset_after_consumption_preserves_displayed_worlds() @test {
    GeneralizedPlaybackFixture fixture;
    create_generalized_playback_fixture(&fixture, {
        .generalized = true,
        .translation_axes = { true, true, true },
        .up = (Vec3){ 1, 2, 3 }.normalize(),
        .twist = true,
    });
    defer destroy_generalized_playback_fixture(&fixture);
    AssetStore assets = asset::create_asset_store(mem, {
        .max_geometries = 1,
        .max_textures = 8,
        .max_materials = 1,
        .max_samplers = 8,
        .max_models = 1,
        .max_skeletons = 1,
        .max_clips = 2,
    });
    defer asset::destroy_asset_store(&assets);
    ModelTemplate template = { .nodes = alloc::new_array(mem, NodeTemplate, fixture.nodes.len) };
    template.nodes[..] = fixture.nodes[..];
    foreach (&node : template.nodes) node.name = node.name.copy(mem);
    ModelId model_id = assets.add_model_owned(&template)!!;
    AnimationClip source_clip = playback_test_owned_clip(&fixture);
    AnimationClip target_clip = playback_test_owned_clip(&fixture);
    target_clip.tracks[0].values[..] = ((float[6]){ -0.2f, 0.4f, 0.3f, 0.1f, 0.7f, 0.6f })[..];
    target_clip.tracks[3].values[..] = ((float[6]){ -1, 0.5f, 1, -0.2f, 0.7f, 1.3f })[..];
    Quat initial = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.25f)
      .mul(quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.1f));
    Quat final = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.7f)
      .mul(quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.1f));
    target_clip.tracks[4].values[..] = ((float[8]){
        initial.v.x, initial.v.y, initial.v.z, initial.v.w, final.v.x, final.v.y, final.v.z, final.v.w,
    })[..];
    ClipId source_id = assets.add_clip_owned(&source_clip)!!;
    ClipId target_id = assets.add_clip_owned(&target_clip)!!;
    Scene scene = scene::create_scene(mem, { .max_nodes = 12 });
    defer scene::destroy_scene(&scene);
    Node* owner = model::instantiate(&assets, &scene, model_id)!!;
    Animator* animator = anim::add_animator(&scene, owner, { .inertia_enabled = true });
    animator.root_node = 2;
    animator.play(
        assets: &assets,
        clip: source_id,
        desc: { .root_motion = RootMotion.EXTRACT, .extraction = fixture.extraction },
    )!!;
    for (uint frame = 0; frame < 3; frame++) {
        anim::update(&assets, &scene, 0.125f);
        anim::apply_root_motion(owner, animator.root_motion);
    }
    assert(owner.local.position.length() > 0.1f);
    Mat4[5] source_worlds;
    playback_test_owner_world_snapshot(&scene, owner, source_worlds[..]);
    double previous_dt = animator.inertial_storage.rows[0].control.previous_dt;
    AnimationTargetDesc[1] targets = { {
        .clip = target_id,
        .play = { .root_motion = RootMotion.EXTRACT, .extraction = fixture.extraction },
        .start_time = 0.375f,
        .speed = 1,
        .weight = 1,
        .loop = true,
        .playing = true,
    } };
    animator.inertialize(&assets, { .duration = 0.5f, .actions = targets[..] })!!;
    playback_test_owner_world_unchanged(&scene, owner, source_worlds[..]);
    for (uint zero_step = 0; zero_step < 3; zero_step++) {
        anim::update(&assets, &scene, 0);
        assert(animator.root_motion.translation == (Vec3){});
        assert(animator.root_motion.rotation.v == (Vec4){ 0, 0, 0, 1 });
        playback_test_owner_world_unchanged(&scene, owner, source_worlds[..]);
        assert(animator.inertial_storage.rows[0].control.previous_dt == previous_dt);
        assert(animator.inertial_storage.rows[0].control.elapsed == 0);
    }
    for (uint frame = 0; frame < 3; frame++) {
        anim::update(&assets, &scene, 0.0625f);
        anim::apply_root_motion(owner, animator.root_motion);
    }
    playback_test_owner_world_snapshot(&scene, owner, source_worlds[..]);
    targets[0].start_time = 0.625f;
    targets[0].speed = -1;
    animator.inertialize(&assets, { .duration = 0.25f, .actions = targets[..] })!!;
    playback_test_owner_world_unchanged(&scene, owner, source_worlds[..]);
    anim::update(&assets, &scene, 0);
    playback_test_owner_world_unchanged(&scene, owner, source_worlds[..]);
}

fn PlayDesc carrier_test_desc() @local {
    return {
        .root_motion = RootMotion.EXTRACT,
        .extraction = { .generalized = true, .translation_axes = { true, false, true }, .up = { 0, 1, 0 } },
    };
}

fn ClipId carrier_test_clip(LayerFixture* fixture, float stride) @local {
    return inertial_owner_translation(
        owner: fixture,
        start: { 0, 0, 0 },
        end: { 0, 0, stride },
        node: 2,
    );
}

fn Vec3 carrier_test_skeleton_offset(LayerFixture* fixture) @local {
    fixture.scene.update_world();
    ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
    Vec3 skeleton = maths::transform_point(instance.present_node(2).world, {});
    return skeleton - maths::transform_point(fixture.root.world, {});
}

fn void carrier_test_advance(LayerFixture* fixture, uint frames) @local {
    for (uint frame = 0; frame < frames; frame++) {
        anim::update(&fixture.assets, &fixture.scene, 0.125f);
        anim::apply_root_motion(fixture.root, fixture.animator.root_motion);
    }
}

fn void test_animation_generalized_playback_fade_keeps_skeleton_on_carrier() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture, inertia_enabled: false);
    defer destroy_layer_fixture(&fixture);
    fixture.animator.root_node = 2;
    ClipId walk = carrier_test_clip(&fixture, 2);
    ClipId run = carrier_test_clip(&fixture, 4);
    AnimationActionId walking = fixture.animator.play(&fixture.assets, walk, carrier_test_desc())!!;
    carrier_test_advance(&fixture, 4);
    Vec3 pinned = carrier_test_skeleton_offset(&fixture);
    carrier_test_advance(&fixture, 76);

    PlayDesc fade = carrier_test_desc();
    fade.fade_in = 1;
    fixture.animator.play(&fixture.assets, run, fade)!!;
    fixture.animator.stop(walking, 1)!!;
    carrier_test_advance(&fixture, 10);

    assert(fixture.root.local.position.z > 20);
    assert((carrier_test_skeleton_offset(&fixture) - pinned).length() < 1e-3f);
}

fn void test_animation_generalized_playback_partial_weight_keeps_skeleton_across_loops() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture, inertia_enabled: false);
    defer destroy_layer_fixture(&fixture);
    fixture.animator.root_node = 2;
    ClipId walk = carrier_test_clip(&fixture, 2);
    AnimationActionId id = fixture.animator.play(&fixture.assets, walk, carrier_test_desc())!!;
    Action* action = fixture.animator.action(id);
    action.weight = 0.5f;
    action.fade_target = 0.5f;
    carrier_test_advance(&fixture, 1);
    Vec3 pinned = carrier_test_skeleton_offset(&fixture);

    for (uint frame = 0; frame < 12; frame++) {
        carrier_test_advance(&fixture, 1);
        assert((carrier_test_skeleton_offset(&fixture) - pinned).length() < 1e-4f);
    }
}

fn void test_animation_generalized_inertial_request_keeps_skeleton_on_carrier() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    fixture.animator.root_node = 2;
    ClipId walk = carrier_test_clip(&fixture, 2);
    ClipId run = carrier_test_clip(&fixture, 4);
    fixture.animator.play(&fixture.assets, walk, carrier_test_desc())!!;
    carrier_test_advance(&fixture, 8);
    Vec3 pinned = carrier_test_skeleton_offset(&fixture);

    AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
    targets[0].clip = run;
    targets[0].play = carrier_test_desc();
    fixture.animator.inertialize(&fixture.assets, { .duration = 0.5f, .actions = targets[..] })!!;
    carrier_test_advance(&fixture, 12);

    assert(!fixture.animator.inertial_status().active);
    assert((carrier_test_skeleton_offset(&fixture) - pinned).length() < 1e-3f);
}

fn void test_animation_generalized_inertial_request_onset_rates_exclude_extracted_motion() @test {
    LayerFixture fixture;
    create_inertial_owner(&fixture);
    defer destroy_layer_fixture(&fixture);
    fixture.animator.root_node = 2;
    Quat turned = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.5f);
    float[2] times = { 0, 1 };
    float[6] positions = { 0.5f, 0, 0, 0.5f, 0, 2 };
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
            target: 1,
        ),
    };
    uint[2] targets = { 2, 2 };
    ClipId walk = add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
    PlayDesc desc = carrier_test_desc();
    desc.extraction.twist = true;
    fixture.animator.play(&fixture.assets, walk, desc)!!;
    for (uint frame = 0; frame < 12; frame++) anim::update(&fixture.assets, &fixture.scene, 0.03125f);

    AnimationTargetDesc[1] request = { anim::ANIMATION_TARGET_DEFAULT };
    request[0].clip = walk;
    request[0].play = desc;
    request[0].start_time = 0.375f;
    fixture.animator.inertialize(&fixture.assets, { .duration = 0.5f, .actions = request[..] })!!;

    foreach (rate : inertial_owner_row(&fixture).offset_velocity) {
        assert(rate.translation.length() < 0.05 && rate.angular.length() < 0.05);
    }
}
