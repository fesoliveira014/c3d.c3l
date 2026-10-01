module c3d::test::anim;

import c3d;
import c3d::anim;
import c3d::anim::retarget;
import c3d::asset;
import c3d::asset::gltf;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::math;

fn ClipId motion_clip(
    LayerFixture* fixture,
    Vec3 displacement,
    float yaw = 0,
    float duration = 1,
) @local {
    float[2] times = { 0, duration };
    float[6] positions = { 0, 0, 0, displacement.x, displacement.y, displacement.z };
    Quat turn = quaternion::from_axis_angle{float}({ 0, 1, 0 }, yaw);
    float[8] rotations = { 0, 0, 0, 1, turn.v.x, turn.v.y, turn.v.z, turn.v.w };
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
    uint[1] targets = { 2 };
    return add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: duration,
    );
}

fn void check_events(Animator* animator, uint[] expected) @local {
    assert(animator.event_count == expected.len);
    foreach (index, value : expected) assert(animator.events[index].id == value);
}

fn void test_root_motion_selects_pins_and_accumulates_translation() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    assert(fixture.animator.root_node == 2);
    ClipId clip = motion_clip(&fixture, { 3, 1, 4 });
    AnimationActionId id = fixture.animator.play(&fixture.assets, clip, { .root_motion = RootMotion.EXTRACT })!!;
    Vec3 sum;

    for (uint frame = 0; frame < 4; frame++) {
        anim::update(&fixture.assets, &fixture.scene, 0.25f);
        Vec3 delta = fixture.animator.root_motion.translation;
        assert((delta - (Vec3){ 0.75f, 0, 1 }).length() < 1e-4f);
        sum += delta;
        Node* root = fixture.animator.nodes[2];
        assert(approx(root.local.position.x, 0) && approx(root.local.position.z, 0));
    }
    assert((sum - (Vec3){ 3, 0, 4 }).length() < 1e-4f);
    fixture.animator.action(id).time = 0.8f;
    anim::update(&fixture.assets, &fixture.scene, 0.4f);
    assert((fixture.animator.root_motion.translation - (Vec3){ 1.2f, 0, 1.6f }).length() < 1e-4f);
    assert(approx(fixture.animator.nodes[2].local.position.y, 0.2f));
}

fn void test_keep_strip_and_invalid_root_modes() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    ClipId clip = motion_clip(&fixture, { 3, 1, 4 });
    AnimationActionId kept = fixture.animator.play(&fixture.assets, clip)!!;
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    assert((fixture.animator.nodes[2].local.position - (Vec3){ 0.75f, 0.25f, 1 }).length() < 1e-4f);
    assert(fixture.animator.root_motion.translation == (Vec3){});
    fixture.animator.stop(kept)!!;

    AnimationActionId stripped = fixture.animator.play(&fixture.assets, clip, { .root_motion = RootMotion.STRIP_XZ })!!;
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    assert((fixture.animator.nodes[2].local.position - (Vec3){ 0, 0.25f, 0 }).length() < 1e-4f);
    assert(fixture.animator.root_motion.translation == (Vec3){});
    fixture.animator.stop(stripped)!!;

    if (catch excuse = fixture.animator.play(&fixture.assets, clip, { .root_yaw = true })) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    if (catch excuse = fixture.animator.play(
        assets: &fixture.assets,
        clip: clip,
        desc: { .root_motion = RootMotion.EXTRACT, .additive = true },
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    fixture.animator.root_node = anim::NO_ROOT_NODE;
    if (catch excuse = fixture.animator.play(&fixture.assets, clip, { .root_motion = RootMotion.EXTRACT })) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    assert(fixture.animator.action_count == 0);
}

fn void test_root_yaw_preserves_tilt_and_twist_handles_half_turn() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    Quat tilt = quaternion::from_axis_angle{float}({ 1, 0, 0 }, (float)math::PI / 6);
    Quat end = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI / 2).mul(tilt);
    float[2] times = { 0, 1 };
    float[8] values = { tilt.v.x, tilt.v.y, tilt.v.z, tilt.v.w, end.v.x, end.v.y, end.v.z, end.v.w };
    Track[1] tracks = {
        make_track(
            path: TargetPath.ROTATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: values[..],
        ),
    };
    uint[1] targets = { 2 };
    ClipId clip = add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
    fixture.animator.play(&fixture.assets, clip, { .root_motion = RootMotion.EXTRACT, .root_yaw = true })!!;
    anim::update(&fixture.assets, &fixture.scene, 0.5f);

    assert(math::abs(fixture.animator.nodes[2].local.rotation.v.dot(tilt.v)) > 0.99999f);
    assert(rotates_x_to(fixture.animator.root_motion.rotation, { 0.7071068f, 0, -0.7071068f }));
    Quat half_turn = quaternion::from_axis_angle{float}({ 1, 0, 0 }, (float)math::PI);
    assert(rotates_x_to(maths::twist_about(half_turn, { 0, 1, 0 }), { 1, 0, 0 }));
}

fn void test_planar_motion_composes_across_substeps_cycles_and_reverse() @test {
    Transform[3] results;
    for (uint variant = 0; variant < 3; variant++) {
        LayerFixture fixture;
        create_layer_fixture(&fixture);
        defer destroy_layer_fixture(&fixture);

        ClipId clip = motion_clip(fixture: &fixture, displacement: { 0, 0, 2 }, yaw: (float)math::PI / 2);
        AnimationActionId id = fixture.animator.play(
            assets: &fixture.assets,
            clip: clip,
            desc: { .root_motion = RootMotion.EXTRACT, .root_yaw = true },
        )!!;
        if (variant == 2) fixture.animator.action(id).speed = -1;
        uint count = variant == 0 ? 1 : 20;
        for (uint step = 0; step < count; step++) {
            anim::update(&fixture.assets, &fixture.scene, 2.0f / count);
            anim::apply_root_motion(fixture.root, fixture.animator.root_motion);
        }
        results[variant] = fixture.root.local;
    }
    assert((results[0].position - results[1].position).length() < 1e-4f);
    assert(math::abs(results[0].rotation.v.dot(results[1].rotation.v)) > 0.99999f);
    Vec3 restored = results[0].position + results[0].rotation.rotate_vec3(results[2].position);
    assert(restored.length() < 1e-4f);
    assert(rotates_x_to(results[0].rotation.mul(results[2].rotation), { 1, 0, 0 }));
}

fn void test_root_motion_respects_weights_layers_and_masks() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    ClipId clip = motion_clip(&fixture, { 4, 0, 0 });
    AnimationActionId base = fixture.animator.play(&fixture.assets, clip, { .root_motion = RootMotion.EXTRACT })!!;
    fixture.animator.action(base).weight = 0.5f;
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    assert(approx(fixture.animator.root_motion.translation.x, 0.5f));

    AnimationActionId upper = fixture.animator.play(&fixture.assets, clip, { .layer = 1 })!!;
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    assert(fixture.animator.root_motion.translation.length() < 1e-5f);
    fixture.animator.stop(upper)!!;
    fixture.animator.stop(base)!!;

    String[1] names = { "joint_tip" };
    JointMask mask = anim::create_joint_mask(mem, &fixture.assets.model(fixture.model).data, names[..])!!;
    defer anim::destroy_joint_mask(&mask);
    fixture.animator.play(&fixture.assets, clip, { .root_motion = RootMotion.EXTRACT, .mask = &mask })!!;
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    assert(fixture.animator.root_motion.translation.length() < 1e-5f);
}

fn void test_motion_consumption_and_twist_use_the_authored_frame() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    fixture.root.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI / 2);
    anim::apply_root_motion(fixture.root, {
        .translation = { 1, 0, 0 },
        .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI / 18),
    });
    assert((fixture.root.local.position - (Vec3){ 0, 0, -1 }).length() < 1e-5f);
    assert(rotates_x_to(fixture.root.local.rotation, { -0.1736482f, 0, -0.9848077f }));

    Quat tilt = quaternion::from_axis_angle{float}({ 1, 0, 0 }, (float)math::PI / 6);
    Quat yaw = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI / 4);
    Quat rotation = yaw.mul(tilt);
    Quat twist = maths::twist_about(rotation, { 0, 1, 0 });
    assert(math::abs(twist.v.dot(yaw.v)) > 0.99999f);
    assert(math::abs(twist.conjugate().mul(rotation).v.dot(tilt.v)) > 0.99999f);
}

fn void test_root_motion_averages_full_weight_extractors() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    ClipId horizontal = motion_clip(&fixture, { 4, 0, 0 });
    ClipId forward = motion_clip(&fixture, { 0, 0, 4 });
    fixture.animator.play(&fixture.assets, horizontal, { .root_motion = RootMotion.EXTRACT })!!;
    fixture.animator.play(&fixture.assets, forward, { .root_motion = RootMotion.EXTRACT })!!;
    anim::update(&fixture.assets, &fixture.scene, 0.5f);
    assert((fixture.animator.root_motion.translation - (Vec3){ 1, 0, 1 }).length() < 1e-5f);
}

fn void test_event_table_sort_validation_and_retarget_copy() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    ClipId clip = motion_clip(&fixture, { 1, 0, 0 });
    ClipEvent[4] events = {
        { .time = 0.9f, .id = 3 },
        { .time = 0, .id = 1 },
        { .time = 0.5f, .id = 2 },
        { .time = 0.5f, .id = 4 },
    };
    fixture.assets.set_clip_events(clip, events[..])!!;
    AnimationClip* source = &fixture.assets.clip(clip).data;
    assert(source.events[0].id == 1 && source.events[1].id == 2);
    assert(source.events[2].id == 4 && source.events[3].id == 3);
    ClipEvent* previous = source.events.ptr;
    float[3] invalid = { -1, 1.5f, bitcast(0x7fc00000u, float) };
    foreach (time : invalid) {
        ClipEvent[1] bad = { { .time = time } };
        if (catch excuse = fixture.assets.set_clip_events(clip, bad[..])) {
            assert(excuse == c3d::INVALID_ARGUMENT);
        } else {
        assert(false);
    }
        assert(source.events.ptr == previous && source.events[0].id == 1);
    }
    if (catch excuse = fixture.assets.set_clip_events((ClipId){}, {})) {
        assert(excuse == c3d::INVALID_ID);
    } else {
        assert(false);
    }

    ModelTemplate* template = &fixture.assets.model(fixture.model).data;
    AnimationClip copy = retarget::retarget_by_name(
        allocator: mem,
        source: source,
        source_nodes: template.nodes,
        target: template,
    )!!;
    defer asset::free_clip(mem, &copy);
    assert(copy.events.len == 4 && copy.events.ptr != source.events.ptr);
    copy.events[0].id = 99;
    assert(source.events[0].id == 1);

    RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
    options.rest_pose = RestPose.CORRECT;
    AnimationClip corrected = retarget::retarget_by_name(
        allocator: mem,
        source: source,
        source_nodes: template.nodes,
        target: template,
        options: options,
    )!!;
    defer asset::free_clip(mem, &corrected);
    assert(corrected.events.len == source.events.len && corrected.events.ptr != source.events.ptr);
}

fn void test_event_forward_sweep_pause_and_seek_rebase() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    ClipId clip = motion_clip(&fixture, { 1, 0, 0 });
    ClipEvent[3] events = { { .time = 0, .id = 1 }, { .time = 0.5f, .id = 2 }, { .time = 0.9f, .id = 3 } };
    fixture.assets.set_clip_events(clip, events[..])!!;
    AnimationActionId id = fixture.animator.play(&fixture.assets, clip)!!;
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    check_events(fixture.animator, { 1 });
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    check_events(fixture.animator, {});
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    check_events(fixture.animator, { 2 });
    anim::update(&fixture.assets, &fixture.scene, 0.5f);
    check_events(fixture.animator, { 3, 1 });

    fixture.animator.action(id).playing = false;
    anim::update(&fixture.assets, &fixture.scene, 0.3f);
    check_events(fixture.animator, {});
    fixture.animator.action(id).time = 0.8f;
    fixture.animator.action(id).playing = true;
    anim::update(&fixture.assets, &fixture.scene, 0);
    check_events(fixture.animator, {});
    anim::update(&fixture.assets, &fixture.scene, 0.15f);
    check_events(fixture.animator, { 3 });
}

fn void test_event_seams_reverse_and_nonloop_endpoints() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    ClipId clip = motion_clip(&fixture, { 1, 0, 0 });
    ClipEvent[3] events = { { .time = 0, .id = 1 }, { .time = 0.5f, .id = 2 }, { .time = 1, .id = 3 } };
    fixture.assets.set_clip_events(clip, events[..])!!;
    AnimationActionId id = fixture.animator.play(&fixture.assets, clip)!!;
    anim::update(&fixture.assets, &fixture.scene, 1);
    check_events(fixture.animator, { 1, 2, 3 });
    anim::update(&fixture.assets, &fixture.scene, 0.1f);
    check_events(fixture.animator, { 1 });
    fixture.animator.action(id).time = 0.25f;
    fixture.animator.action(id).speed = -1;
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    check_events(fixture.animator, { 1 });
    anim::update(&fixture.assets, &fixture.scene, 0.1f);
    check_events(fixture.animator, { 3 });
    fixture.animator.action(id).time = 0.1f;
    anim::update(&fixture.assets, &fixture.scene, 0.2f);
    check_events(fixture.animator, { 1, 3 });

    fixture.animator.action(id).time = 0.75f;
    fixture.animator.action(id).speed = 1;
    fixture.animator.action(id).loop = false;
    anim::update(&fixture.assets, &fixture.scene, 2);
    check_events(fixture.animator, { 3 });
    anim::update(&fixture.assets, &fixture.scene, 2);
    check_events(fixture.animator, {});
}

fn void test_many_event_loops_are_bounded_and_count_drops() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    ClipId clip = motion_clip(&fixture, { 1, 0, 0 });
    ClipEvent[1] event = { { .time = 0.25f, .id = 7 } };
    fixture.assets.set_clip_events(clip, event[..])!!;
    AnimationActionId id = fixture.animator.play(&fixture.assets, clip)!!;
    anim::update(&fixture.assets, &fixture.scene, 3);
    check_events(fixture.animator, { 7, 7, 7 });
    anim::update(&fixture.assets, &fixture.scene, 1_000_000);
    assert(fixture.animator.event_count == anim::MAX_FIRED_EVENTS);
    assert(fixture.animator.events_dropped == 1_000_000 - anim::MAX_FIRED_EVENTS);

    ClipEvent[20] many;
    foreach (uint index, &value : many) *value = { .time = (float)index / 40, .id = index };
    fixture.assets.set_clip_events(clip, many[..])!!;
    fixture.animator.action(id).time = 0;
    anim::update(&fixture.assets, &fixture.scene, 1);
    assert(fixture.animator.event_count == 16 && fixture.animator.events_dropped == 4);
    for (uint index = 0; index < 16; index++) assert(fixture.animator.events[index].id == index);
}

fn void test_event_fractional_steps_do_not_skip_loop_boundary() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    ClipId clip = motion_clip(&fixture, { 1, 0, 0 });
    ClipEvent[1] end = { { .time = 1, .id = 1 } };
    fixture.assets.set_clip_events(clip, end[..])!!;
    fixture.animator.play(&fixture.assets, clip)!!;
    uint count;
    for (uint frame = 0; frame < 100; frame++) {
        anim::update(&fixture.assets, &fixture.scene, 0.1f);
        count += fixture.animator.event_count;
    }
    assert(count == 10);
}

fn void test_blend_space_weights_phase_pause_and_member_ownership() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    ClipId[2] clips = { layer_translation(&fixture, { 0, 2, 0 }), layer_translation(&fixture, { 0, 6, 0 }) };
    fixture.assets.clip(clips[1]).data.duration = 0.5f;
    float[2] positions = { 0, 1 };
    BlendSpace1D* space = fixture.animator.add_blend_space(&fixture.assets, clips[..], positions[..])!!;
    space.parameter = 0.25f;
    anim::update(&fixture.assets, &fixture.scene, 0);
    assert(approx(fixture.animator.nodes[3].local.position.y, 3));
    space.parameter = 0.5f;
    anim::update(&fixture.assets, &fixture.scene, 0.375f);
    assert(math::abs(space.phase - 0.5) < 1e-6);
    assert(approx(fixture.animator.action(space.actions[0]).time, 0.5f));
    assert(approx(fixture.animator.action(space.actions[1]).time, 0.25f));
    anim::update(&fixture.assets, &fixture.scene, 0.75f);
    assert(math::abs(space.phase - 0.5) < 1e-6);

    if (catch excuse = fixture.animator.stop(space.actions[0])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    if (catch excuse = fixture.animator.cross_fade(space.actions[0], space.actions[1], 1)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }

    space.playing = false;
    space.parameter = 2;
    anim::update(&fixture.assets, &fixture.scene, 1);
    assert(approx(fixture.animator.nodes[3].local.position.y, 6));
    assert(math::abs(space.phase - 0.5) < 1e-6);
    space.parameter = -1;
    anim::update(&fixture.assets, &fixture.scene, 0);
    assert(approx(fixture.animator.nodes[3].local.position.y, 2));
    fixture.animator.stop_blend_space(space, 1)!!;
    anim::update(&fixture.assets, &fixture.scene, 0.5f);
    assert(approx(fixture.animator.action(space.actions[0]).weight, 0.5f));
    anim::update(&fixture.assets, &fixture.scene, 0.6f);
    assert(space.count == 0 && fixture.animator.action_count == 0);
}

fn void test_blend_space_motion_and_events_share_the_member_clock() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    ClipId[2] clips = {
        motion_clip(&fixture, { 1, 0, 0 }),
        motion_clip(fixture: &fixture, displacement: { 1, 0, 0 }, duration: 0.5f),
    };
    ClipEvent[1] event = { { .time = 0, .id = 1 } };
    foreach (clip : clips) fixture.assets.set_clip_events(clip, event[..])!!;
    float[2] positions = { 0, 1 };
    BlendSpace1D* space = fixture.animator.add_blend_space(
        assets: &fixture.assets,
        clips: clips[..],
        positions: positions[..],
        desc: { .root_motion = RootMotion.EXTRACT },
    )!!;
    space.parameter = 0.5f;
    anim::update(&fixture.assets, &fixture.scene, 0.375f);
    assert(approx(fixture.animator.root_motion.translation.x, 0.5f));
    check_events(fixture.animator, { 1, 1 });
    assert(!fixture.animator.action(space.actions[0]).playing);
    space.speed = -1;
    anim::update(&fixture.assets, &fixture.scene, 0.375f);
    assert(approx(fixture.animator.root_motion.translation.x, -0.5f));
}

fn void test_blend_space_failures_leave_existing_actions_intact() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    ClipId clip = motion_clip(&fixture, { 1, 0, 0 });
    AnimationActionId existing = fixture.animator.play(&fixture.assets, clip)!!;
    ClipId[2] clips = { clip, {} };
    float[2] positions = { 0, 1 };
    if (catch excuse = fixture.animator.add_blend_space(&fixture.assets, clips[..], positions[..])) {
        assert(excuse == c3d::INVALID_ID);
    } else {
        assert(false);
    }
    clips[1] = clip;
    positions[1] = 0;
    if (catch excuse = fixture.animator.add_blend_space(&fixture.assets, clips[..], positions[..])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    assert(fixture.animator.action_count == 1 && c3d::same_id(fixture.animator.order[0], existing));
    positions[1] = 1;
    for (uint count = 1; count < anim::MAX_ACTIONS - 1; count++) fixture.animator.play(&fixture.assets, clip)!!;
    if (catch excuse = fixture.animator.add_blend_space(&fixture.assets, clips[..], positions[..])) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }
    assert(fixture.animator.action_count == anim::MAX_ACTIONS - 1);
}

fn void test_motion_groups_allocate_only_at_creation_and_release_owned_arrays() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        LayerFixture fixture;
        create_layer_fixture(&fixture, &tracker);
        defer destroy_layer_fixture(&fixture);

        ClipId[2] clips = { motion_clip(&fixture, { 1, 0, 0 }), motion_clip(&fixture, { 2, 0, 0 }) };
        float[2] positions = { 0, 1 };
        BlendSpace1D* space = fixture.animator.add_blend_space(
            assets: &fixture.assets,
            clips: clips[..],
            positions: positions[..],
            desc: { .root_motion = RootMotion.EXTRACT },
        )!!;
        space.parameter = 0.5f;
        ClipEvent[1] event = { { .time = 0.25f, .id = 1 } };
        foreach (clip : clips) fixture.assets.set_clip_events(clip, event[..])!!;

        sz allocations = tracker.total_allocation_count();
        for (uint frame = 0; frame < 100; frame++) anim::update(&fixture.assets, &fixture.scene, 0.01f);
        assert(tracker.total_allocation_count() == allocations);
        fixture.animator.stop_blend_space(space)!!;
        assert(fixture.animator.action_count == 0);
    }
    assert(!tracker.has_leaks());
}

fn void test_root_yaw_crosses_angle_seam_and_rejects_tilted_basis() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    Quat start = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 170.0f * (float)math::PI / 180);
    Quat end = quaternion::from_axis_angle{float}({ 0, 1, 0 }, -170.0f * (float)math::PI / 180);
    float[2] times = { 0, 1 };
    float[8] rotations = { start.v.x, start.v.y, start.v.z, start.v.w, end.v.x, end.v.y, end.v.z, end.v.w };
    Track[1] tracks = {
        make_track(
            path: TargetPath.ROTATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: rotations[..],
        ),
    };
    uint[1] targets = { 2 };
    ClipId clip = add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
    AnimationActionId id = fixture.animator.play(
        assets: &fixture.assets,
        clip: clip,
        desc: { .root_motion = RootMotion.EXTRACT, .root_yaw = true },
    )!!;
    anim::update(&fixture.assets, &fixture.scene, 1);
    assert(rotates_x_to(fixture.animator.root_motion.rotation, { 0.9396926f, 0, -0.3420201f }));
    fixture.animator.stop(id)!!;

    fixture.root.local.scale = { 1, 2, 1 };
    if (catch excuse = fixture.animator.play(
        assets: &fixture.assets,
        clip: clip,
        desc: { .root_motion = RootMotion.EXTRACT, .root_yaw = true },
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    assert(fixture.animator.action_count == 0);
}

fn void test_event_fades_preserve_action_order_and_saturate_drops() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    ClipId clip = motion_clip(&fixture, { 1, 0, 0 });
    ClipEvent[2] events = { { .time = 0, .id = 1 }, { .time = 0.25f, .id = 2 } };
    fixture.assets.set_clip_events(clip, events[..])!!;
    AnimationActionId first = fixture.animator.play(&fixture.assets, clip)!!;
    AnimationActionId second = fixture.animator.play(&fixture.assets, clip, { .fade_in = 0.5f })!!;
    fixture.animator.cross_fade(first, second, 0.5f)!!;
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    check_events(fixture.animator, { 1, 1 });
    assert(c3d::same_id(fixture.animator.events[0].action, first));
    assert(c3d::same_id(fixture.animator.events[1].action, second));

    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    check_events(fixture.animator, { 2 });
    assert(c3d::same_id(fixture.animator.events[0].action, second));
    anim::update(&fixture.assets, &fixture.scene, 4_294_967_296.0f);
    assert(fixture.animator.events_dropped == uint::max);
}

fn void test_space_partial_creation_rolls_back_and_slot_capacity_is_fixed() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    ClipId good = motion_clip(&fixture, { 1, 0, 0 });
    ClipId bad = motion_clip(&fixture, { 1, 0, 0 });
    fixture.assets.clip(bad).data.targets[0] = (uint)fixture.animator.nodes.len;
    ClipId[2] clips = { good, bad };
    float[2] positions = { 0, 1 };
    AnimationActionId existing = fixture.animator.play(&fixture.assets, good)!!;
    if (catch excuse = fixture.animator.add_blend_space(&fixture.assets, clips[..], positions[..])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    assert(fixture.animator.action_count == 1 && c3d::same_id(fixture.animator.order[0], existing));

    clips[1] = good;
    positions[1] = bitcast(0x7fc00000u, float);
    if (catch excuse = fixture.animator.add_blend_space(&fixture.assets, clips[..], positions[..])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    positions[1] = 1;
    fixture.assets.clip(good).data.duration = 0;
    if (catch excuse = fixture.animator.add_blend_space(&fixture.assets, clips[..], positions[..])) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    fixture.assets.clip(good).data.duration = 1;

    for (uint index = 0; index < anim::MAX_BLEND_SPACES; index++) {
        fixture.animator.add_blend_space(&fixture.assets, clips[..], positions[..])!!;
    }
    if (catch excuse = fixture.animator.add_blend_space(&fixture.assets, clips[..], positions[..])) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }
    assert(fixture.animator.action_count == 1 + 2 * anim::MAX_BLEND_SPACES);
    fixture.animator.stop_blend_space(&fixture.animator.blend_spaces[0])!!;
    BlendSpace1D* reused = fixture.animator.add_blend_space(&fixture.assets, clips[..], positions[..])!!;
    assert(reused.count == 2 && reused.phase == 0);
}

fn void test_unskinned_instances_require_explicit_motion_root() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    foreach (node : fixture.animator.nodes) {
        if (fixture.scene.has(node, SkinBinding)) fixture.scene.remove_component(node, SkinBinding);
    }
    fixture.scene.remove_component(fixture.root, Animator);
    fixture.animator = anim::add_animator(&fixture.scene, fixture.root);
    assert(fixture.animator.root_node == anim::NO_ROOT_NODE);
    ClipId clip = motion_clip(&fixture, { 1, 0, 0 });
    if (catch excuse = fixture.animator.play(&fixture.assets, clip, { .root_motion = RootMotion.EXTRACT })) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    fixture.animator.root_node = 2;
    fixture.animator.play(&fixture.assets, clip, { .root_motion = RootMotion.EXTRACT })!!;
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    assert(approx(fixture.animator.root_motion.translation.x, 0.25f));
}
