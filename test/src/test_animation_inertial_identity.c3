module c3d::test::anim;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::scene;

fn void create_identity_fixture(LayerFixture* fixture, Allocator allocator = mem) @local {
    create_layer_fixture(fixture, allocator);
    fixture.scene.remove_component(fixture.root, Animator);
    fixture.animator = anim::add_animator(&fixture.scene, fixture.root, { .inertia_enabled = true });
}

fn ClipId identity_translation_clip(LayerFixture* fixture, uint node = 3) @local {
    float[2] times = { 0, 1 };
    float[6] values = { 2, 0, 3, 4, 0, 3 };
    Track[1] tracks = { make_track(
        path: TargetPath.TRANSLATION,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: values[..],
    ) };
    uint[1] targets = { node };
    return add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
}

fn InertialIdentityState identity_for_animator(LayerFixture* fixture) @local {
    PlaybackView playback = fixture.animator.playback();
    return anim::compute_inertial_identity(
        playback: &playback,
        assets: &fixture.assets,
        target_present: fixture.animator.pose_storage.destination.present,
    );
}

fn ModelTemplate copy_identity_model(ModelTemplate* source) @local {
    assert(!source.lod_groups.len && !source.lights.len && !source.cameras.len);
    ModelTemplate copy = {
        .nodes = alloc::new_array(mem, NodeTemplate, source.nodes.len),
        .meshes = alloc::new_array(mem, ModelMesh, source.meshes.len),
        .skins = alloc::new_array(mem, ModelSkin, source.skins.len),
        .clips = alloc::new_array(mem, ClipId, source.clips.len),
    };
    copy.nodes[..] = source.nodes[..];
    copy.meshes[..] = source.meshes[..];
    copy.skins[..] = source.skins[..];
    copy.clips[..] = source.clips[..];
    foreach (&node : copy.nodes) node.name = node.name.copy(mem);
    foreach (index, &mesh : copy.meshes) {
        float[] weights = source.meshes[index].default_morph_weights;
        mesh.default_morph_weights = alloc::new_array(mem, float, weights.len);
        mesh.default_morph_weights[..] = weights[..];
    }
    foreach (index, &skin : copy.skins) {
        uint[] joints = source.skins[index].joint_nodes;
        skin.joint_nodes = alloc::new_array(mem, uint, joints.len);
        skin.joint_nodes[..] = joints[..];
    }
    return copy;
}

fn bool identity_reference_unchanged(char[] bytes, Action* action) @local {
    return mem::equals(bytes.ptr, (char*)&action.motion_reference, (usz)bytes.len);
}

fn void test_animation_inertial_identity_normal_clocks_keep_identity_and_seek_queries_are_read_only() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        LayerFixture fixture;
        create_identity_fixture(&fixture, &tracker);
        defer destroy_layer_fixture(&fixture);
        ClipId clip = identity_translation_clip(&fixture);
        AnimationActionId id = fixture.animator.play(&fixture.assets, clip)!!;
        anim::update(&fixture.assets, &fixture.scene, 0.125f);
        anim::update(&fixture.assets, &fixture.scene, 0.125f);
        InertialRow* row = &fixture.animator.inertial_storage.rows[0];
        InertialIdentityState first = identity_for_animator(&fixture);
        anim::refresh_inertial_identity(row, first);
        assert(anim::inertial_history_is_current(row, first));
        sz allocations = tracker.total_allocation_count();
        for (uint frame = 0; frame < 4; frame++) {
            anim::update(&fixture.assets, &fixture.scene, 0.0625f);
            InertialIdentityState current = identity_for_animator(&fixture);
            assert(current.fingerprint == first.fingerprint && current.layout == first.layout);
            assert(!current.pending_seek && anim::inertial_history_is_current(row, current));
        }
        assert(tracker.total_allocation_count() == allocations);
        Action* action = fixture.animator.action(id);
        action.time = 0.75f;
        char[InertialRow::size] row_before;
        char[Action::size] action_before;
        mem::copy(&row_before, row, InertialRow::size);
        mem::copy(&action_before, action, Action::size);
        InertialIdentityState sought = identity_for_animator(&fixture);
        assert(sought.pending_seek && !anim::inertial_history_is_current(row, sought));
        assert(sought.fingerprint == first.fingerprint && sought.layout == first.layout);
        assert(mem::equals((char*)&row_before, (char*)row, InertialRow::size));
        assert(mem::equals((char*)&action_before, (char*)action, Action::size));
        assert(tracker.total_allocation_count() == allocations);
        anim::refresh_inertial_identity(row, sought);
        assert(!row.control.history_valid && !row.control.active);
        assert(row.control.duration == 0 && row.control.elapsed == 0 && !row.root.target_rate_pending);
        assert(action.time == 0.75f && action.published_time == 0.5f);
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_inertial_identity_sanctioned_revisions_invalidate_without_rebuilding_references() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        LayerFixture fixture;
        create_identity_fixture(&fixture, &tracker);
        defer destroy_layer_fixture(&fixture);
        ClipId clip = identity_translation_clip(&fixture, 2);
        AnimationActionId id = fixture.animator.play(&fixture.assets, clip, {
            .root_motion = RootMotion.EXTRACT,
            .extraction = { .generalized = true, .translation_axes = { true, false, true }, .up = { 0, 1, 0 } },
        })!!;
        anim::update(&fixture.assets, &fixture.scene, 0.125f);
        anim::update(&fixture.assets, &fixture.scene, 0.125f);
        InertialRow* row = &fixture.animator.inertial_storage.rows[0];
        InertialIdentityState original = identity_for_animator(&fixture);
        anim::refresh_inertial_identity(row, original);
        Action* action = fixture.animator.action(id);
        char[GeneralizedMotionReference::size] reference_before;
        mem::copy(&reference_before, &action.motion_reference, GeneralizedMotionReference::size);
        CapturedMotionChain* captured = action.motion_chain;
        ClipEvent[1] events = { { .time = 0.5f, .id = 123 } };
        fixture.assets.set_clip_events(clip, events[..])!!;
        sz allocations = tracker.total_allocation_count();
        InertialIdentityState revised_clip = identity_for_animator(&fixture);
        assert(revised_clip.fingerprint != original.fingerprint);
        assert(!anim::inertial_history_is_current(row, revised_clip));
        anim::refresh_inertial_identity(row, revised_clip);
        assert(!row.control.history_valid);
        assert(action.motion_chain == captured);
        assert(identity_reference_unchanged(reference_before[..], action));
        assert(tracker.total_allocation_count() == allocations);
        anim::update(&fixture.assets, &fixture.scene, 0.125f);
        InertialIdentityState current = identity_for_animator(&fixture);
        anim::refresh_inertial_identity(row, current);
        assert(anim::inertial_history_is_current(row, current));
        ModelTemplate replacement = copy_identity_model(&fixture.assets.model(fixture.model).data);
        fixture.assets.replace_model_owned(fixture.model, &replacement)!!;
        InertialIdentityState revised_model = identity_for_animator(&fixture);
        assert(revised_model.fingerprint != current.fingerprint && revised_model.layout == current.layout);
        assert(!anim::inertial_history_is_current(row, revised_model));
        anim::refresh_inertial_identity(row, revised_model);
        assert(!row.control.history_valid && action.motion_chain == captured);
        assert(identity_reference_unchanged(reference_before[..], action));
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_inertial_identity_rejected_request_does_not_clear_seek_history_or_clocks() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        LayerFixture fixture;
        create_identity_fixture(&fixture, &tracker);
        defer destroy_layer_fixture(&fixture);
        ClipId clip = identity_translation_clip(&fixture);
        fixture.animator.play(&fixture.assets, clip)!!;
        anim::update(&fixture.assets, &fixture.scene, 0.125f);
        anim::update(&fixture.assets, &fixture.scene, 0.125f);
        AnimationTargetDesc[1] targets = { anim::ANIMATION_TARGET_DEFAULT };
        targets[0].clip = clip;
        fixture.animator.inertialize(&fixture.assets, { .duration = 0.5f, .actions = targets[..] })!!;
        PlaybackView playback = fixture.animator.playback();
        InertialRow* row = playback.inertial;
        anim::refresh_inertial_identity(row, identity_for_animator(&fixture));
        assert(row.control.active && row.control.history_valid);
        Action* action = playback.actions.get(playback.order[0]);
        action.time = 0.75f;
        @pool() {
            InertialStorage* storage = fixture.animator.inertial_storage;
            char[] before = alloc::new_array(tmem, char, (sz)storage.bytes);
            mem::copy(before.ptr, storage, (sz)storage.bytes);
            char[Action::size] action_before;
            mem::copy(&action_before, action, Action::size);
            uint event_count = fixture.animator.event_count;
            sz calls = tracker.total_allocation_count();
            InertialIdentityState identity = identity_for_animator(&fixture);
            assert(identity.pending_seek && !anim::inertial_history_is_current(row, identity));
            bool caught;
            AnimationTransitionDesc rejected = { .duration = -1, .actions = targets[..] };
            if (catch excuse = fixture.animator.inertialize(&fixture.assets, rejected)) {
                assert(excuse == c3d::INVALID_ARGUMENT);
                caught = true;
            }
            assert(caught && tracker.total_allocation_count() == calls);
            assert(mem::equals(before.ptr, (char*)storage, (sz)storage.bytes));
            assert(mem::equals((char*)&action_before, (char*)action, Action::size));
            assert(fixture.animator.event_count == event_count && row.control.history_valid && row.control.active);
        };
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_inertial_identity_presence_root_and_order_changes_are_detected_without_allocating() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        LayerFixture fixture;
        create_identity_fixture(&fixture, &tracker);
        defer destroy_layer_fixture(&fixture);
        ClipId clip = identity_translation_clip(&fixture);
        AnimationActionId first = fixture.animator.play(&fixture.assets, clip)!!;
        AnimationActionId second = fixture.animator.play(&fixture.assets, clip)!!;
        anim::update(&fixture.assets, &fixture.scene, 0.125f);
        anim::update(&fixture.assets, &fixture.scene, 0.125f);
        InertialRow* row = &fixture.animator.inertial_storage.rows[0];
        InertialIdentityState original = identity_for_animator(&fixture);
        anim::refresh_inertial_identity(row, original);
        sz allocations = tracker.total_allocation_count();
        fixture.animator.root_node = 3;
        InertialIdentityState new_root = identity_for_animator(&fixture);
        assert(new_root.layout != original.layout && !anim::inertial_history_is_current(row, new_root));
        fixture.animator.root_node = 2;
        fixture.animator.order[0] = second;
        fixture.animator.order[1] = first;
        InertialIdentityState new_order = identity_for_animator(&fixture);
        assert(new_order.fingerprint != original.fingerprint && !anim::inertial_history_is_current(row, new_order));
        fixture.animator.order[0] = first;
        fixture.animator.order[1] = second;
        ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
        fixture.scene.remove(instance.present_node(3));
        anim::refresh_destination(fixture.animator);
        InertialIdentityState missing = identity_for_animator(&fixture);
        assert(missing.layout != original.layout && !anim::inertial_history_is_current(row, missing));
        fixture.animator.stop(second)!!;
        InertialIdentityState removed_action = identity_for_animator(&fixture);
        assert(removed_action.fingerprint != original.fingerprint);
        assert(!anim::inertial_history_is_current(row, removed_action));
        anim::refresh_inertial_identity(row, removed_action);
        assert(!row.control.history_valid && !row.control.active);
        assert(tracker.total_allocation_count() == allocations);
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_inertial_identity_crowd_reset_changes_incarnation_and_isolates_other_slot() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        LayerFixture fixture;
        create_identity_fixture(&fixture, &tracker);
        defer destroy_layer_fixture(&fixture);
        Transform[2] placements = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
        CrowdPlaybackState* state = anim::create_crowd_playback(
            allocator: &tracker,
            template: &fixture.assets.model(fixture.model).data,
            placements: placements[..],
            actions_per_instance: 4,
            event_capacity: 0,
            inertia_enabled: true,
        )!!;
        defer anim::destroy_crowd_playback(state);
        state.model = fixture.model;
        state.count = 2;
        ClipId clip = identity_translation_clip(&fixture);
        CrowdPlayer first = state.player(state.instance_id(0)!!)!!;
        CrowdPlayer second = state.player(state.instance_id(1)!!)!!;
        first.play(&fixture.assets, clip)!!;
        second.play(&fixture.assets, clip)!!;
        state.update(&fixture.assets, 0.125f);
        state.update(&fixture.assets, 0.125f);
        PlaybackView first_view = anim::crowd_playback_view(state, &state.slots[0]);
        PlaybackView second_view = anim::crowd_playback_view(state, &state.slots[1]);
        InertialIdentityState old_first = anim::compute_inertial_identity(&first_view, &fixture.assets, state.pose_storage.destination.present);
        InertialIdentityState old_second = anim::compute_inertial_identity(&second_view, &fixture.assets, state.pose_storage.destination.present);
        anim::refresh_inertial_identity(first_view.inertial, old_first);
        anim::refresh_inertial_identity(second_view.inertial, old_second);
        assert(anim::inertial_history_is_current(first_view.inertial, old_first));
        sz allocations = tracker.total_allocation_count();
        uint generation = first_view.inertial.control.generation;
        anim::reset_crowd_playback_slot(state, 0);
        first_view = anim::crowd_playback_view(state, &state.slots[0]);
        InertialIdentityState reset = anim::compute_inertial_identity(&first_view, &fixture.assets, state.pose_storage.destination.present);
        assert(first_view.inertial.control.generation != generation);
        assert(!first_view.inertial.control.history_valid && !first_view.inertial.control.identity.valid);
        assert(reset.fingerprint != old_first.fingerprint);
        assert(!anim::inertial_history_is_current(first_view.inertial, reset));
        InertialIdentityState retained = anim::compute_inertial_identity(&second_view, &fixture.assets, state.pose_storage.destination.present);
        assert(retained.fingerprint == old_second.fingerprint && retained.layout == old_second.layout);
        assert(anim::inertial_history_is_current(second_view.inertial, retained));
        assert(tracker.total_allocation_count() == allocations);
    }
    assert(!tracker.has_leaks());
}
