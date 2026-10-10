module c3d::test::anim;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::math;

struct SpaceAllocationProbe (Allocator) @local {
    Allocator backing;
    sz remaining;
    sz outstanding;
    sz attempts;
}

struct SpacePoolSnapshot @local {
    char[] actions;
    uint[] generations;
    uint[] free;
    AnimationActionId[] order;
    char[] linear_groups;
    char[] planar_groups;
    uint action_count;
    uint free_count;
}

struct SpaceOutput @local {
    Transform[4] poses;
    float morph;
}

struct SpaceTopology @local {
    Vec2[16] coordinates;
    BlendTriangle[27] triangles;
    uint count;
    uint triangle_count;
}

fn void*? SpaceAllocationProbe.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    self.attempts++;
    if (self.remaining <= 0) return mem::OUT_OF_MEMORY~;
    self.remaining--;
    void* pointer = self.backing.acquire(size, init_type, alignment)!;
    self.outstanding++;
    return pointer;
}

fn void*? SpaceAllocationProbe.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    self.attempts++;
    if (self.remaining <= 0) return mem::OUT_OF_MEMORY~;
    self.remaining--;
    return self.backing.resize(pointer, size, alignment);
}

fn void SpaceAllocationProbe.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
    self.outstanding--;
}

fn ClipId space_channel_clip(LayerFixture* fixture, uint member, float duration) @local {
    float[2] times = { 0, duration };
    float[6] positions = { (float)member * 10, 0, 0, (float)member * 10, 0, 0 };
    float[6] scales;
    scales[..] = 1 + (float)member;
    Vec4 rotation = member == 0 ? (Vec4){ 0, 0, 0, 1 }
      : member == 1 ? (Vec4){ 0, 0, 0.6f, 0.8f } : (Vec4){ 0, 0, 0.8f, 0.6f };
    float[8] rotations = {
        rotation.x, rotation.y, rotation.z, rotation.w,
        rotation.x, rotation.y, rotation.z, rotation.w,
    };
    float[2] morph = { (float)member * 0.25f, (float)member * 0.25f };
    Track[4] tracks = {
        make_track(
            path: TargetPath.TRANSLATION,
            interpolation: Interpolation.STEP,
            times: times[..],
            values: positions[..],
        ),
        make_track(
            path: TargetPath.ROTATION,
            interpolation: Interpolation.STEP,
            times: times[..],
            values: rotations[..],
        ),
        make_track(
            path: TargetPath.SCALE,
            interpolation: Interpolation.STEP,
            times: times[..],
            values: scales[..],
        ),
        make_track(
            path: TargetPath.MORPH_WEIGHTS,
            interpolation: Interpolation.STEP,
            times: times[..],
            values: morph[..],
            target: 1,
        ),
    };
    uint[2] targets = { 3, 1 };
    ClipId clip = add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: duration,
    );
    ClipEvent[3] events = {
        { .time = 0, .id = 100 + member * 10 },
        { .time = duration * 0.25f, .id = 101 + member * 10 },
        { .time = duration, .id = 102 + member * 10 },
    };
    fixture.assets.set_clip_events(clip, events[..])!!;
    return clip;
}

fn ClipId[3] space_clips(LayerFixture* fixture) @local {
    return {
        space_channel_clip(fixture, 0, 1),
        space_channel_clip(fixture, 1, 2),
        space_channel_clip(fixture, 2, 4),
    };
}

fn SpaceTopology space_triangle() @local {
    return {
        .coordinates = { [0] = { 0, 0 }, [1] = { 2, 0 }, [2] = { 0, 2 } },
        .triangles = { [0] = { .indices = { 0, 1, 2 } } },
        .count = 3,
        .triangle_count = 1,
    };
}

fn SpaceTopology space_grid(uint width, uint height) @local {
    SpaceTopology topology = { .count = width * height };
    for (uint y = 0; y < height; y++) for (uint x = 0; x < width; x++) {
        topology.coordinates[y * width + x] = { (float)x, (float)y };
    }
    for (uint y = 0; y + 1 < height; y++) for (uint x = 0; x + 1 < width; x++) {
        uint a = y * width + x;
        uint b = a + 1;
        uint c = a + width;
        uint d = c + 1;
        topology.triangles[topology.triangle_count++] = { .indices = { a, b, d } };
        topology.triangles[topology.triangle_count++] = { .indices = { a, d, c } };
    }
    return topology;
}

fn SpaceTopology space_maximal(uint count) @local {
    SpaceTopology topology = space_triangle();
    topology.coordinates[1] = { 4, 0 };
    topology.coordinates[2] = { 0, 4 };
    while (topology.count < count) {
        BlendTriangle cell = topology.triangles[0];
        uint sample = topology.count++;
        topology.coordinates[sample] = (topology.coordinates[cell.indices[0]]
          + topology.coordinates[cell.indices[1]] + topology.coordinates[cell.indices[2]]) / 3.0f;
        topology.triangles[0] = { .indices = { cell.indices[0], cell.indices[1], sample } };
        topology.triangles[topology.triangle_count++] = { .indices = { cell.indices[1], cell.indices[2], sample } };
        topology.triangles[topology.triangle_count++] = { .indices = { cell.indices[2], cell.indices[0], sample } };
    }
    return topology;
}

fn CrowdPlaybackState* space_crowd(
    LayerFixture* fixture,
    Allocator allocator = mem,
    uint capacity = 16,
) @local {
    Transform[1] placements = { maths::TRANSFORM_IDENTITY };
    CrowdPlaybackState* state = anim::create_crowd_playback(
        allocator: allocator,
        template: &fixture.assets.model(fixture.model).data,
        placements: placements[..],
        actions_per_instance: capacity,
        event_capacity: anim::MAX_FIRED_EVENTS,
    )!!;
    state.model = fixture.model;
    state.count = 1;
    return state;
}

fn BlendSpace2D*? space_add(
    LayerFixture* fixture,
    CrowdPlayer* crowd,
    ClipId[] clips,
    SpaceTopology* topology,
    PlayDesc desc = anim::PLAY_DESC_DEFAULT,
) @local {
    if (crowd) {
        return crowd.add_blend_space_2d(
            assets: &fixture.assets,
            clips: clips,
            coordinates: topology.coordinates[:topology.count],
            triangles: topology.triangles[:topology.triangle_count],
            desc: desc,
        );
    }
    return fixture.animator.add_blend_space_2d(
        assets: &fixture.assets,
        clips: clips,
        coordinates: topology.coordinates[:topology.count],
        triangles: topology.triangles[:topology.triangle_count],
        desc: desc,
    );
}

fn void space_stop(LayerFixture* fixture, CrowdPlayer* crowd, BlendSpace2D* space) @local {
    if (crowd) {
        crowd.stop_blend_space_2d(space)!!;
    } else {
        fixture.animator.stop_blend_space_2d(space)!!;
    }
}

fn PlaybackView space_playback(LayerFixture* fixture, CrowdPlayer* crowd) @local {
    if (crowd) return anim::crowd_playback_view(crowd.state, &crowd.state.slots[crowd.instance.index]);
    return fixture.animator.playback();
}

fn SpaceOutput space_output(LayerFixture* fixture, CrowdPlayer* crowd) @local {
    SpaceOutput output;
    if (crowd) {
        foreach (uint index, &pose : output.poses) *pose = crowd.state.poses[index];
        output.morph = crowd.state.logical_weights[0][0];
    } else {
        ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
        foreach (uint index, &pose : output.poses) *pose = instance.present_node(index).local;
        output.morph = fixture.scene.get(instance.present_node(1), Mesh).morph_weights[0];
    }
    return output;
}

fn void space_assert_same_output(SpaceOutput actual, SpaceOutput expected) @local {
    foreach (uint index, pose : actual.poses) {
        assert(pose.position == expected.poses[index].position);
        assert(pose.rotation.v == expected.poses[index].rotation.v);
        assert(pose.scale == expected.poses[index].scale);
    }
    assert(actual.morph == expected.morph);
}

fn SpacePoolSnapshot space_snapshot(PlaybackView* playback) @local {
    SpacePoolSnapshot snapshot = {
        .actions = alloc::new_array(mem, char, playback.actions.items.len * Action::size),
        .generations = alloc::new_array(mem, uint, playback.actions.generations.len),
        .free = alloc::new_array(mem, uint, playback.actions.free.len),
        .order = alloc::new_array(mem, AnimationActionId, playback.order.len),
        .linear_groups = alloc::new_array(mem, char, playback.blend_spaces.len * BlendSpace1D::size),
        .planar_groups = alloc::new_array(
            allocator: mem,
            $Type: char,
            elements: (sz)anim::blend_space_2d_storage_bytes((uint)playback.actions.items.len),
        ),
        .action_count = *playback.action_count,
        .free_count = playback.actions.free_count,
    };
    snapshot.actions[..] = ((char*)playback.actions.items.ptr)[:snapshot.actions.len];
    snapshot.generations[..] = playback.actions.generations[..];
    snapshot.free[..] = playback.actions.free[..];
    snapshot.order[..] = playback.order[..];
    snapshot.linear_groups[..] = ((char*)playback.blend_spaces.ptr)[:snapshot.linear_groups.len];
    snapshot.planar_groups[..] = ((char*)playback.blend_spaces_2d.ptr)[:snapshot.planar_groups.len];
    return snapshot;
}

fn void space_destroy_snapshot(SpacePoolSnapshot* snapshot) @local {
    alloc::free(mem, snapshot.actions.ptr);
    alloc::free(mem, snapshot.generations.ptr);
    alloc::free(mem, snapshot.free.ptr);
    alloc::free(mem, snapshot.order.ptr);
    alloc::free(mem, snapshot.linear_groups.ptr);
    alloc::free(mem, snapshot.planar_groups.ptr);
}

fn void space_assert_unchanged(PlaybackView* playback, SpacePoolSnapshot* snapshot) @local {
    assert(*playback.action_count == snapshot.action_count && playback.actions.free_count == snapshot.free_count);
    assert(mem::equals((char*)playback.actions.items.ptr, snapshot.actions.ptr, snapshot.actions.len));
    assert(playback.actions.generations == snapshot.generations && playback.actions.free == snapshot.free);
    assert(mem::equals(playback.order.ptr, snapshot.order.ptr, snapshot.order.len * AnimationActionId::size));
    assert(mem::equals((char*)playback.blend_spaces.ptr, snapshot.linear_groups.ptr, snapshot.linear_groups.len));
    assert(mem::equals((char*)playback.blend_spaces_2d.ptr, snapshot.planar_groups.ptr, snapshot.planar_groups.len));
}

fn void space_expect_fault(
    LayerFixture* fixture,
    CrowdPlayer* crowd,
    ClipId[] clips,
    SpaceTopology* topology,
    fault expected,
    PlayDesc desc = anim::PLAY_DESC_DEFAULT,
) @local {
    PlaybackView playback = space_playback(fixture, crowd);
    SpacePoolSnapshot snapshot = space_snapshot(&playback);
    defer space_destroy_snapshot(&snapshot);
    SpaceOutput output = space_output(fixture, crowd);
    if (catch failure = space_add(
        fixture: fixture,
        crowd: crowd,
        clips: clips,
        topology: topology,
        desc: desc,
    )) {
        assert(failure == expected);
    } else {
        unreachable();
    }
    space_assert_unchanged(&playback, &snapshot);
    space_assert_same_output(space_output(fixture, crowd), output);
}

fn void space_assert_events(
    LayerFixture* fixture,
    CrowdPlaybackState* state,
    uint[] ids,
    uint dropped = 0,
) @local {
    assert(fixture.animator.event_count == ids.len && fixture.animator.events_dropped == dropped);
    assert(state.event_count == ids.len && state.events_dropped == dropped);
    foreach (uint index, id : ids) {
        assert(fixture.animator.events[index].id == id && state.events[index].event.id == id);
        assert(state.events[index].instance.index == 0 && state.events[index].instance.generation == 1);
        assert(c3d::same_id(fixture.animator.events[index].clip, state.events[index].event.clip));
    }
}

fn void space_update_both(LayerFixture* fixture, CrowdPlaybackState* state, float dt) @local {
    anim::update(&fixture.assets, &fixture.scene, dt);
    state.update(&fixture.assets, dt);
}

fn WeightedJointMask space_full_mask(LayerFixture* fixture) @local {
    String[2] names = { "joint_tip", fixture.assets.model(fixture.model).data.nodes[1].name };
    float[2] weights = { 1, 1 };
    return anim::create_weighted_joint_mask(
        allocator: mem,
        assets: &fixture.assets,
        model: fixture.model,
        names: names[..],
        weights: weights[..],
    )!!;
}


fn void test_animation_authoring_blend_space_full_channels_and_residual_baseline_parity() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId[3] clips = space_clips(&fixture);
    SpaceTopology topology = space_triangle();
    CrowdPlaybackState* state = space_crowd(&fixture);
    defer anim::destroy_crowd_playback(state);
    CrowdPlayer player = state.player(state.instance_id(0)!!)!!;
    BlendSpace2D* ordinary = space_add(
        fixture: &fixture,
        crowd: null,
        clips: clips[..],
        topology: &topology,
    )!!;
    BlendSpace2D* crowd = space_add(
        fixture: &fixture,
        crowd: &player,
        clips: clips[..],
        topology: &topology,
    )!!;
    for (uint member = 0; member < 3; member++) {
        ordinary.parameter = crowd.parameter = topology.coordinates[member];
        space_update_both(&fixture, state, 0);
        SpaceOutput actual = space_output(&fixture, null);
        assert(actual.poses[3].position == (Vec3){ (float)member * 10, 0, 0 });
        assert(actual.poses[3].scale == (Vec3){ 1 + (float)member, 1 + (float)member, 1 + (float)member });
        assert(actual.morph == (float)member * 0.25f);
        space_assert_same_output(space_output(&fixture, &player), actual);
    }
    Vec2[4] parameters = { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 0.5f, 0.5f } };
    float[4] translations = { 5, 10, 15, 7.5f };
    foreach (uint index, parameter : parameters) {
        ordinary.parameter = crowd.parameter = parameter;
        space_update_both(&fixture, state, 0);
        assert(space_output(&fixture, null).poses[3].position.x == translations[index]);
        space_assert_same_output(space_output(&fixture, &player), space_output(&fixture, null));
    }
    ordinary.parameter = crowd.parameter = { 0.5f, 0.5f };
    foreach (float weight : { 0.0f, 0.25f, 1.0f }) {
        ordinary.weight = crowd.weight = weight;
        space_update_both(&fixture, state, 0);
        SpaceOutput actual = space_output(&fixture, null);
        assert(math::abs(actual.poses[3].position.x - 7.5 * weight) < 1e-5);
        assert(math::abs(actual.poses[3].position.y - (1 - (double)weight)) < 1e-5);
        for (uint axis = 0; axis < 3; axis++) {
            assert(math::abs(actual.poses[3].scale[axis] - (1 + 0.75 * weight)) < 1e-5);
        }
        double z = 0.35 * weight;
        double w = 1 - 0.15 * weight;
        double length = math::sqrt(z * z + w * w);
        assert(math::abs(actual.poses[3].rotation.v.z - z / length) < 1e-6);
        assert(math::abs(actual.poses[3].rotation.v.w - w / length) < 1e-6);
        assert(math::abs(actual.morph - (0.5 * (1 - (double)weight) + 0.1875 * weight)) < 1e-6);
        space_assert_same_output(space_output(&fixture, &player), actual);
        assert(fixture.animator.action(ordinary.actions[0]).weight == 0.5f * weight);
        assert(fixture.animator.action(ordinary.actions[1]).weight == 0.25f * weight);
        assert(fixture.animator.action(ordinary.actions[2]).weight == 0.25f * weight);
    }
}

fn void test_animation_authoring_blend_space_phase_reverse_seams_pause_and_zero_weight_events() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        LayerFixture fixture;
        create_layer_fixture(&fixture, &tracker);
        defer destroy_layer_fixture(&fixture);
        ClipId[3] clips = space_clips(&fixture);
        SpaceTopology topology = space_triangle();
        CrowdPlaybackState* state = space_crowd(&fixture, &tracker);
        defer anim::destroy_crowd_playback(state);
        CrowdPlayer player = state.player(state.instance_id(0)!!)!!;
        BlendSpace2D* ordinary = space_add(
            fixture: &fixture,
            crowd: null,
            clips: clips[..],
            topology: &topology,
        )!!;
        BlendSpace2D* crowd = space_add(
            fixture: &fixture,
            crowd: &player,
            clips: clips[..],
            topology: &topology,
        )!!;
        ordinary.parameter = crowd.parameter = { 0.5f, 0.5f };
        sz allocations = tracker.total_allocation_count();
        space_update_both(&fixture, state, 1);
        assert(ordinary.phase == 0.5 && crowd.phase == 0.5);
        assert(fixture.animator.action(ordinary.actions[0]).time == 0.5f);
        assert(fixture.animator.action(ordinary.actions[1]).time == 1);
        assert(fixture.animator.action(ordinary.actions[2]).time == 2);
        uint[6] initial = { 100, 101, 110, 111, 120, 121 };
        space_assert_events(&fixture, state, initial[..]);
        space_update_both(&fixture, state, 1.5f);
        assert(ordinary.phase == 0.25 && crowd.phase == 0.25);
        uint[6] crossed = { 102, 100, 112, 110, 122, 120 };
        space_assert_events(&fixture, state, crossed[..]);
        ordinary.speed = crowd.speed = -1;
        space_update_both(&fixture, state, 1.5f);
        assert(ordinary.phase == 0.5 && crowd.phase == 0.5);
        uint[9] reverse = { 101, 100, 102, 111, 110, 112, 121, 120, 122 };
        space_assert_events(&fixture, state, reverse[..]);
        ordinary.playing = crowd.playing = false;
        ordinary.parameter = crowd.parameter = { 0, 2 };
        space_update_both(&fixture, state, 1);
        assert(ordinary.phase == 0.5 && crowd.phase == 0.5);
        assert(space_output(&fixture, null).poses[3].position.x == 20);
        space_assert_same_output(space_output(&fixture, &player), space_output(&fixture, null));
        uint[1] none;
        space_assert_events(&fixture, state, none[:0]);
        ordinary.playing = crowd.playing = true;
        ordinary.parameter = crowd.parameter = { 0.5f, 0.5f };
        ordinary.phase = crowd.phase = 0;
        ordinary.speed = crowd.speed = 1;
        ordinary.weight = crowd.weight = 0;
        space_update_both(&fixture, state, 1);
        space_assert_events(&fixture, state, initial[..]);
        assert(space_output(&fixture, null).poses[3].position == (Vec3){ 0, 1, 0 });
        ordinary.phase = crowd.phase = 0;
        space_update_both(&fixture, state, 4.5f);
        assert(ordinary.phase == 0.25 && crowd.phase == 0.25);
        uint[16] multiloop = {
            100, 101, 102, 100, 101, 102, 100,
            110, 111, 112, 110, 111, 112, 110,
            120, 121,
        };
        space_assert_events(fixture: &fixture, state: state, ids: multiloop[..], dropped: 5);
        assert(tracker.total_allocation_count() == allocations);
        ordinary.weight = crowd.weight = 1;
        AnimationActionId[3] retired;
        retired[..] = ordinary.actions[:3];
        AnimationActionId[3] retired_crowd;
        retired_crowd[..] = crowd.actions[:3];
        fixture.animator.stop_blend_space_2d(ordinary, 0.5f)!!;
        player.stop_blend_space_2d(crowd, 0.5f)!!;
        space_update_both(&fixture, state, 0.25f);
        assert(ordinary.weight == 0.5f && crowd.weight == 0.5f);
        space_update_both(&fixture, state, 0.25f);
        assert(ordinary.count == 0 && crowd.count == 0);
        assert(fixture.animator.action_count == 0 && state.slots[0].action_count == 0);
        foreach (id : retired) assert(@catch(fixture.animator.try_action(id)) == c3d::INVALID_ID);
        foreach (id : retired_crowd) assert(@catch(player.try_action(id)) == c3d::INVALID_ID);
        uint[16] generations;
        generations[..] = fixture.animator.actions.generations[..];
        space_update_both(&fixture, state, 0.25f);
        assert(fixture.animator.actions.generations == generations[..]);
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_authoring_blend_space_full_owner_capacities_and_legacy_limit() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId clip = layer_translation(&fixture, { 0, 2, 0 });
    ClipId[17] clips;
    clips[..] = clip;
    foreach (uint count : { 3u, 4u, 8u, 9u, 15u, 16u }) {
        SpaceTopology topology = count == 9 ? space_grid(3, 3)
          : count == 15 ? space_grid(5, 3) : space_maximal(count);
        CrowdPlaybackState* state = space_crowd(&fixture, mem, count);
        defer anim::destroy_crowd_playback(state);
        CrowdPlayer player = state.player(state.instance_id(0)!!)!!;
        BlendSpace2D* ordinary = space_add(
            fixture: &fixture,
            crowd: null,
            clips: clips[:count],
            topology: &topology,
        )!!;
        BlendSpace2D* crowd = space_add(
            fixture: &fixture,
            crowd: &player,
            clips: clips[:count],
            topology: &topology,
        )!!;
        assert(ordinary.count == count && crowd.count == count);
        assert(fixture.animator.action_count == count && state.slots[0].action_count == count);
        assert(ordinary.triangle_count <= 2 * count - 5 && ordinary.hull_count <= count);
        space_update_both(&fixture, state, 0);
        assert(space_output(&fixture, null).poses[3].position.y == 2);
        space_assert_same_output(space_output(&fixture, &player), space_output(&fixture, null));
        space_stop(&fixture, null, ordinary);
        space_stop(&fixture, &player, crowd);
    }
    foreach (uint capacity : { 1u, 2u, 4u }) {
        CrowdPlaybackState* state = space_crowd(&fixture, mem, capacity);
        defer anim::destroy_crowd_playback(state);
        CrowdPlayer player = state.player(state.instance_id(0)!!)!!;
        SpaceTopology topology = capacity == 4 ? space_maximal(5) : space_triangle();
        space_expect_fault(
            fixture: &fixture,
            crowd: &player,
            clips: clips[:topology.count],
            topology: &topology,
            expected: c3d::INVALID_ARGUMENT,
        );
    }
    SpaceTopology three = space_triangle();
    for (uint action = 0; action < 14; action++) fixture.animator.play(&fixture.assets, clip)!!;
    space_expect_fault(
        fixture: &fixture,
        crowd: null,
        clips: clips[:3],
        topology: &three,
        expected: c3d::CAPACITY_EXCEEDED,
    );
    PlaybackView playback = fixture.animator.playback();
    anim::clear_playback(&playback);
    float[9] positions;
    foreach (uint index, &position : positions) *position = (float)index;
    assert(@catch(fixture.animator.add_blend_space(&fixture.assets, clips[:9], positions[..]))
      == c3d::INVALID_ARGUMENT);
    BlendSpace1D* linear = fixture.animator.add_blend_space(&fixture.assets, clips[:8], positions[:8])!!;
    assert(linear.count == 8);
    fixture.animator.stop_blend_space(linear)!!;
    Vec2[17] too_many;
    BlendTriangle[1] triangle = { { .indices = { 0, 1, 2 } } };
    assert(@catch(fixture.animator.add_blend_space_2d(
        assets: &fixture.assets,
        clips: clips[..],
        coordinates: too_many[..],
        triangles: triangle[..],
    )) == c3d::INVALID_ARGUMENT);
    assert(fixture.animator.action_count == 0);
}

fn void test_animation_authoring_blend_space_two_shared_slots_preserve_linear_borrows() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId clip = layer_translation(&fixture, { 0, 2, 0 });
    ClipId[3] clips = { clip, clip, clip };
    float[2] positions = { 0, 1 };
    SpaceTopology topology = space_triangle();
    CrowdPlaybackState* state = space_crowd(&fixture);
    defer anim::destroy_crowd_playback(state);
    CrowdPlayer player = state.player(state.instance_id(0)!!)!!;
    for (uint owner = 0; owner < 2; owner++) {
        CrowdPlayer* selected_owner = owner ? &player : null;
        for (uint order = 0; order < 3; order++) {
            BlendSpace1D* linear;
            BlendSpace2D* first;
            BlendSpace2D* second;
            if (order == 0) {
                if (owner) {
                    linear = player.add_blend_space(&fixture.assets, clips[:2], positions[..])!!;
                } else {
                    linear = fixture.animator.add_blend_space(&fixture.assets, clips[:2], positions[..])!!;
                }
                first = space_add(
                    fixture: &fixture,
                    crowd: selected_owner,
                    clips: clips[..],
                    topology: &topology,
                )!!;
            } else {
                first = space_add(
                    fixture: &fixture,
                    crowd: selected_owner,
                    clips: clips[..],
                    topology: &topology,
                )!!;
                if (order == 1) {
                    if (owner) {
                        linear = player.add_blend_space(&fixture.assets, clips[:2], positions[..])!!;
                    } else {
                        linear = fixture.animator.add_blend_space(&fixture.assets, clips[:2], positions[..])!!;
                    }
                } else {
                    second = space_add(
                        fixture: &fixture,
                        crowd: selected_owner,
                        clips: clips[..],
                        topology: &topology,
                    )!!;
                }
            }
            space_expect_fault(
                fixture: &fixture,
                crowd: selected_owner,
                clips: clips[..],
                topology: &topology,
                expected: c3d::CAPACITY_EXCEEDED,
            );
            if (linear) {
                linear.parameter = 0.5f;
                assert(linear.count == 2 && linear.positions[0] == 0 && linear.positions[1] == 1);
                space_update_both(&fixture, state, 0);
                assert(space_output(&fixture, selected_owner).poses[3].position.y == 2);
                if (owner) {
                    player.stop_blend_space(linear)!!;
                } else {
                    fixture.animator.stop_blend_space(linear)!!;
                }
            }
            space_stop(&fixture, selected_owner, first);
            if (second) space_stop(&fixture, selected_owner, second);
        }
    }
}

fn void test_animation_authoring_blend_space_faults_preserve_existing_groups_and_output() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);
    ClipId[3] clips = space_clips(&fixture);
    SpaceTopology valid = space_triangle();
    CrowdPlaybackState* state = space_crowd(&fixture);
    defer anim::destroy_crowd_playback(state);
    CrowdPlayer player = state.player(state.instance_id(0)!!)!!;
    for (uint owner = 0; owner < 2; owner++) {
        CrowdPlayer* selected_owner = owner ? &player : null;
        BlendSpace2D* existing = space_add(
            fixture: &fixture,
            crowd: selected_owner,
            clips: clips[..],
            topology: &valid,
        )!!;
        existing.parameter = { 0.5f, 0.5f };
        space_update_both(&fixture, state, 0.25f);
        for (uint mutation = 0; mutation < 5; mutation++) {
            SpaceTopology invalid = valid;
            switch (mutation) {
                case 0: invalid.coordinates[0].x = float::nan;
                case 1: invalid.coordinates[1] = invalid.coordinates[0];
                case 2: invalid.triangles[0].indices[2] = 3;
                case 3: invalid.coordinates[2] = { 1, 0 };
                case 4: invalid.triangle_count = 0;
            }
            space_expect_fault(
                fixture: &fixture,
                crowd: selected_owner,
                clips: clips[..],
                topology: &invalid,
                expected: c3d::INVALID_ARGUMENT,
            );
        }
        space_expect_fault(
            fixture: &fixture,
            crowd: selected_owner,
            clips: clips[:2],
            topology: &valid,
            expected: c3d::INVALID_ARGUMENT,
        );
        ClipId[3] missing = clips;
        missing[1] = {};
        space_expect_fault(
            fixture: &fixture,
            crowd: selected_owner,
            clips: missing[..],
            topology: &valid,
            expected: c3d::INVALID_ID,
        );
        foreach (float duration : { 0.0f, float::nan }) {
            fixture.assets.clip(clips[1]).data.duration = duration;
            space_expect_fault(
                fixture: &fixture,
                crowd: selected_owner,
                clips: clips[..],
                topology: &valid,
                expected: c3d::INVALID_ARGUMENT,
            );
        }
        fixture.assets.clip(clips[1]).data.duration = 2;
        space_expect_fault(
            fixture: &fixture,
            crowd: selected_owner,
            clips: clips[..],
            topology: &valid,
            expected: c3d::INVALID_ARGUMENT,
            desc: { .fade_in = -1 },
        );
        space_stop(&fixture, selected_owner, existing);
    }
}

fn void test_animation_authoring_blend_space_preparation_failure_is_atomic_at_every_allocation() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        SpaceAllocationProbe allocator = { .backing = &tracker, .remaining = sz::max };
        LayerFixture fixture;
        create_layer_fixture(&fixture, &allocator);
        defer destroy_layer_fixture(&fixture);
        ClipId[3] clips = space_clips(&fixture);
        SpaceTopology topology = space_triangle();
        WeightedJointMask mask = space_full_mask(&fixture);
        defer anim::destroy_weighted_joint_mask(&mask);
        CrowdPlaybackState* state = space_crowd(&fixture, &allocator);
        defer anim::destroy_crowd_playback(state);
        CrowdPlayer player = state.player(state.instance_id(0)!!)!!;
        for (uint owner = 0; owner < 2; owner++) {
            CrowdPlayer* selected_owner = owner ? &player : null;
            BlendSpace2D* existing = space_add(
                fixture: &fixture,
                crowd: selected_owner,
                clips: clips[..],
                topology: &topology,
            )!!;
            existing.parameter = { 0.5f, 0.5f };
            space_update_both(&fixture, state, 0.25f);
            for (uint additive = 0; additive < 2; additive++) {
                sz allocations = additive ? 9 : 6;
                for (sz allowance = 0; allowance < allocations; allowance++) {
                    allocator.remaining = allowance;
                    sz outstanding = allocator.outstanding;
                    sz retained = tracker.allocated();
                    space_expect_fault(
                        fixture: &fixture,
                        crowd: selected_owner,
                        clips: clips[..],
                        topology: &topology,
                        expected: c3d::CAPACITY_EXCEEDED,
                        desc: { .additive = additive != 0, .weighted_mask = &mask },
                    );
                    assert(allocator.outstanding == outstanding && tracker.allocated() == retained);
                }
                allocator.remaining = allocations;
                BlendSpace2D* completed = space_add(
                    fixture: &fixture,
                    crowd: selected_owner,
                    clips: clips[..],
                    topology: &topology,
                    desc: { .additive = additive != 0, .weighted_mask = &mask },
                )!!;
                assert(allocator.remaining == 0);
                space_stop(&fixture, selected_owner, completed);
                allocator.remaining = sz::max;
            }
            space_stop(&fixture, selected_owner, existing);
        }
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_authoring_blend_space_copies_topology_masks_and_rejects_stale_actions() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        LayerFixture fixture;
        create_layer_fixture(&fixture, &tracker);
        defer destroy_layer_fixture(&fixture);
        ClipId[3] clips = space_clips(&fixture);
        CrowdPlaybackState* state = space_crowd(&fixture, &tracker);
        defer anim::destroy_crowd_playback(state);
        CrowdPlayer player = state.player(state.instance_id(0)!!)!!;
        BlendSpace2D* ordinary;
        BlendSpace2D* crowd;
        {
            Vec2[] coordinates = alloc::new_array(mem, Vec2, 3);
            defer alloc::free(mem, coordinates.ptr);
            BlendTriangle[] triangles = alloc::new_array(mem, BlendTriangle, 1);
            defer alloc::free(mem, triangles.ptr);
            SpaceTopology topology = space_triangle();
            coordinates[..] = topology.coordinates[:3];
            triangles[..] = topology.triangles[:1];
            WeightedJointMask mask = space_full_mask(&fixture);
            defer anim::destroy_weighted_joint_mask(&mask);
            ordinary = fixture.animator.add_blend_space_2d(
                assets: &fixture.assets,
                clips: clips[..],
                coordinates: coordinates,
                triangles: triangles,
                desc: { .weighted_mask = &mask },
            )!!;
            crowd = player.add_blend_space_2d(
                assets: &fixture.assets,
                clips: clips[..],
                coordinates: coordinates,
                triangles: triangles,
                desc: { .weighted_mask = &mask },
            )!!;
            assert(ordinary.points.ptr != coordinates.ptr && crowd.points.ptr != coordinates.ptr);
            coordinates[..] = (Vec2){ 99, 99 };
            triangles[0].indices = { 99, 99, 99 };
            mask.nodes[..] = 0;
        }
        ordinary.parameter = crowd.parameter = { 0.5f, 0.5f };
        sz allocations = tracker.total_allocation_count();
        for (uint frame = 0; frame < 20; frame++) space_update_both(&fixture, state, 0.01f);
        assert(tracker.total_allocation_count() == allocations);
        assert(space_output(&fixture, null).poses[3].position.x == 7.5f);
        space_assert_same_output(space_output(&fixture, &player), space_output(&fixture, null));
        AnimationActionId[3] removed;
        removed[..] = ordinary.actions[:3];
        AnimationActionId[3] removed_crowd;
        removed_crowd[..] = crowd.actions[:3];
        space_stop(&fixture, null, ordinary);
        space_stop(&fixture, &player, crowd);
        SpaceTopology topology = space_triangle();
        BlendSpace2D* reused = space_add(
            fixture: &fixture,
            crowd: null,
            clips: clips[..],
            topology: &topology,
        )!!;
        BlendSpace2D* reused_crowd = space_add(
            fixture: &fixture,
            crowd: &player,
            clips: clips[..],
            topology: &topology,
        )!!;
        foreach (id : removed) assert(@catch(fixture.animator.try_action(id)) == c3d::INVALID_ID);
        foreach (id : removed_crowd) assert(@catch(player.try_action(id)) == c3d::INVALID_ID);
        assert(reused.count == 3 && reused_crowd.count == 3);
        assert(@catch(fixture.animator.stop(reused.actions[0])) == c3d::INVALID_ARGUMENT);
        assert(@catch(player.stop(reused_crowd.actions[0])) == c3d::INVALID_ARGUMENT);
        assert(@catch(fixture.animator.cross_fade(reused.actions[0], reused.actions[1], 1)) == c3d::INVALID_ARGUMENT);
        assert(@catch(player.cross_fade(reused_crowd.actions[0], reused_crowd.actions[1], 1))
          == c3d::INVALID_ARGUMENT);
    }
    assert(!tracker.has_leaks());
}

fn void test_animation_authoring_blend_space_foreign_weighted_masks_fail_before_allocation() @test {
    SpaceAllocationProbe allocator = { .backing = mem, .remaining = sz::max };
    LayerFixture fixture;
    create_layer_fixture(&fixture, &allocator);
    defer {
        destroy_layer_fixture(&fixture);
        assert(allocator.outstanding == 0);
    }
    ClipId[3] clips = space_clips(&fixture);
    ModelTemplate foreign = { .nodes = alloc::new_array(mem, NodeTemplate, 4) };
    foreach (uint index, node : fixture.assets.model(fixture.model).data.nodes) {
        foreign.nodes[index] = node;
        foreign.nodes[index].name = node.name.copy(mem);
    }
    ModelId foreign_model = fixture.assets.add_model_owned(&foreign)!!;
    String[1] names = { "joint_tip" };
    float[1] weights = { 1 };
    WeightedJointMask mask = anim::create_weighted_joint_mask(
        allocator: mem,
        assets: &fixture.assets,
        model: foreign_model,
        names: names[..],
        weights: weights[..],
    )!!;
    defer anim::destroy_weighted_joint_mask(&mask);
    SpaceTopology topology = space_triangle();
    CrowdPlaybackState* state = space_crowd(&fixture, &allocator);
    defer anim::destroy_crowd_playback(state);
    CrowdPlayer player = state.player(state.instance_id(0)!!)!!;
    for (uint owner = 0; owner < 2; owner++) {
        CrowdPlayer* selected_owner = owner ? &player : null;
        BlendSpace2D* existing = space_add(
            fixture: &fixture,
            crowd: selected_owner,
            clips: clips[..],
            topology: &topology,
        )!!;
        space_update_both(&fixture, state, 0);
        allocator.remaining = 0;
        sz attempts = allocator.attempts;
        space_expect_fault(
            fixture: &fixture,
            crowd: selected_owner,
            clips: clips[..],
            topology: &topology,
            expected: c3d::INVALID_ARGUMENT,
            desc: { .weighted_mask = &mask },
        );
        assert(allocator.attempts == attempts);
        allocator.remaining = sz::max;
        space_stop(&fixture, selected_owner, existing);
    }
}
