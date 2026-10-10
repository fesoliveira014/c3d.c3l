module c3d::test::anim;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::core::mem::allocators;
import std::io;
import std::math;

struct RequestAllocationProbe (Allocator) @local {
    Allocator backing;
    uint acquisitions;
    uint failure;
    sz outstanding;
}

struct RequestBlockSnapshot @local {
    void* pointer;
    char[] bytes;
}

struct InertialRequestFixture @local {
    LayerFixture ordinary;
    Transform[1] placements;
    CrowdPlaybackState* crowd;
    CrowdPlayer player;
}

struct RequestTargets @local {
    AnimationTargetDesc[4] actions;
    bool[4] membership;
    JointMask mask;
    WeightedJointMask weighted;
    uint[2] members;
    float[2] positions;
    CrowdSpaceAuthoring[1] spaces;
    AnimationTransitionDesc description;
}

fn void*? RequestAllocationProbe.acquire(
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

fn void*? RequestAllocationProbe.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    if (++self.acquisitions == self.failure) return mem::OUT_OF_MEMORY~;
    return self.backing.resize(pointer, size, alignment);
}

fn void RequestAllocationProbe.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
    self.outstanding--;
}

fn void create_inertial_request_fixture(
    InertialRequestFixture* fixture,
    Allocator allocator,
    uint crowd_actions,
) @local {
    create_layer_fixture(&fixture.ordinary, allocator);
    fixture.ordinary.scene.remove_component(fixture.ordinary.root, Animator);
    fixture.ordinary.animator = anim::add_animator(
        &fixture.ordinary.scene, fixture.ordinary.root, { .inertia_enabled = true });
    if (!crowd_actions) return;
    fixture.placements[0] = maths::TRANSFORM_IDENTITY;
    fixture.crowd = anim::create_crowd_playback(
        allocator: allocator,
        template: &fixture.ordinary.assets.model(fixture.ordinary.model).data,
        placements: fixture.placements[..],
        actions_per_instance: crowd_actions,
        event_capacity: 64,
        inertia_enabled: true,
    )!!;
    fixture.crowd.model = fixture.ordinary.model;
    fixture.crowd.count = 1;
    fixture.player = fixture.crowd.player(fixture.crowd.instance_id(0)!!)!!;
}

fn void destroy_inertial_request_fixture(InertialRequestFixture* fixture) @local {
    if (fixture.crowd) anim::destroy_crowd_playback(fixture.crowd);
    destroy_layer_fixture(&fixture.ordinary);
}

fn PlaybackView request_playback(InertialRequestFixture* fixture) @local {
    return fixture.crowd
      ? anim::crowd_playback_view(fixture.crowd, &fixture.crowd.slots[0])
      : fixture.ordinary.animator.playback();
}

fn InertialRow* request_history(InertialRequestFixture* fixture) @local {
    return fixture.crowd ? &fixture.crowd.inertial_storage.rows[0]
      : &fixture.ordinary.animator.inertial_storage.rows[0];
}

fn Transform request_pose(InertialRequestFixture* fixture, uint node = 3) @local {
    if (fixture.crowd) return fixture.crowd.poses[node];
    ModelInstance* instance = fixture.ordinary.scene.get(fixture.ordinary.root, ModelInstance);
    return instance.present_node(node).local;
}

fn void request_update(InertialRequestFixture* fixture, float dt) @local {
    if (fixture.crowd) {
        fixture.crowd.update(&fixture.ordinary.assets, dt);
    } else {
        anim::update(&fixture.ordinary.assets, &fixture.ordinary.scene, dt);
    }
}

fn void? request_transition(InertialRequestFixture* fixture, AnimationTransitionDesc description) @local {
    if (fixture.crowd) return fixture.player.inertialize(&fixture.ordinary.assets, description);
    return fixture.ordinary.animator.inertialize(&fixture.ordinary.assets, description);
}

fn AnimationActionId request_play(InertialRequestFixture* fixture, ClipId clip, PlayDesc desc = {}) @local {
    if (fixture.crowd) return fixture.player.play(&fixture.ordinary.assets, clip, desc)!!;
    return fixture.ordinary.animator.play(&fixture.ordinary.assets, clip, desc)!!;
}

fn void request_cancel(InertialRequestFixture* fixture) @local {
    if (fixture.crowd) {
        fixture.player.cancel_inertial_transition()!!;
    } else {
        fixture.ordinary.animator.cancel_inertial_transition();
    }
}

fn uint request_event_count(InertialRequestFixture* fixture) @local {
    return fixture.crowd ? fixture.crowd.event_count : fixture.ordinary.animator.event_count;
}

fn FiredEvent request_event(InertialRequestFixture* fixture, uint index) @local {
    return fixture.crowd ? fixture.crowd.events[index].event : fixture.ordinary.animator.events[index];
}

fn ClipId request_translation_clip(
    InertialRequestFixture* fixture,
    Vec3 start,
    Vec3 end,
    ClipEvent[] events = {},
) @local {
    float[2] times = { 0, 1 };
    float[6] values = { start.x, start.y, start.z, end.x, end.y, end.z };
    Track[1] tracks = { make_track(
        path: TargetPath.TRANSLATION,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: values[..],
    ) };
    uint[1] targets = { 3 };
    ClipId clip = add_clip(
        assets: &fixture.ordinary.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
    AnimationClip* data = &fixture.ordinary.assets.clip(clip).data;
    data.events = alloc::new_array(mem, ClipEvent, events.len);
    data.events[..] = events[..];
    return clip;
}

fn ClipId request_property_clip(
    InertialRequestFixture* fixture,
    TargetPath path,
    Interpolation interpolation,
    float[] times,
    float[] values,
    uint node,
) @local {
    Track[1] tracks = { make_track(
        path: path,
        interpolation: interpolation,
        times: times,
        values: values,
    ) };
    uint[1] targets = { node };
    return add_clip(
        assets: &fixture.ordinary.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: times[times.len - 1],
    );
}

fn RequestBlockSnapshot[] request_snapshot_blocks(TrackingAllocator* tracker) @local {
    Allocation[] allocations = tracker.allocations_tlist(tmem);
    RequestBlockSnapshot[] snapshot = alloc::new_array(tmem, RequestBlockSnapshot, allocations.len);
    foreach (index, allocation : allocations) {
        snapshot[index].pointer = allocation.ptr;
        snapshot[index].bytes = alloc::new_array(tmem, char, allocation.size);
        mem::copy(snapshot[index].bytes.ptr, allocation.ptr, (usz)allocation.size);
    }
    return snapshot;
}

fn void request_assert_blocks_unchanged(TrackingAllocator* tracker, RequestBlockSnapshot[] snapshot) @local {
    Allocation[] current = tracker.allocations_tlist(tmem);
    assert(current.len == snapshot.len);
    foreach (saved : snapshot) {
        bool present;
        foreach (allocation : current) {
            if (allocation.ptr != saved.pointer) continue;
            assert(allocation.size == saved.bytes.len);
            present = true;
        }
        assert(present);
        assert(mem::equals((char*)saved.pointer, saved.bytes.ptr, (usz)saved.bytes.len));
    }
}

fn void request_fill_sources(InertialRequestFixture* fixture, ClipId clip) @local {
    PlaybackView playback = request_playback(fixture);
    for (uint index = 0; index < playback.actions.items.len; index++) request_play(fixture, clip);
    request_update(fixture, 0.25f);
    assert(*playback.action_count == playback.actions.items.len && playback.actions.free_count == 0);
}

fn void create_request_targets(InertialRequestFixture* fixture, RequestTargets* targets) @local {
    ClipId translation = request_translation_clip(
        fixture: fixture,
        start: { 8, 0, 0 },
        end: { 8, 0, 0 },
    );
    float[2] times = { 0, 1 };
    float[6] scales = { 2, 2, 2, 2, 2, 2 };
    ClipId scale = request_property_clip(
        fixture: fixture,
        path: TargetPath.SCALE,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: scales[..],
        node: 3,
    );
    String[4] names;
    float[4] weights = { 1, 1, 1, 1 };
    foreach (index, node : fixture.ordinary.assets.model(fixture.ordinary.model).data.nodes) names[index] = node.name;
    targets.weighted = anim::create_weighted_joint_mask(
        allocator: mem,
        assets: &fixture.ordinary.assets,
        model: fixture.ordinary.model,
        names: names[..],
        weights: weights[..],
    )!!;
    targets.membership[..] = true;
    targets.mask = { .nodes = targets.membership[..] };
    foreach (&target : targets.actions) {
        *target = anim::ANIMATION_TARGET_DEFAULT;
        target.clip = translation;
    }
    targets.actions[0].play.mask = &targets.mask;
    targets.actions[1].play.mask = &targets.mask;
    targets.actions[2].play = { .additive = true, .weighted_mask = &targets.weighted };
    targets.actions[3].clip = scale;
    targets.actions[3].play = {
        .additive = true,
        .additive_scale = AdditiveScaleMode.MULTIPLICATIVE,
        .weighted_mask = &targets.weighted,
    };
    targets.members = { 0, 1 };
    targets.positions = { 0, 1 };
    targets.spaces[0] = {
        .actions = targets.members[..],
        .positions = targets.positions[..],
        .parameter = 0.25f,
        .weight = 1,
        .speed = 0.5f,
        .playing = true,
    };
    targets.description = { .duration = 0.5f, .actions = targets.actions[..], .spaces = targets.spaces[..] };
}

fn uint measure_request_allocations(uint crowd_actions) @local {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    uint acquisitions;
    {
        RequestAllocationProbe allocator = { .backing = &tracker };
        InertialRequestFixture fixture;
        create_inertial_request_fixture(&fixture, &allocator, crowd_actions);
        defer destroy_inertial_request_fixture(&fixture);
        ClipId source = request_translation_clip(
            fixture: &fixture,
            start: { 1, 0, 0 },
            end: { 1, 0, 0 },
        );
        request_fill_sources(&fixture, source);
        RequestTargets targets;
        create_request_targets(&fixture, &targets);
        defer anim::destroy_weighted_joint_mask(&targets.weighted);
        allocator.acquisitions = 0;
        request_transition(&fixture, targets.description)!!;
        acquisitions = allocator.acquisitions;
        assert(acquisitions > 0);
    }
    assert(!tracker.has_leaks());
    return acquisitions;
}

fn PlayDesc request_generalized_desc() @local {
    return {
        .root_motion = RootMotion.EXTRACT,
        .extraction = { .generalized = true, .translation_axes = { true, true, true }, .up = { 0, 1, 0 } },
    };
}

fn void test_animation_inertial_request_full_capacity_copies_targets_and_hands_off_events() @test {
    uint[3] capacities = { 0, 4, 16 };
    foreach (capacity : capacities) {
        InertialRequestFixture fixture;
        create_inertial_request_fixture(&fixture, mem, capacity);
        defer destroy_inertial_request_fixture(&fixture);
        ClipEvent[1] source_events = { { .time = 0.125f, .id = 111 } };
        ClipEvent[1] target_events = { { .time = 0.375f, .id = 222 } };
        ClipId source = request_translation_clip(
            fixture: &fixture,
            start: { 1, 0, 0 },
            end: { 1, 0, 0 },
            events: source_events[..],
        );
        ClipId destination = request_translation_clip(
            fixture: &fixture,
            start: { 8, 0, 0 },
            end: { 8, 0, 0 },
            events: target_events[..],
        );
        request_fill_sources(&fixture, source);
        PlaybackView playback = request_playback(&fixture);
        uint count = *playback.action_count;
        AnimationActionId[16] previous;
        previous[:count] = playback.order[:count];
        assert(request_event_count(&fixture) == count);
        assert(request_event(&fixture, 0).id == 111);
        AnimationTargetDesc[16] targets;
        bool[4] membership = { true, true, true, true };
        JointMask mask = { .nodes = membership[..] };
        foreach (&target : targets[:count]) {
            *target = anim::ANIMATION_TARGET_DEFAULT;
            target.clip = destination;
            target.play.mask = &mask;
        }
        request_transition(&fixture, { .duration = 0.5f, .actions = targets[:count] })!!;
        playback = request_playback(&fixture);
        assert(*playback.action_count == count && playback.actions.free_count == 0);
        foreach (id : previous[:count]) assert(!playback.actions.is_live(id));
        assert(request_event_count(&fixture) == 0 && request_pose(&fixture).position == (Vec3){ 1, 0, 0 });
        targets[..] = (AnimationTargetDesc){};
        membership[..] = false;
        request_update(&fixture, 0.25f);
        assert(request_pose(&fixture).position == (Vec3){ 4.5f, 0, 0 });
        assert(request_event_count(&fixture) == 0);
        request_update(&fixture, 0.25f);
        assert(request_pose(&fixture).position == (Vec3){ 8, 0, 0 });
        assert(request_event_count(&fixture) == count);
        for (uint index = 0; index < count; index++) {
            FiredEvent event = request_event(&fixture, index);
            assert(event.id == 222 && c3d::same_id(event.clip, destination));
            assert(playback.actions.is_live(event.action));
        }
    }
}

fn void test_animation_inertial_request_every_real_temporary_failure_preserves_all_owner_blocks() @test {
    uint[3] capacities = { 0, 4, 16 };
    foreach (capacity : capacities) {
        uint acquisitions = measure_request_allocations(capacity);
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        {
            RequestAllocationProbe allocator = { .backing = &tracker };
            InertialRequestFixture fixture;
            create_inertial_request_fixture(&fixture, &allocator, capacity);
            defer destroy_inertial_request_fixture(&fixture);
            ClipEvent[1] events = { { .time = 0.125f, .id = 111 } };
            ClipId source = request_translation_clip(
                fixture: &fixture,
                start: { 1, 0, 0 },
                end: { 1, 0, 0 },
                events: events[..],
            );
            request_fill_sources(&fixture, source);
            RequestTargets targets;
            create_request_targets(&fixture, &targets);
            defer anim::destroy_weighted_joint_mask(&targets.weighted);
            for (uint failure = 1; failure <= acquisitions; failure++) @pool() {
                RequestBlockSnapshot[] snapshot = request_snapshot_blocks(&tracker);
                sz retained = tracker.allocated();
                sz outstanding = allocator.outstanding;
                allocator.acquisitions = 0;
                allocator.failure = failure;
                bool caught;
                if (catch excuse = request_transition(&fixture, targets.description)) {
                    assert(excuse == c3d::CAPACITY_EXCEEDED);
                    caught = true;
                }
                assert(caught && allocator.acquisitions == failure);
                assert(allocator.outstanding == outstanding && tracker.allocated() == retained);
                request_assert_blocks_unchanged(&tracker, snapshot);
                assert(request_event_count(&fixture) == (capacity ? capacity : 16));
            };
            allocator.failure = 0;
            request_transition(&fixture, targets.description)!!;
            targets.members[..] = uint::max;
            targets.positions[..] = -100;
            targets.membership[..] = false;
            targets.weighted.nodes[..] = 0;
            targets.actions[..] = (AnimationTargetDesc){};
            PlaybackView playback = request_playback(&fixture);
            assert(playback.blend_spaces[0].positions[0] == 0 && playback.blend_spaces[0].positions[1] == 1);
            assert(playback.blend_spaces[0].parameter == 0.25f && *playback.action_count == 4);
            request_update(&fixture, 0.5f);
            assert(request_pose(&fixture).position == (Vec3){ 8, 0, 0 });
        }
        assert(!tracker.has_leaks());
    }
}

fn void test_animation_inertial_request_onset_zero_step_interruption_and_cancel_have_literal_output() @test {
    uint[2] capacities = { 0, 4 };
    foreach (capacity : capacities) {
        InertialRequestFixture fixture;
        create_inertial_request_fixture(&fixture, mem, capacity);
        defer destroy_inertial_request_fixture(&fixture);
        ClipId source = request_translation_clip(
            fixture: &fixture,
            start: { 0, 0, 0 },
            end: { 1, 0, 0 },
        );
        ClipId target = request_translation_clip(
            fixture: &fixture,
            start: { 10, 0, 0 },
            end: { 10, 0, 0 },
        );
        ClipId interrupted = request_translation_clip(
            fixture: &fixture,
            start: { -4, 0, 0 },
            end: { -4, 0, 0 },
        );
        request_play(&fixture, source);
        request_update(&fixture, 0.125f);
        request_update(&fixture, 0.125f);
        assert(request_pose(&fixture).position.x == 0.25f);
        assert(request_history(&fixture).velocity[3].translation.x == 1);
        AnimationTargetDesc[1] description = { anim::ANIMATION_TARGET_DEFAULT };
        description[0].clip = target;
        request_transition(&fixture, { .duration = 0.5f, .actions = description[..] })!!;
        assert(request_pose(&fixture).position.x == 0.25f);
        request_update(&fixture, 0);
        assert(request_pose(&fixture).position.x == 0.25f && request_history(&fixture).control.elapsed == 0);
        request_update(&fixture, 0.125f);
        assert(request_pose(&fixture).position.x == 1.3515625f);
        assert(request_history(&fixture).velocity[3].translation.x == 8.8125);
        description[0].clip = interrupted;
        request_transition(&fixture, { .duration = 0.25f, .actions = description[..] })!!;
        assert(request_pose(&fixture).position.x == 1.3515625f);
        request_update(&fixture, 0);
        assert(request_pose(&fixture).position.x == 1.3515625f && request_history(&fixture).control.elapsed == 0);
        PlaybackView playback = request_playback(&fixture);
        AnimationActionId installed = playback.order[0];
        request_cancel(&fixture);
        assert(!request_history(&fixture).control.active && playback.actions.is_live(installed));
        request_update(&fixture, 0);
        assert(request_pose(&fixture).position.x == -4 && *playback.action_count == 1);
    }
}

fn void test_animation_inertial_request_rotation_uses_shortest_twenty_degree_transition() @test {
    uint[2] capacities = { 0, 4 };
    foreach (capacity : capacities) {
        InertialRequestFixture fixture;
        create_inertial_request_fixture(&fixture, mem, capacity);
        defer destroy_inertial_request_fixture(&fixture);
        float[2] times = { 0, 1 };
        Quat positive = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)(math::PI * 170 / 180));
        Quat negative = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)(-math::PI * 170 / 180));
        float[8] source_values = { positive.v.x, positive.v.y, positive.v.z, positive.v.w,
            positive.v.x, positive.v.y, positive.v.z, positive.v.w };
        float[8] target_values = { negative.v.x, negative.v.y, negative.v.z, negative.v.w,
            negative.v.x, negative.v.y, negative.v.z, negative.v.w };
        ClipId source = request_property_clip(
            fixture: &fixture,
            path: TargetPath.ROTATION,
            interpolation: Interpolation.STEP,
            times: times[..],
            values: source_values[..],
            node: 3,
        );
        ClipId target = request_property_clip(
            fixture: &fixture,
            path: TargetPath.ROTATION,
            interpolation: Interpolation.STEP,
            times: times[..],
            values: target_values[..],
            node: 3,
        );
        request_play(&fixture, source);
        request_update(&fixture, 0);
        AnimationTargetDesc[1] description = { anim::ANIMATION_TARGET_DEFAULT };
        description[0].clip = target;
        request_transition(&fixture, { .duration = 0.5f, .actions = description[..] })!!;
        Quat onset = request_pose(&fixture).rotation;
        assert(math::abs(onset.v.dot(positive.v)) > 1 - 1e-6f);
        request_update(&fixture, 0.25f);
        Quat middle = request_pose(&fixture).rotation;
        assert(math::abs(middle.v.y) > 1 - 1e-6f && math::abs(middle.v.w) < 1e-6f);
        request_update(&fixture, 0.25f);
        assert(math::abs(request_pose(&fixture).rotation.v.dot(negative.v)) > 1 - 1e-6f);
    }
}

fn void test_animation_inertial_request_consumed_scale_follows_geometric_midpoint() @test {
    uint[2] capacities = { 0, 4 };
    foreach (capacity : capacities) {
        InertialRequestFixture fixture;
        create_inertial_request_fixture(&fixture, mem, capacity);
        defer destroy_inertial_request_fixture(&fixture);
        float[2] times = { 0, 1 };
        float[6] source_values = { 4, 4, 4, 4, 4, 4 };
        float[6] target_values = { 1, 1, 1, 1, 1, 1 };
        ClipId source = request_property_clip(
            fixture: &fixture,
            path: TargetPath.SCALE,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: source_values[..],
            node: 2,
        );
        ClipId target = request_property_clip(
            fixture: &fixture,
            path: TargetPath.SCALE,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: target_values[..],
            node: 2,
        );
        PlayDesc generalized = request_generalized_desc();
        request_play(&fixture, source, generalized);
        request_update(&fixture, 0);
        AnimationTargetDesc[1] description = { anim::ANIMATION_TARGET_DEFAULT };
        description[0].clip = target;
        description[0].play = generalized;
        request_transition(&fixture, { .duration = 0.5f, .actions = description[..] })!!;
        assert(request_pose(&fixture, 2).scale == (Vec3){ 4, 4, 4 });
        request_update(&fixture, 0.25f);
        assert((request_pose(&fixture, 2).scale - (Vec3){ 2, 2, 2 }).length() < 1e-5f);
        assert(request_pose(&fixture, 0).scale == (Vec3){ 1, 1, 1 });
        request_update(&fixture, 0.25f);
        assert(request_pose(&fixture, 2).scale == (Vec3){ 1, 1, 1 });
    }
}

fn void test_animation_inertial_request_real_scale_histories_reject_long_and_accept_short_duration_atomically() @test {
    uint[2] capacities = { 0, 4 };
    foreach (capacity : capacities) foreach (double sign : { -1.0, 1.0 }) {
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        {
            RequestAllocationProbe allocator = { .backing = &tracker };
            InertialRequestFixture fixture;
            create_inertial_request_fixture(&fixture, &allocator, capacity);
            defer destroy_inertial_request_fixture(&fixture);
            float scale = 0x1p-100f;
            float step = 0x1p-11f;
            float[2] source_times = { 0, step };
            float first = sign < 0 ? 0x1.8p-100f : 0x1p-101f;
            float[6] source_values = { first, first, first, scale, scale, scale };
            float[2] target_times = { 0, 1 };
            float[6] target_values = { scale, scale, scale, scale, scale, scale };
            ClipId source = request_property_clip(
                fixture: &fixture,
                path: TargetPath.SCALE,
                interpolation: Interpolation.LINEAR,
                times: source_times[..],
                values: source_values[..],
                node: 2,
            );
            ClipId target = request_property_clip(
                fixture: &fixture,
                path: TargetPath.SCALE,
                interpolation: Interpolation.LINEAR,
                times: target_times[..],
                values: target_values[..],
                node: 2,
            );
            ModelInstance* instance = fixture.ordinary.scene.get(fixture.ordinary.root, ModelInstance);
            instance.base_pose[2].scale = { scale, scale, scale };
            if (fixture.crowd) fixture.crowd.base_pose[2].scale = { scale, scale, scale };
            PlayDesc generalized = request_generalized_desc();
            AnimationActionId id = request_play(&fixture, source, generalized);
            PlaybackView playback = request_playback(&fixture);
            Action* action = playback.actions.get(id);
            action.loop = false;
            action.playing = false;
            request_update(&fixture, step);
            action.playing = true;
            request_update(&fixture, step);
            assert(request_pose(&fixture, 2).scale.x == scale);
            assert(request_history(&fixture).velocity[2].scale.x == sign * 0x1p-90);
            AnimationTargetDesc[1] description = { anim::ANIMATION_TARGET_DEFAULT };
            description[0].clip = target;
            description[0].play = generalized;
            @pool() {
                RequestBlockSnapshot[] snapshot = request_snapshot_blocks(&tracker);
                uint calls = allocator.acquisitions;
                bool caught;
                if (catch excuse = request_transition(&fixture, { .duration = 1, .actions = description[..] })) {
                    assert(excuse == c3d::INVALID_ARGUMENT);
                    caught = true;
                }
                assert(caught && allocator.acquisitions == calls);
                request_assert_blocks_unchanged(&tracker, snapshot);
            };
            request_transition(&fixture, { .duration = 0x1p-6f, .actions = description[..] })!!;
            assert(request_pose(&fixture, 2).scale.x == scale);
            request_update(&fixture, 0x1p-8f);
            double expected = 0x1p-100 * math::exp(sign * 2.953125);
            Vec3 actual = request_pose(&fixture, 2).scale;
            assert(math::abs((double)actual.x / expected - 1) < 1e-5);
            assert(actual.x > 0 && math::is_finite(actual.x) && actual.x == actual.y && actual.y == actual.z);
        }
        assert(!tracker.has_leaks());
    }
}

fn void test_animation_inertial_request_exact_invalid_precedes_sampling_unsupported_without_allocating() @test {
    uint[2] capacities = { 0, 4 };
    foreach (capacity : capacities) {
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        {
            RequestAllocationProbe allocator = { .backing = &tracker };
            InertialRequestFixture fixture;
            create_inertial_request_fixture(&fixture, &allocator, capacity);
            defer destroy_inertial_request_fixture(&fixture);
            float[2] times = { 0, 1 };
            float[6] ordinary = { 1, 1, 1, 1, 1, 1 };
            ClipId source = request_property_clip(
                fixture: &fixture,
                path: TargetPath.SCALE,
                interpolation: Interpolation.LINEAR,
                times: times[..],
                values: ordinary[..],
                node: 2,
            );
            float[2] band_times = { 0x1p-149, 1 };
            float[18] band_values = { 0, 0, 0, 1, 1, 1, -4, -4, -4, 4, 4, 4, 1, 1, 1, 0, 0, 0 };
            ClipId band = request_property_clip(
                fixture: &fixture,
                path: TargetPath.SCALE,
                interpolation: Interpolation.CUBIC_SPLINE,
                times: band_times[..],
                values: band_values[..],
                node: 2,
            );
            float[6] invalid_values = { 1, 2, 1, 1, 2, 1 };
            ClipId invalid = request_property_clip(
                fixture: &fixture,
                path: TargetPath.SCALE,
                interpolation: Interpolation.LINEAR,
                times: times[..],
                values: invalid_values[..],
                node: 2,
            );
            PlayDesc generalized = request_generalized_desc();
            request_play(&fixture, source, generalized);
            PlaybackView playback = request_playback(&fixture);
            assert(playback.root_node == 2);
            ModelTemplate* template = &fixture.ordinary.assets.model(fixture.ordinary.model).data;
            assert(template.nodes[0].parent == -1 && template.nodes[2].parent == -1);
            request_update(&fixture, 0.25f);
            AnimationTargetDesc[2] targets = { anim::ANIMATION_TARGET_DEFAULT, anim::ANIMATION_TARGET_DEFAULT };
            targets[0].clip = band;
            targets[1].clip = invalid;
            targets[0].play = targets[1].play = generalized;
            for (uint count = 2; count > 0; count--) @pool() {
                RequestBlockSnapshot[] snapshot = request_snapshot_blocks(&tracker);
                uint calls = allocator.acquisitions;
                bool caught;
                if (catch excuse = request_transition(&fixture, { .duration = 0.5f, .actions = targets[:count] })) {
                    fault expected = count == 2 ? c3d::INVALID_ARGUMENT : c3d::UNSUPPORTED;
                    if (excuse != expected) {
                        io::printfn("request rejection crowd_actions=%s targets=%s", capacity, count);
                        io::printfn("expected=%s observed=%s", expected, excuse);
                    }
                    assert(excuse == expected);
                    caught = true;
                }
                assert(caught && allocator.acquisitions == calls);
                request_assert_blocks_unchanged(&tracker, snapshot);
            };
        }
        assert(!tracker.has_leaks());
    }
}
