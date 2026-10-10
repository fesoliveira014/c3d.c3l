module c3d::test::anim;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::maths;
import std::math;

struct CrowdAllocationProbe (Allocator) @local {
    Allocator backing;
    sz remaining;
    sz outstanding;
}

fn void*? CrowdAllocationProbe.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    if (self.remaining <= 0) return mem::OUT_OF_MEMORY~;
    self.remaining--;
    void* pointer = self.backing.acquire(size, init_type, alignment)!;
    self.outstanding++;
    return pointer;
}

fn void*? CrowdAllocationProbe.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    if (self.remaining <= 0) return mem::OUT_OF_MEMORY~;
    self.remaining--;
    return self.backing.resize(pointer, size, alignment);
}

fn void CrowdAllocationProbe.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
    self.outstanding--;
}

fn void test_crowd_playback_storage_rolls_back_each_allocation() @test {
    NodeTemplate[4] nodes;
    foreach (&node : nodes) *node = { .parent = -1, .local = maths::TRANSFORM_IDENTITY };
    float[2] weights = { 0.25f, 0.75f };
    ModelMesh[1] meshes = { { .node = 3, .default_morph_weights = weights[..] } };
    ModelTemplate template = { .nodes = nodes[..], .meshes = meshes[..] };
    Transform[3] placements;
    placements[..] = maths::TRANSFORM_IDENTITY;
    foreach (events : (uint[2]){ 0, anim::DEFAULT_CROWD_EVENT_CAPACITY }) {
        bool succeeded;
        for (sz allowance = 0; allowance < 128; allowance++) {
            CrowdAllocationProbe allocator = { .backing = mem, .remaining = allowance };
            CrowdPlaybackState*? attempt = anim::create_crowd_playback(
                allocator: &allocator,
                template: &template,
                placements: placements[..],
                actions_per_instance: anim::DEFAULT_CROWD_ACTIONS,
                event_capacity: events,
            );
            if (catch excuse = attempt) {
                assert(excuse == c3d::CAPACITY_EXCEEDED);
            } else {
                CrowdPlaybackState* state = attempt;
                assert(state.slots.len == 3 && state.events.len == events);
                assert(state.base_morph_weights[0] == weights[..]);
                assert(state.base_morph_weights[0].ptr != &weights[0]);
                foreach (slot : state.slots) assert(slot.actions.free_count == anim::DEFAULT_CROWD_ACTIONS);
                anim::destroy_crowd_playback(state);
                succeeded = true;
            }
            assert(allocator.outstanding == 0);
            if (succeeded) break;
        }
        assert(succeeded);
    }
}

fn void test_crowd_players_enforce_owner_capacity_and_stale_generation() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);
    NodeTemplate[4] nodes;
    foreach (&node : nodes) *node = { .parent = -1, .local = maths::TRANSFORM_IDENTITY };
    ModelTemplate template = { .nodes = nodes[..] };
    Transform[2] placements;
    placements[..] = maths::TRANSFORM_IDENTITY;
    CrowdPlaybackState* state = anim::create_crowd_playback(
        allocator: mem,
        template: &template,
        placements: placements[..],
        actions_per_instance: 1,
        event_capacity: 0,
    )!!;
    defer anim::destroy_crowd_playback(state);
    state.count = 2;
    CrowdInstanceId first = state.instance_id(0)!!;
    CrowdInstanceId second = state.instance_id(1)!!;
    CrowdPlayer player = state.player(first)!!;
    CrowdPlayer independent = state.player(second)!!;
    ClipId clip = layer_translation(&fixture, { 0, 2, 0 });
    AnimationActionId action = player.play(&fixture.assets, clip)!!;
    assert(@catch(player.play(&fixture.assets, clip)) == c3d::CAPACITY_EXCEEDED);
    assert(state.slots[0].action_count == 1 && state.slots[1].action_count == 0);
    assert(@catch(state.instance_id(2)) == c3d::INVALID_ID);
    AnimationActionId other = independent.play(&fixture.assets, clip)!!;
    player.action(action).speed = -1;
    assert(independent.action(other).speed == 1);
    player.stop(action)!!;
    assert(@catch(player.try_action(action)) == c3d::INVALID_ID);
    state.slots[0].generation++;
    assert(@catch(state.player(first)) == c3d::INVALID_ID);
    assert(@catch(player.play(&fixture.assets, clip)) == c3d::INVALID_ID);
    assert(@catch(player.try_action(action)) == c3d::INVALID_ID);
    assert(@catch(player.stop(action)) == c3d::INVALID_ID);
    assert(independent.try_action(other)!!.speed == 1);
}

fn void test_crowd_evaluation_matches_animator_and_fixed_event_prefix() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);
    ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
    NodeTemplate[4] nodes;
    foreach (usz index, &node : nodes) *node = { .parent = -1, .local = instance.base_pose[index] };
    ModelTemplate template = { .nodes = nodes[..] };
    Transform[2] placements;
    placements[..] = maths::TRANSFORM_IDENTITY;
    ClipId clip = layer_translation(&fixture, { 0, 2, 0 });
    ClipEvent[2] events = { { .time = 0.25f, .id = 3 }, { .time = 0.75f, .id = 4 } };
    fixture.assets.set_clip_events(clip, events[..])!!;
    AnimationActionId ordinary = fixture.animator.play(&fixture.assets, clip)!!;
    fixture.animator.action(ordinary).weight = 0.5f;
    anim::update(&fixture.assets, &fixture.scene, 1);
    Transform[4] reference;
    foreach (usz index, &pose : reference) *pose = instance.present_node(index).local;
    foreach (capacity : (uint[4]){ 0, 1, anim::DEFAULT_CROWD_EVENT_CAPACITY, 2048 }) {
        CrowdPlaybackState* state = anim::create_crowd_playback(
            allocator: mem,
            template: &template,
            placements: placements[..],
            actions_per_instance: anim::DEFAULT_CROWD_ACTIONS,
            event_capacity: capacity,
        )!!;
        defer anim::destroy_crowd_playback(state);
        state.count = 2;
        CrowdPlayer first = state.player(state.instance_id(0)!!)!!;
        CrowdPlayer second = state.player(state.instance_id(1)!!)!!;
        AnimationActionId first_action = first.play(&fixture.assets, clip)!!;
        AnimationActionId second_action = second.play(&fixture.assets, clip)!!;
        first.action(first_action).weight = 0.5f;
        second.action(second_action).weight = 0.25f;
        state.update(&fixture.assets, 1);
        foreach (usz index, expected : reference) {
            Transform actual = state.poses[index];
            assert(actual.position == expected.position);
            assert(actual.rotation.v == expected.rotation.v);
            assert(actual.scale == expected.scale);
        }
        Vec3 second_expected = (Vec3){ 0, 2, 0 } * 0.25f + instance.base_pose[3].position * 0.75f;
        assert(state.poses[7].position == second_expected);
        uint retained = capacity < 4 ? capacity : 4;
        assert(state.event_count == retained && state.events_dropped == 4 - retained);
        foreach (usz index, value : state.events[:retained]) {
            assert(value.instance.index == index / 2 && value.instance.generation == 1);
            assert(value.event.id == (index % 2 ? 4u : 3u));
            assert(value.event.time == (index % 2 ? 0.75f : 0.25f));
            assert(c3d::same_id(value.event.clip, clip));
            assert(c3d::same_id(value.event.action, index < 2 ? first_action : second_action));
        }
        state.update(&fixture.assets, 0);
        assert(state.event_count == 0 && state.events_dropped == 0);
    }
}
