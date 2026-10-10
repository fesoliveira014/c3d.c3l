module c3d::test::anim;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import c3d::scene;
import std::math;

struct TransitionPrepareProbe (Allocator) @local {
    Allocator backing;
    uint attempts;
    uint failure;
    uint outstanding;
}

struct TransitionPrepareSnapshot @local {
    char[] actions;
    uint[] generations;
    uint[] free;
    AnimationActionId[] order;
    char[] linear;
    char[] planar;
    char[] inertia;
    uint action_count;
    uint free_count;
}

fn void*? TransitionPrepareProbe.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    if (++self.attempts == self.failure) return mem::OUT_OF_MEMORY~;
    void* pointer = self.backing.acquire(size, init_type, alignment)!;
    self.outstanding++;
    return pointer;
}

fn void*? TransitionPrepareProbe.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    if (++self.attempts == self.failure) return mem::OUT_OF_MEMORY~;
    return self.backing.resize(pointer, size, alignment);
}

fn void TransitionPrepareProbe.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
    self.outstanding--;
}

fn TransitionPrepareSnapshot snapshot_transition_owner(PlaybackView* playback) @local {
    char[] actions = ((char*)playback.actions.items.ptr)[:playback.actions.items.len * Action::size];
    char[] linear = ((char*)playback.blend_spaces.ptr)[:playback.blend_spaces.len * BlendSpace1D::size];
    char[] planar = ((char*)playback.blend_spaces_2d.ptr)[:playback.blend_spaces_2d.len * BlendSpace2D::size];
    TransitionPrepareSnapshot snapshot = {
        .actions = alloc::clone_slice(mem, actions),
        .generations = alloc::clone_slice(mem, playback.actions.generations),
        .free = alloc::clone_slice(mem, playback.actions.free),
        .order = alloc::clone_slice(mem, playback.order),
        .linear = alloc::clone_slice(mem, linear),
        .planar = alloc::clone_slice(mem, planar),
        .action_count = *playback.action_count,
        .free_count = playback.actions.free_count,
    };
    return snapshot;
}

fn void destroy_transition_snapshot(TransitionPrepareSnapshot* snapshot) @local {
    alloc::free(mem, snapshot.actions.ptr);
    alloc::free(mem, snapshot.generations.ptr);
    alloc::free(mem, snapshot.free.ptr);
    alloc::free(mem, snapshot.order.ptr);
    alloc::free(mem, snapshot.linear.ptr);
    alloc::free(mem, snapshot.planar.ptr);
    alloc::free(mem, snapshot.inertia.ptr);
}

fn void assert_transition_owner_unchanged(PlaybackView* playback, TransitionPrepareSnapshot* snapshot) @local {
    assert(*playback.action_count == snapshot.action_count && playback.actions.free_count == snapshot.free_count);
    assert(mem::equals((char*)playback.actions.items.ptr, snapshot.actions.ptr, snapshot.actions.len));
    assert(playback.actions.generations == snapshot.generations && playback.actions.free == snapshot.free);
    assert(mem::equals(playback.order, snapshot.order));
    assert(mem::equals((char*)playback.blend_spaces.ptr, snapshot.linear.ptr, snapshot.linear.len));
    assert(mem::equals((char*)playback.blend_spaces_2d.ptr, snapshot.planar.ptr, snapshot.planar.len));
}

fn void test_animation_transition_prepare_full_animator_copies_inputs_and_boolean_source_aliases() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        LayerFixture fixture;
        create_layer_fixture(&fixture, &tracker);
        defer destroy_layer_fixture(&fixture);
        ClipId clip = layer_translation(&fixture, { 1, 2, 3 });
        bool[4] source_membership = { false, true, false, true };
        JointMask source_mask = { .nodes = source_membership[..] };
        for (uint index = 0; index < anim::MAX_ACTIONS; index++) {
            fixture.animator.play(&fixture.assets, clip, { .mask = &source_mask })!!;
        }
        PlaybackView playback = fixture.animator.playback();
        assert(playback.actions.free_count == 0);
        TransitionPrepareSnapshot snapshot = snapshot_transition_owner(&playback);
        defer destroy_transition_snapshot(&snapshot);
        JointMask alias_mask = { .nodes = fixture.animator.action(fixture.animator.order[0]).mask };
        AnimationTargetDesc[16] targets;
        foreach (index, &target : targets) {
            *target = anim::ANIMATION_TARGET_DEFAULT;
            target.clip = clip;
            target.start_time = (float)index / 32;
            target.speed = index ? -0.5f : 1.5f;
            target.weight = 0.25f;
            target.play.mask = &alias_mask;
        }
        uint[3] members = { 0, 1, 2 };
        Vec2[3] points = { { 0, 0 }, { 1, 0 }, { 0, 1 } };
        BlendTriangle[1] triangles = { { .indices = { 2, 1, 0 } } };
        CrowdSpaceAuthoring[1] spaces = { {
            .actions = members[..], .kind = TWO_DIMENSIONAL, .points = points[..],
            .triangles = triangles[..], .parameter_2d = { 0.25f, 0.5f },
            .weight = 0.75f, .speed = -0.25f, .playing = true,
        } };
        PreparedTransition prepared = anim::prepare_animation_transition(
            playback: &playback,
            assets: &fixture.assets,
            desc: { .duration = 0.5f, .actions = targets[..], .spaces = spaces[..] },
            destination: fixture.animator.pose_storage.destination,
            motion_basis: anim::animator_motion_basis(fixture.animator),
        )!!;
        defer anim::release_prepared_transition(&prepared);
        assert_transition_owner_unchanged(&playback, &snapshot);
        assert(prepared.action_count == 16 && prepared.space_count == 1 && prepared.duration == 0.5f);
        assert(prepared.spaces[0].layout.reversed == 1 && prepared.spaces[0].count == 3);
        foreach (index, action : prepared.actions[:prepared.action_count]) {
            assert(action.time == (float)index / 32 && action.clock_time == (double)action.time);
            assert(action.previous_time == action.clock_time && action.published_time == action.time);
            assert(action.speed == (index ? -0.5f : 1.5f) && action.weight == 0.25f);
            assert(prepared.has_boolean_mask[index] && prepared.boolean_masks[index].ptr != alias_mask.nodes.ptr);
            assert(prepared.boolean_masks[index] == source_membership[..]);
        }
        points[0] = { 7, 8 };
        members[0] = 9;
        triangles[0].indices[0] = 99;
        targets[0].start_time = 0.9f;
        assert(prepared.spaces[0].points[0] == (Vec2){} && prepared.spaces[0].members[0] == 0);
        assert(prepared.starts[0] == 0 && prepared.spaces[0].triangles[0].indices[0] == 2);
        playback.mask_storage[..] = false;
        foreach (row : prepared.boolean_masks[:prepared.action_count]) assert(row == source_membership[..]);
        sz acquisitions = tracker.total_allocation_count();
        InstalledTransition installed = anim::install_animation_transition(&playback, &fixture.assets, &prepared);
        assert(tracker.total_allocation_count() == acquisitions);
        assert(installed.count == 16 && *playback.action_count == 16 && playback.actions.free_count == 0);
        foreach (old : snapshot.order[:snapshot.action_count]) assert(!playback.actions.is_live(old));
        foreach (index, id : installed.actions[:installed.count]) {
            assert(c3d::same_id(id, playback.order[index]));
            Action* action = playback.action(id);
            assert(action.mask == source_membership[..] && action.speed == (index ? -0.5f : 1.5f));
            if (index >= 3) assert(action.time == (float)index / 32 && action.weight == 0.25f);
        }
        BlendSpace2D* installed_space = &playback.blend_spaces_2d[0];
        assert(installed_space.count == 3 && installed_space.reversed == 1);
        assert(installed_space.points[0] == (Vec2){} && installed_space.parameter == (Vec2){ 0.25f, 0.5f });
        assert(installed_space.triangles[0].indices[0] == 2 && installed_space.triangles[0].indices[1] == 0);
        assert(installed_space.triangles[0].indices[2] == 1);
        assert(playback.action(installed.actions[0]).weight == 0.1875f);
        assert(playback.action(installed.actions[1]).weight == 0.1875f);
        assert(playback.action(installed.actions[2]).weight == 0.375f);
        assert(playback.action(installed.actions[0]).time == 0 && installed_space.phase == 0);
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_transition_prepare_full_crowd_temporaries_rollback_at_each_allocation() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId clip = layer_translation(&fixture, { 1, 2, 3 });
    String[1] names = { "joint_tip" };
    WeightedJointMask weighted = anim::create_weighted_joint_mask(
        allocator: mem,
        assets: &fixture.assets,
        model: fixture.model,
        names: names[..],
        weights: { 0.5f },
    )!!;
    defer anim::destroy_weighted_joint_mask(&weighted);
    Transform[1] placements = { maths::TRANSFORM_IDENTITY };
    foreach (capacity : (uint[2]){ 4, 16 }) {
        TransitionPrepareProbe probe = { .backing = mem };
        CrowdPlaybackState* state = anim::create_crowd_playback(
            allocator: &probe,
            template: &fixture.assets.model(fixture.model).data,
            placements: placements[..],
            actions_per_instance: capacity,
            event_capacity: 4,
            inertia_enabled: true,
        )!!;
        defer anim::destroy_crowd_playback(state);
        state.count = 1;
        state.model = fixture.model;
        CrowdPlayer player = state.player(state.instance_id(0)!!)!!;
        for (uint index = 0; index < capacity; index++) player.play(&fixture.assets, clip)!!;
        state.inertial_storage.rows[0].control.history_valid = true;
        state.inertial_storage.rows[0].control.previous_dt = 0.125;
        PlaybackView playback = anim::crowd_playback_view(state, &state.slots[0]);
        TransitionPrepareSnapshot snapshot = snapshot_transition_owner(&playback);
        defer destroy_transition_snapshot(&snapshot);
        snapshot.inertia = alloc::clone_slice(mem, ((char*)state.inertial_storage)[:state.inertial_storage.bytes]);
        JointMask alias_mask = { .nodes = player.action(state.slots[0].order[0]).mask };
        AnimationTargetDesc[16] targets;
        foreach (index, &target : targets[:capacity]) {
            *target = anim::ANIMATION_TARGET_DEFAULT;
            target.clip = clip;
            target.play.additive = index % 2 != 0;
            if (index % 3 == 0) {
                target.play.mask = &alias_mask;
            } else {
                target.play.weighted_mask = &weighted;
            }
        }
        AnimationTransitionDesc desc = { .duration = 1, .actions = targets[:capacity] };
        uint baseline = probe.outstanding;
        uint start = probe.attempts;
        PreparedTransition prepared = anim::prepare_animation_transition(
            playback: &playback,
            assets: &fixture.assets,
            desc: desc,
            destination: anim::crowd_destination(state, 0),
            motion_basis: anim::crowd_motion_basis(state, 0, state.slots[0].root_node),
        )!!;
        uint allocations = probe.attempts - start;
        assert(prepared.action_count == capacity && playback.actions.free_count == 0);
        anim::release_prepared_transition(&prepared);
        assert(probe.outstanding == baseline && allocations > capacity);
        for (uint failure = 1; failure <= allocations; failure++) {
            probe.failure = probe.attempts + failure;
            assert(@catch(anim::prepare_animation_transition(
                playback: &playback,
                assets: &fixture.assets,
                desc: desc,
                destination: anim::crowd_destination(state, 0),
                motion_basis: anim::crowd_motion_basis(state, 0, state.slots[0].root_node),
            )) == c3d::CAPACITY_EXCEEDED);
            probe.failure = 0;
            assert(probe.outstanding == baseline);
            assert_transition_owner_unchanged(&playback, &snapshot);
            assert(mem::equals((char*)state.inertial_storage, snapshot.inertia.ptr, snapshot.inertia.len));
        }
        prepared = anim::prepare_animation_transition(
            playback: &playback,
            assets: &fixture.assets,
            desc: desc,
            destination: anim::crowd_destination(state, 0),
            motion_basis: anim::crowd_motion_basis(state, 0, state.slots[0].root_node),
        )!!;
        uint attempts = probe.attempts;
        InstalledTransition installed = anim::install_animation_transition(&playback, &fixture.assets, &prepared);
        assert(probe.attempts == attempts && installed.count == capacity);
        assert(*playback.action_count == capacity && playback.actions.free_count == 0);
        foreach (old : snapshot.order[:snapshot.action_count]) assert(!playback.actions.is_live(old));
        foreach (index, id : installed.actions[:installed.count]) {
            assert(c3d::same_id(id, playback.order[index]));
            Action* action = playback.action(id);
            assert(action.time == targets[index].start_time && action.speed == targets[index].speed);
            assert(action.weight == targets[index].weight && action.additive == targets[index].play.additive);
            if (index % 3 == 0) {
                foreach (included : action.mask) assert(included);
            } else {
                assert(action.weighted_mask == weighted.nodes && action.weighted_mask.ptr != weighted.nodes.ptr);
            }
        }
        anim::release_prepared_transition(&prepared);
    }
}

fn void test_animation_transition_prepare_invalid_targets_and_groups_fail_before_resources() @test {
    TransitionPrepareProbe probe = { .backing = mem };
    LayerFixture fixture;
    create_layer_fixture(&fixture, &probe);
    defer destroy_layer_fixture(&fixture);
    ClipId clip = layer_translation(&fixture, { 1, 2, 3 });
    PlaybackView playback = fixture.animator.playback();
    TransitionPrepareSnapshot snapshot = snapshot_transition_owner(&playback);
    defer destroy_transition_snapshot(&snapshot);
    AnimationTargetDesc[3] targets;
    Vec2[3] points = { { 0, 0 }, { 1, 0 }, { 0, 1 } };
    BlendTriangle[1] triangles = { { .indices = { 0, 1, 2 } } };
    uint[3] members;
    CrowdSpaceAuthoring[1] spaces;
    for (uint invalid = 0; invalid < 9; invalid++) {
        targets[..] = anim::ANIMATION_TARGET_DEFAULT;
        foreach (&target : targets) target.clip = clip;
        members[0] = 0;
        members[1] = 1;
        members[2] = 2;
        triangles[0].indices = { 0, 1, 2 };
        spaces[0] = {
            .actions = members[..], .kind = TWO_DIMENSIONAL, .points = points[..],
            .triangles = triangles[..], .weight = 1, .speed = 1, .playing = true,
        };
        AnimationTransitionDesc desc = { .duration = 1, .actions = targets[..], .spaces = spaces[..] };
        fault expected = c3d::INVALID_ARGUMENT;
        switch (invalid) {
            case 0: desc.duration = float::nan;
            case 1: targets[2].speed = float::inf;
            case 2: targets[2].weight = -1;
            case 3: targets[2].start_time = float::nan;
            case 4:
                targets[2].clip = { .index = uint::max, .generation = 1 };
                expected = c3d::INVALID_ID;
            case 5: members[1] = 0;
            case 6: triangles[0].indices[2] = 99;
            case 7: spaces[0].parameter_2d.x = float::nan;
            case 8: members[2] = 3;
        }
        uint attempts = probe.attempts;
        assert(@catch(anim::prepare_animation_transition(
            playback: &playback,
            assets: &fixture.assets,
            desc: desc,
            destination: fixture.animator.pose_storage.destination,
            motion_basis: anim::animator_motion_basis(fixture.animator),
        )) == expected);
        assert(probe.attempts == attempts);
        assert_transition_owner_unchanged(&playback, &snapshot);
    }
}
