module c3d::test::anim;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import std::math;

fn RootExtractionDesc transition_admission_extraction() @local {
    return { .generalized = true, .translation_axes = { true, true, true }, .up = { 0, 1, 0 }, .twist = true };
}

fn ClipId transition_admission_translation(LayerFixture* fixture, Vec3 start) @local {
    float[2] times = { 0, 1 };
    float[6] values = { start.x, start.y, start.z, start.x + 1, start.y + 2, start.z + 3 };
    Track[1] tracks = { make_track(
        path: TRANSLATION,
        interpolation: LINEAR,
        times: times[..],
        values: values[..],
    ) };
    uint[1] targets = { 2 };
    return add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
}

fn ClipId transition_admission_scale(LayerFixture* fixture, Vec3 start, Vec3 end) @local {
    float[2] times = { 0, 1 };
    float[6] values = { start.x, start.y, start.z, end.x, end.y, end.z };
    Track[1] tracks = { make_track(
        path: SCALE,
        interpolation: LINEAR,
        times: times[..],
        values: values[..],
    ) };
    uint[1] targets = { 2 };
    return add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
}

fn AnimationActionId initialize_transition_admission_source(LayerFixture* fixture, TrackingAllocator* tracker) @local {
    create_layer_fixture(fixture, tracker);
    ClipId clip = transition_admission_translation(fixture, {});
    AnimationActionId action = fixture.animator.play(&fixture.assets, clip, {
        .root_motion = EXTRACT,
        .extraction = transition_admission_extraction(),
    })!!;
    anim::update(&fixture.assets, &fixture.scene, 0);
    return action;
}

fn void test_animation_transition_admission_reference_offsets_and_animated_basis_are_allowed() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    LayerFixture fixture;
    initialize_transition_admission_source(&fixture, &tracker);
    defer destroy_layer_fixture(&fixture);
    ClipId target_clip = transition_admission_translation(&fixture, { 5, 7, -3 });
    AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
    targets[0].clip = target_clip;
    targets[0].play = { .root_motion = EXTRACT, .extraction = transition_admission_extraction() };
    PlaybackView playback = fixture.animator.playback();
    MotionBasis basis = anim::animator_motion_basis(fixture.animator);
    basis.basis.m03 += 9;
    sz acquisitions = tracker.total_allocation_count();
    TransitionMotionIdentity identity = anim::validate_transition_motion_identity(
        playback: &playback,
        assets: &fixture.assets,
        desc: { .duration = 0.5f, .actions = targets[..] },
        destination: fixture.animator.pose_storage.destination,
        motion_basis: basis,
    )!!;
    assert(identity.consumes_chain && !identity.unsupported && identity.root_node == 2);
    assert(identity.extraction.up == (Vec3){ 0, 1, 0 });
    assert(tracker.total_allocation_count() == acquisitions);
}

fn void test_animation_transition_admission_configuration_model_layout_and_frame_mismatches_are_atomic() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    LayerFixture fixture;
    AnimationActionId id = initialize_transition_admission_source(&fixture, &tracker);
    defer destroy_layer_fixture(&fixture);
    ClipId target_clip = transition_admission_translation(&fixture, { 5, 7, -3 });
    Action* source = fixture.animator.action(id);
    CapturedMotionChain* captured = source.motion_chain;
    AnimationTargetDesc[1] targets;
    for (uint mismatch = 0; mismatch < 8; mismatch++) {
        targets[0] = anim::ANIMATION_TARGET_DEFAULT;
        targets[0].clip = target_clip;
        targets[0].play = { .root_motion = EXTRACT, .extraction = transition_admission_extraction() };
        PlaybackView playback = fixture.animator.playback();
        MotionBasis basis = anim::animator_motion_basis(fixture.animator);
        ModelId model = captured.model;
        int parent = captured.model_parents[3];
        char name_start = captured.model_names[3][0];
        switch (mismatch) {
            case 0: targets[0].play.extraction.up = { 1, 0, 0 };
            case 1: targets[0].play.extraction.translation_axes[1] = false;
            case 2: targets[0].play.extraction.twist = false;
            case 3: playback.root_node = 3;
            case 4: basis.instance_scale = { 2, 2, 2 };
            case 5: captured.model.index++;
            case 6: captured.model_parents[3] = 0;
            case 7: captured.model_names[3][0] = 'X';
        }
        Action unchanged = *source;
        uint count = fixture.animator.action_count;
        uint generation = fixture.animator.actions.generations[id.index];
        sz acquisitions = tracker.total_allocation_count();
        assert(@catch(anim::validate_transition_motion_identity(
            playback: &playback,
            assets: &fixture.assets,
            desc: { .duration = 0.5f, .actions = targets[..] },
            destination: fixture.animator.pose_storage.destination,
            motion_basis: basis,
        )) == c3d::INVALID_ARGUMENT);
        assert(tracker.total_allocation_count() == acquisitions);
        assert(fixture.animator.action_count == count && fixture.animator.actions.generations[id.index] == generation);
        assert(mem::equals(&unchanged, source, Action::size));
        captured.model = model;
        captured.model_parents[3] = parent;
        captured.model_names[3][0] = name_start;
    }
}

fn void test_animation_transition_admission_invalid_source_pose_and_morph_fault_without_allocating() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    LayerFixture fixture;
    AnimationActionId id = initialize_transition_admission_source(&fixture, &tracker);
    defer destroy_layer_fixture(&fixture);
    PlaybackView playback = fixture.animator.playback();
    PoseDestination destination = fixture.animator.pose_storage.destination;
    Transform pose = destination.pose[3];
    float morph = destination.morph_weights[0][0];
    for (uint invalid = 0; invalid < 4; invalid++) {
        switch (invalid) {
            case 0: destination.pose[3].rotation = {};
            case 1: destination.pose[3].position.x = float::inf;
            case 2: destination.pose[3].scale.z = float::nan;
            case 3: destination.morph_weights[0][0] = float::nan;
        }
        Action unchanged = *fixture.animator.action(id);
        sz acquisitions = tracker.total_allocation_count();
        assert(@catch(anim::validate_transition_motion_identity(
            playback: &playback,
            assets: &fixture.assets,
            desc: { .duration = 0.5f },
            destination: destination,
            motion_basis: anim::animator_motion_basis(fixture.animator),
        )) == c3d::INVALID_ARGUMENT);
        assert(tracker.total_allocation_count() == acquisitions);
        assert(mem::equals(&unchanged, fixture.animator.action(id), Action::size));
        destination.pose[3] = pose;
        destination.morph_weights[0][0] = morph;
    }
}

fn void test_animation_transition_admission_additive_scale_neutrality_ignores_zero_contribution() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    LayerFixture fixture;
    initialize_transition_admission_source(&fixture, &tracker);
    defer destroy_layer_fixture(&fixture);
    ClipId nonneutral = transition_admission_scale(&fixture, { 1, 1, 1 }, { 2, 2, 2 });
    ClipId neutral = transition_admission_scale(&fixture, { 2, 4, 8 }, { 2, 4, 8 });
    bool[4] excluded;
    JointMask mask = { .nodes = excluded[..] };
    PlaybackView playback = fixture.animator.playback();
    foreach (mode : (AdditiveScaleMode[2]){ DIFFERENCE, MULTIPLICATIVE }) {
        AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
        targets[0].clip = nonneutral;
        targets[0].weight = 0;
        targets[0].play = { .additive = true, .mask = &mask, .additive_scale = mode };
        sz acquisitions = tracker.total_allocation_count();
        assert(@catch(anim::validate_transition_motion_identity(
            playback: &playback,
            assets: &fixture.assets,
            desc: { .duration = 0.5f, .actions = targets[..] },
            destination: fixture.animator.pose_storage.destination,
            motion_basis: anim::animator_motion_basis(fixture.animator),
        )) == c3d::INVALID_ARGUMENT);
        targets[0].clip = neutral;
        TransitionMotionIdentity accepted = anim::validate_transition_motion_identity(
            playback: &playback,
            assets: &fixture.assets,
            desc: { .duration = 0.5f, .actions = targets[..] },
            destination: fixture.animator.pose_storage.destination,
            motion_basis: anim::animator_motion_basis(fixture.animator),
        )!!;
        assert(accepted.consumes_chain && !accepted.unsupported);
        assert(tracker.total_allocation_count() == acquisitions);
    }
}
