module c3d::test::motion_admission;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import std::math;

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
    UNPROVEN_QUATERNION,
    UNPROVEN_QUATERNION_AND_NONUNIFORM_BASELINE,
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

struct MotionCaptureAllocator (Allocator) @local {
    Allocator backing;
    uint acquisitions;
    uint failure;
    uint outstanding;
}

fn void*? MotionCaptureAllocator.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    if (++self.acquisitions == self.failure) return mem::OUT_OF_MEMORY~;
    void* pointer = self.backing.acquire(size, init_type, alignment)!;
    self.outstanding++;
    return pointer;
}

fn void*? MotionCaptureAllocator.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    if (++self.acquisitions == self.failure) return mem::OUT_OF_MEMORY~;
    return self.backing.resize(pointer, size, alignment);
}

fn void MotionCaptureAllocator.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
    self.outstanding--;
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
            case UNPROVEN_QUATERNION:
            case UNPROVEN_QUATERNION_AND_NONUNIFORM_BASELINE:
                fixture.tracks[3].interpolation = Interpolation.CUBIC_SPLINE;
                fixture.tracks[3].times = times[..];
                fixture.tracks[3].values = rotations[..];
                if (mutation == ZERO_QUATERNION) break;
                rotations[4] = rotations[16] = 1e-12;
                if (mutation == UNPROVEN_QUATERNION) {
                    expected = c3d::UNSUPPORTED;
                } else {
                    fixture.nodes[0].local.scale = { 1, 2, 1 };
                }
        }
        assert(@catch(validate_admission_fixture(&fixture, root)) == expected);
    }
}

fn void test_animation_motion_admission_sampling_margin_defers_to_exact_faults() @test {
    MotionAdmissionFixture fixture;
    create_motion_admission_fixture(&fixture);
    float[2] times = { 0x1p-149, 1 };
    float[18] values = { 0, 0, 0, 1, 1, 1, -4, -4, -4, 4, 4, 4, 1, 1, 1, 0, 0, 0 };
    fixture.tracks[4].interpolation = Interpolation.CUBIC_SPLINE;
    fixture.tracks[4].times = times[..];
    fixture.tracks[4].values = values[..];
    assert(@catch(validate_admission_fixture(&fixture)) == c3d::UNSUPPORTED);
    fixture.nodes[0].local.scale = { 1, 2, 1 };
    assert(@catch(validate_admission_fixture(&fixture)) == c3d::INVALID_ARGUMENT);
    fixture.nodes[0].local.scale = { 2, 2, 2 };
    fixture.tracks[2].values = fixture.excluded_scales[..];
    assert(@catch(validate_admission_fixture(&fixture)) == c3d::INVALID_ARGUMENT);
    fixture.tracks[2].values = fixture.scales[..];
    times[0] = 0;
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
    MotionCaptureAllocator allocator = { .backing = &tracker };
    MotionAdmissionFixture fixture;
    create_motion_admission_fixture(&fixture);
    uint acquisitions;
    {
        CapturedMotionChain completed = capture_admission_fixture(&fixture, &allocator);
        defer anim::destroy_captured_motion_chain(&completed);
        acquisitions = allocator.acquisitions;
        assert(acquisitions > 0);
    }
    assert(allocator.outstanding == 0 && !tracker.has_leaks());
    for (uint failure = 1; failure <= acquisitions; failure++) {
        allocator.acquisitions = 0;
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
        assert(caught && allocator.acquisitions == failure);
        assert(allocator.outstanding == 0 && !tracker.has_leaks());
        assert(fixture.nodes[1].parent == 0 && fixture.nodes[0].name == "base");
        assert(fixture.targets[4] == 2 && fixture.tracks[4].values.ptr == &fixture.scales[0]);
    }
    allocator.acquisitions = 0;
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
    assert(caught && allocator.acquisitions == 0 && allocator.outstanding == 0);
}
