module c3d::test::anim;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::math;

struct MaskPlaybackAllocator (Allocator) @local {
    Allocator backing;
    sz remaining;
    sz outstanding;
    sz acquisitions;
    sz releases;
}

struct MaskPlaybackSnapshot @local {
    char[] actions;
    uint[] generations;
    uint[] free;
    AnimationActionId[] order;
    uint action_count;
    uint free_count;
}

fn void*? MaskPlaybackAllocator.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    if (self.remaining <= 0) return mem::OUT_OF_MEMORY~;
    self.remaining--;
    void* pointer = self.backing.acquire(size, init_type, alignment)!;
    self.outstanding++;
    self.acquisitions++;
    return pointer;
}

fn void*? MaskPlaybackAllocator.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    if (self.remaining <= 0) return mem::OUT_OF_MEMORY~;
    self.remaining--;
    return self.backing.resize(pointer, size, alignment);
}

fn void MaskPlaybackAllocator.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
    self.outstanding--;
    self.releases++;
}

fn ClipId mask_playback_clip(LayerFixture* fixture) @local {
    float[2] times = { 0, 1 };
    float[6] translation = { 8, 9, 4, 8, 9, 4 };
    float[8] rotation = { 0, 1, 0, 0, 0, 1, 0, 0 };
    float[6] scale = { 5, 9, 13, 5, 9, 13 };
    float[2] morph = { 0.9f, 0.9f };
    float[6] root = { 0, 0, 0, 8, 0, 4 };
    Track[5] tracks = {
        make_track(
            path: TargetPath.TRANSLATION,
            interpolation: Interpolation.STEP,
            times: times[..],
            values: translation[..],
        ),
        make_track(
            path: TargetPath.ROTATION,
            interpolation: Interpolation.STEP,
            times: times[..],
            values: rotation[..],
        ),
        make_track(
            path: TargetPath.SCALE,
            interpolation: Interpolation.STEP,
            times: times[..],
            values: scale[..],
        ),
        make_track(
            path: TargetPath.MORPH_WEIGHTS,
            interpolation: Interpolation.STEP,
            times: times[..],
            values: morph[..],
            target: 1,
        ),
        make_track(
            path: TargetPath.TRANSLATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: root[..],
            target: 2,
        ),
    };
    uint[3] targets = { 3, 1, 2 };
    ClipId clip = add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
    ClipEvent[2] events = { { .time = 0.25f, .id = 71 }, { .time = 0.4f, .id = 72 } };
    fixture.assets.set_clip_events(clip, events[..])!!;
    return clip;
}

fn WeightedJointMask mask_playback_weights(LayerFixture* fixture) @local {
    String[3] names = { "joint_root", "joint_tip", fixture.assets.model(fixture.model).data.nodes[1].name };
    float[3] weights = { 0.5f, 0.5f, 0.25f };
    return anim::create_weighted_joint_mask(
        allocator: mem,
        assets: &fixture.assets,
        model: fixture.model,
        names: names[..],
        weights: weights[..],
    )!!;
}

fn CrowdPlaybackState* mask_playback_crowd(
    LayerFixture* fixture,
    Allocator allocator,
    Transform[] placements,
) @local {
    CrowdPlaybackState* state = anim::create_crowd_playback(
        allocator: allocator,
        template: &fixture.assets.model(fixture.model).data,
        placements: placements,
        actions_per_instance: 4,
        event_capacity: 8,
    )!!;
    state.model = fixture.model;
    state.count = (uint)placements.len;
    return state;
}

fn MaskPlaybackSnapshot snapshot_mask_playback(PlaybackView* playback) @local {
    MaskPlaybackSnapshot snapshot = {
        .action_count = *playback.action_count,
        .free_count = playback.actions.free_count,
        .actions = alloc::new_array(mem, char, playback.actions.items.len * Action::size),
        .generations = alloc::new_array(mem, uint, playback.actions.generations.len),
        .free = alloc::new_array(mem, uint, playback.actions.free.len),
        .order = alloc::new_array(mem, AnimationActionId, playback.order.len),
    };
    snapshot.actions[..] = ((char*)playback.actions.items.ptr)[:snapshot.actions.len];
    snapshot.generations[..] = playback.actions.generations[..];
    snapshot.free[..] = playback.actions.free[..];
    snapshot.order[..] = playback.order[..];
    return snapshot;
}

fn void destroy_mask_playback_snapshot(MaskPlaybackSnapshot* snapshot) @local {
    alloc::free(mem, snapshot.actions.ptr);
    alloc::free(mem, snapshot.generations.ptr);
    alloc::free(mem, snapshot.free.ptr);
    alloc::free(mem, snapshot.order.ptr);
}

fn void assert_mask_playback_unchanged(PlaybackView* playback, MaskPlaybackSnapshot* snapshot) @local {
    assert(*playback.action_count == snapshot.action_count);
    assert(playback.actions.free_count == snapshot.free_count);
    assert(mem::equals((char*)playback.actions.items.ptr, snapshot.actions.ptr, snapshot.actions.len));
    assert(playback.actions.generations == snapshot.generations);
    assert(playback.actions.free == snapshot.free);
    assert(mem::equals(playback.order.ptr, snapshot.order.ptr, snapshot.order.len * AnimationActionId::size));
}

fn void test_animation_authoring_mask_copied_all_channel_crowd_parity_and_zero_weight_events() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        MaskPlaybackAllocator allocator = { .backing = &tracker, .remaining = sz::max };
        LayerFixture fixture;
        create_layer_fixture(&fixture, &allocator);
        defer destroy_layer_fixture(&fixture);
        ClipId clip = mask_playback_clip(&fixture);
        ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
        Transform[2] placements;
        placements[..] = maths::TRANSFORM_IDENTITY;
        CrowdPlaybackState* state = mask_playback_crowd(&fixture, &allocator, placements[..]);
        defer anim::destroy_crowd_playback(state);
        CrowdPlayer first = state.player(state.instance_id(0)!!)!!;
        CrowdPlayer zero = state.player(state.instance_id(1)!!)!!;
        AnimationActionId ordinary;
        AnimationActionId crowd_action;
        AnimationActionId zero_action;
        {
            WeightedJointMask mask = mask_playback_weights(&fixture);
            defer anim::destroy_weighted_joint_mask(&mask);
            ordinary = fixture.animator.play(&fixture.assets, clip, {
                .weighted_mask = &mask,
                .root_motion = RootMotion.EXTRACT,
            })!!;
            crowd_action = first.play(&fixture.assets, clip, {
                .weighted_mask = &mask,
                .root_motion = RootMotion.EXTRACT,
            })!!;
            assert(fixture.animator.action(ordinary).weighted_mask.ptr != mask.nodes.ptr);
            assert(first.action(crowd_action).weighted_mask.ptr != mask.nodes.ptr);
            assert(first.action(crowd_action).weighted_mask.ptr != fixture.animator.action(ordinary).weighted_mask.ptr);
            mask.nodes[..] = 0;
            zero_action = zero.play(&fixture.assets, clip, {
                .weighted_mask = &mask,
                .root_motion = RootMotion.EXTRACT,
            })!!;
        }
        fixture.animator.action(ordinary).weight = 0.5f;
        first.action(crowd_action).weight = 0.5f;
        zero.action(zero_action).weight = 0.5f;
        sz acquisitions = allocator.acquisitions;
        sz releases = allocator.releases;
        anim::update(&fixture.assets, &fixture.scene, 0.5f);
        state.update(&fixture.assets, 0.5f);
        assert(allocator.acquisitions == acquisitions && allocator.releases == releases);
        Transform tip = instance.present_node(3).local;
        assert(tip.position == (Vec3){ 2, 3, 1 });
        assert(tip.scale == (Vec3){ 2, 3, 4 });
        Vec3 facing = tip.rotation.rotate_vec3({ 1, 0, 0 });
        assert((facing - (Vec3){ 0.8f, 0, -0.6f }).length() < 1e-6f);
        assert(math::abs(fixture.scene.get(instance.present_node(1), Mesh).morph_weights[0] - 0.55f) < 1e-6f);
        assert(fixture.animator.root_motion.translation == (Vec3){ 1, 0, 0.5f });
        assert(instance.present_node(2).local.position == (Vec3){});
        foreach (sz index, expected : instance.base_pose) {
            Transform actual = instance.present_node((uint)index).local;
            assert(state.poses[index].position == actual.position);
            assert(state.poses[index].rotation.v == actual.rotation.v);
            assert(state.poses[index].scale == actual.scale);
            Transform masked = state.poses[instance.base_pose.len + index];
            assert(masked.position == expected.position && masked.rotation.v == expected.rotation.v);
            assert(masked.scale == expected.scale);
        }
        assert(state.logical_weights[0][0] == fixture.scene.get(instance.present_node(1), Mesh).morph_weights[0]);
        assert(state.logical_weights[1][0] == 0.5f);
        assert(state.slots[0].root_motion.translation == fixture.animator.root_motion.translation);
        assert(state.slots[1].root_motion.translation == (Vec3){});
        assert(fixture.animator.event_count == 2 && state.event_count == 4);
        assert(fixture.animator.events[0].id == 71 && fixture.animator.events[1].id == 72);
        foreach (sz index, event : state.events[:state.event_count]) {
            assert(event.instance.index == index / 2);
            assert(event.event.id == (index % 2 ? 72u : 71u));
            assert(c3d::same_id(event.event.clip, clip));
        }
        anim::update(&fixture.assets, &fixture.scene, 0);
        state.update(&fixture.assets, 0);
        assert(fixture.animator.event_count == 0 && state.event_count == 0);
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_authoring_mask_play_allocation_failures_preserve_both_owner_pools() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        MaskPlaybackAllocator allocator = { .backing = &tracker, .remaining = sz::max };
        LayerFixture fixture;
        create_layer_fixture(&fixture, &allocator);
        defer destroy_layer_fixture(&fixture);
        ClipId clip = mask_playback_clip(&fixture);
        WeightedJointMask mask = mask_playback_weights(&fixture);
        defer anim::destroy_weighted_joint_mask(&mask);
        Transform[1] placements = { maths::TRANSFORM_IDENTITY };
        CrowdPlaybackState* state = mask_playback_crowd(&fixture, &allocator, placements[..]);
        defer anim::destroy_crowd_playback(state);
        CrowdPlayer player = state.player(state.instance_id(0)!!)!!;
        fixture.animator.play(&fixture.assets, clip)!!;
        player.play(&fixture.assets, clip)!!;
        for (uint crowd = 0; crowd < 2; crowd++) {
            PlaybackView playback;
            if (crowd) {
                playback = anim::crowd_playback_view(state, &state.slots[0]);
            } else {
                playback = fixture.animator.playback();
            }
            MaskPlaybackSnapshot snapshot = snapshot_mask_playback(&playback);
            defer destroy_mask_playback_snapshot(&snapshot);
            for (uint additive = 0; additive < 2; additive++) {
                for (sz allowance = 0; allowance < (additive ? 3 : 2); allowance++) {
                    allocator.remaining = allowance;
                    sz outstanding = allocator.outstanding;
                    PlayDesc desc = { .weighted_mask = &mask, .additive = additive != 0 };
                    AnimationActionId? attempt;
                    if (crowd) {
                        attempt = player.play(&fixture.assets, clip, desc);
                    } else {
                        attempt = fixture.animator.play(&fixture.assets, clip, desc);
                    }
                    if (catch excuse = attempt) {
                        assert(excuse == c3d::CAPACITY_EXCEEDED);
                    } else {
                        assert(false);
                    }
                    assert(allocator.outstanding == outstanding);
                    assert_mask_playback_unchanged(&playback, &snapshot);
                    assert(fixture.animator.event_count == 0 && state.event_count == 0);
                }
            }
            allocator.remaining = sz::max;
        }
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_authoring_mask_rows_release_on_stop_fade_reset_and_owner_removal() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        LayerFixture fixture;
        create_layer_fixture(&fixture, &tracker);
        defer destroy_layer_fixture(&fixture);
        ClipId clip = mask_playback_clip(&fixture);
        WeightedJointMask mask = mask_playback_weights(&fixture);
        defer anim::destroy_weighted_joint_mask(&mask);
        sz baseline = tracker.allocated();
        AnimationActionId first = fixture.animator.play(&fixture.assets, clip, { .weighted_mask = &mask })!!;
        sz expected = (sz)(fixture.assets.clip(clip).data.tracks.len * uint::size + mask.nodes.len * float::size);
        assert(tracker.allocated() == baseline + expected);
        fixture.animator.stop(first)!!;
        assert(tracker.allocated() == baseline && !fixture.animator.actions.is_live(first));
        AnimationActionId fading = fixture.animator.play(&fixture.assets, clip, { .weighted_mask = &mask })!!;
        fixture.animator.stop(fading, 0.1f)!!;
        anim::update(&fixture.assets, &fixture.scene, 0.2f);
        assert(tracker.allocated() == baseline && !fixture.animator.actions.is_live(fading));
        fixture.animator.play(&fixture.assets, clip, { .weighted_mask = &mask, .additive = true })!!;
        sz before_remove = tracker.allocated();
        fixture.scene.remove_component(fixture.root, Animator);
        assert(tracker.allocated() < before_remove - expected);
        Transform[1] placements = { maths::TRANSFORM_IDENTITY };
        CrowdPlaybackState* state = mask_playback_crowd(&fixture, &tracker, placements[..]);
        defer anim::destroy_crowd_playback(state);
        CrowdPlayer player = state.player(state.instance_id(0)!!)!!;
        baseline = tracker.allocated();
        AnimationActionId action = player.play(&fixture.assets, clip, { .weighted_mask = &mask })!!;
        assert(tracker.allocated() == baseline + expected);
        player.stop(action)!!;
        assert(tracker.allocated() == baseline);
        player.play(&fixture.assets, clip, { .weighted_mask = &mask, .additive = true })!!;
        anim::reset_crowd_playback_slot(state, 0);
        assert(tracker.allocated() == baseline && state.slots[0].action_count == 0);
        assert(@catch(state.player(player.instance)) == c3d::INVALID_ID);
        player = state.player(state.instance_id(0)!!)!!;
        player.play(&fixture.assets, clip, { .weighted_mask = &mask })!!;
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_authoring_mask_mutually_exclusive_and_foreign_layout_fail_atomically() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId clip = mask_playback_clip(&fixture);
    WeightedJointMask mask = mask_playback_weights(&fixture);
    defer anim::destroy_weighted_joint_mask(&mask);
    bool[4] included = { true, true, true, true };
    JointMask boolean = { .nodes = included[..] };
    fixture.animator.play(&fixture.assets, clip)!!;
    PlaybackView playback = fixture.animator.playback();
    MaskPlaybackSnapshot snapshot = snapshot_mask_playback(&playback);
    defer destroy_mask_playback_snapshot(&snapshot);
    if (catch excuse = fixture.animator.play(&fixture.assets, clip, {
        .mask = &boolean,
        .weighted_mask = &mask,
    })) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    assert_mask_playback_unchanged(&playback, &snapshot);
    mask.model.index++;
    if (catch excuse = fixture.animator.play(&fixture.assets, clip, { .weighted_mask = &mask })) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    assert_mask_playback_unchanged(&playback, &snapshot);
    mask.model.index--;
    mask.model_parents[3] = 0;
    if (catch excuse = fixture.animator.play(&fixture.assets, clip, { .weighted_mask = &mask })) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    assert_mask_playback_unchanged(&playback, &snapshot);
}
