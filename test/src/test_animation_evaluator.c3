module c3d::test::anim;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::maths;
import c3d::scene;

struct PoseFaultAllocator (Allocator) @local {
    Allocator backing;
    sz remaining;
    sz outstanding;
}

struct TaggedEvent @local {
    uint prefix;
    FiredEvent event;
    uint suffix;
}

fn void*? PoseFaultAllocator.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    if (self.remaining <= 0) return mem::OUT_OF_MEMORY~;
    self.remaining--;
    void* allocation = self.backing.acquire(size, init_type, alignment)!;
    self.outstanding++;
    return allocation;
}

fn void*? PoseFaultAllocator.resize(
    &self,
    void* pointer,
    sz new_size,
    sz alignment,
) @dynamic {
    if (self.remaining <= 0) return mem::OUT_OF_MEMORY~;
    self.remaining--;
    return self.backing.resize(pointer, new_size, alignment);
}

fn void PoseFaultAllocator.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
    self.outstanding--;
}

fn ClipId evaluator_clip(LayerFixture* fixture) @local {
    float[2] times = { 0, 1 };
    float[6] values = { 0, 0, 0, 1, 0, 0 };
    Track[1] tracks = {
        make_track(
            path: TargetPath.TRANSLATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: values[..],
        ),
    };
    uint[1] targets = { 2 };
    return add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
}

fn void test_evaluator_pose_storage_rolls_back_each_allocation_failure() @test {
    Transform[3] baseline;
    baseline[..] = maths::TRANSFORM_IDENTITY;
    uint[2] mesh_nodes = { 1, 2 };
    float[2] first = { 0.2f, 0.7f };
    float[5] second = { 0.1f, 0.2f, 0.3f, 0.4f, 0.5f };
    float[][2] weights = { first[..], second[..] };
    bool reached_success;
    for (sz allowance = 0; allowance < 64; allowance++) {
        PoseFaultAllocator allocator = { .backing = mem, .remaining = allowance };
        PoseStorage*? attempt = anim::create_pose_storage_try(
            allocator: &allocator,
            base_pose: baseline[..],
            mesh_nodes: mesh_nodes[..],
            base_morph_weights: weights[..],
            event_capacity: 16,
        );
        if (catch failure = attempt) {
            assert(failure == c3d::CAPACITY_EXCEEDED);
            assert(allocator.outstanding == 0);
            continue;
        }
        PoseStorage* storage = attempt;
        assert(storage.scratch.sample.len == 5);
        assert(storage.destination.mesh_indices[0] == uint::max);
        assert(storage.destination.mesh_indices[1] == 0 && storage.destination.mesh_indices[2] == 1);
        anim::destroy_pose_storage(&allocator, storage);
        assert(allocator.outstanding == 0);
        reached_success = true;
        break;
    }
    assert(reached_success);
}

fn void test_evaluator_event_growth_uses_strided_retained_capacity_and_zero_drops() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        LayerFixture fixture;
        create_layer_fixture(&fixture, &tracker);
        defer destroy_layer_fixture(&fixture);
        ClipId clip = evaluator_clip(&fixture);
        ClipEvent[1] initial = { { .time = 0.25f, .id = 1 } };
        fixture.assets.set_clip_events(clip, initial[..])!!;
        fixture.animator.play(&fixture.assets, clip)!!;
        ClipEvent[40] expanded;
        foreach (uint index, &event : expanded) *event = { .time = 0.25f, .id = index + 1 };
        fixture.assets.set_clip_events(clip, expanded[..])!!;

        TaggedEvent[16] output;
        foreach (&entry : output) {
            entry.prefix = 0x12345678;
            entry.suffix = 0x87654321;
        }
        PlaybackView playback = fixture.animator.playback();
        sz allocations = tracker.total_allocation_count();
        PoseReport report = anim::evaluate_pose(
            playback: &playback,
            assets: &fixture.assets,
            destination: fixture.animator.pose_storage.destination,
            scratch: fixture.animator.pose_storage.scratch,
            dt: 3.25f,
            events: { .first = &output[0].event, .stride = TaggedEvent::size, .capacity = output.len },
        );
        assert(report.events.count == 16 && report.events.dropped == 104);
        foreach (uint index, entry : output) {
            assert(entry.prefix == 0x12345678 && entry.suffix == 0x87654321);
            assert(entry.event.id == index + 1 && entry.event.time == 0.25f);
        }
        assert(tracker.total_allocation_count() == allocations);

        report = anim::evaluate_pose(
            playback: &playback,
            assets: &fixture.assets,
            destination: fixture.animator.pose_storage.destination,
            scratch: fixture.animator.pose_storage.scratch,
            dt: 3,
            events: {},
        );
        assert(report.events.count == 0 && report.events.dropped == 120);
        assert(tracker.total_allocation_count() == allocations);
    }
    assert(!tracker.has_leaks());
}

fn void test_evaluator_rejected_root_index_and_failed_play_leave_owner_unchanged() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId clip = evaluator_clip(&fixture);
    PlaybackView playback = fixture.animator.playback();
    playback.root_node = (uint)fixture.animator.nodes.len;
    if (catch failure = playback.play(
        assets: &fixture.assets,
        clip: clip,
        desc: { .root_motion = RootMotion.EXTRACT },
        destination: fixture.animator.pose_storage.destination,
        motion_basis: {},
    )) {
        assert(failure == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    assert(fixture.animator.action_count == 0);

    playback.root_node = fixture.animator.root_node;
    for (sz allowance = 0; allowance < 2; allowance++) {
        PoseFaultAllocator allocator = { .backing = mem, .remaining = allowance };
        playback.allocator = &allocator;
        if (catch failure = playback.play(
            assets: &fixture.assets,
            clip: clip,
            desc: { .additive = true },
            destination: fixture.animator.pose_storage.destination,
            motion_basis: {},
        )) {
            assert(failure == c3d::CAPACITY_EXCEEDED);
        } else {
            assert(false);
        }
        assert(allocator.outstanding == 0 && fixture.animator.action_count == 0);
    }
}

fn void test_evaluator_absent_wide_morph_tracks_skip_before_sample_slicing() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);
    ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
    fixture.scene.remove(instance.present_node(1));
    float[2] times = { 0, 1 };
    float[16] weights;
    weights[..] = 0.5f;
    float[6] positions = { 0, 0, 0, 2, 0, 0 };
    Track[2] tracks = {
        make_track(
            path: TargetPath.MORPH_WEIGHTS,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: weights[..],
        ),
        make_track(
            path: TargetPath.TRANSLATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: positions[..],
            target: 1,
        ),
    };
    uint[2] targets = { 1, 3 };
    ClipId clip = add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
    fixture.animator.play(&fixture.assets, clip)!!;
    fixture.animator.play(&fixture.assets, clip, { .additive = true })!!;
    assert(fixture.animator.pose_storage.scratch.sample.len == 4);
    anim::update(&fixture.assets, &fixture.scene, 0.5f);
    assert(instance.present_node(3).local.position.x == 2);
}

fn void test_evaluator_prepared_actions_leave_live_pool_unchanged_until_installation() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId clip = evaluator_clip(&fixture);
    AnimationActionId previous = fixture.animator.play(&fixture.assets, clip)!!;
    fixture.animator.action(previous).time = 0.375f;
    PlaybackView playback = fixture.animator.playback();
    uint[anim::MAX_ACTIONS] generations;
    generations[..] = playback.actions.generations[..];
    Action prior = *playback.action(previous);
    for (sz allowance = 0; allowance < 2; allowance++) {
        PoseFaultAllocator allocator = { .backing = mem, .remaining = allowance };
        if (catch failure = anim::prepare_playback_action(
            allocator: &allocator,
            assets: &fixture.assets,
            clip: clip,
            desc: { .additive = true },
            destination: fixture.animator.pose_storage.destination,
            motion_basis: {},
            root_node: fixture.animator.root_node,
        )) {
            assert(failure == c3d::CAPACITY_EXCEEDED);
        } else {
            assert(false);
        }
        assert(allocator.outstanding == 0);
        assert(fixture.animator.action_count == 1 && c3d::same_id(fixture.animator.order[0], previous));
        assert(playback.action(previous).time == prior.time
          && playback.action(previous).cursors.ptr == prior.cursors.ptr);
        foreach (index, generation : generations) assert(playback.actions.generations[index] == generation);
    }

    Action abandoned = anim::prepare_playback_action(
        allocator: fixture.scene.allocator,
        assets: &fixture.assets,
        clip: clip,
        desc: { .additive = true },
        destination: fixture.animator.pose_storage.destination,
        motion_basis: {},
        root_node: fixture.animator.root_node,
    )!!;
    assert(abandoned.cursors.len == 1 && abandoned.reference.len == 3);
    assert(fixture.animator.action_count == 1);
    anim::release_prepared_action(fixture.scene.allocator, &abandoned);
    assert(!abandoned.cursors.ptr && !abandoned.reference.ptr);
    assert(playback.action(previous).time == prior.time);

    bool[] membership = alloc::new_array(mem, bool, fixture.animator.nodes.len);
    defer alloc::free(mem, membership.ptr);
    membership[..] = true;
    JointMask mask = { .nodes = membership };
    Action prepared = anim::prepare_playback_action(
        allocator: fixture.scene.allocator,
        assets: &fixture.assets,
        clip: clip,
        desc: { .mask = &mask },
        destination: fixture.animator.pose_storage.destination,
        motion_basis: {},
        root_node: fixture.animator.root_node,
    )!!;
    membership[3] = false;
    assert(fixture.animator.action_count == 1 && playback.actions.is_live(previous));
    playback.stop(previous)!!;
    AnimationActionId installed = anim::install_playback_action(&playback, prepared, &mask);
    assert(installed.index == previous.index && installed.generation != previous.generation);
    assert(!playback.actions.is_live(previous) && fixture.animator.action_count == 1);
    assert(playback.action(installed).cursors.ptr == prepared.cursors.ptr);
    assert(!playback.action(installed).mask[3]);
    membership[3] = true;
    assert(!playback.action(installed).mask[3]);
}
