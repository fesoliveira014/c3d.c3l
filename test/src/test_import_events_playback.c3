module c3d::test::import_events_playback;

import c3d;
import c3d::anim;
import c3d::anim::retarget;
import c3d::asset;
import c3d::asset::gltf;
import c3d::maths;
import c3d::model;
import c3d::scene;

const char[] IMPORTED_EVENT_MODEL @local = $embed("../fixtures/animation_events/gltf-events-v1.gltf");

struct ImportedEventsFixture @local {
    AssetStore assets;
    Scene scene;
    ModelId model;
    ClipId clip;
    Node* root;
    Animator* animator;
}

fn void create_imported_events_fixture(ImportedEventsFixture* fixture) @local {
    fixture.assets = asset::create_asset_store(mem, {
        .max_geometries = 2, .max_textures = 8, .max_materials = 2, .max_samplers = 8,
        .max_models = 2, .max_skeletons = 2, .max_clips = 8,
    });
    fixture.scene = scene::create_scene(mem, { .max_nodes = 16 });
    fixture.model = gltf::load_model_memory(
        assets: &fixture.assets,
        bytes: IMPORTED_EVENT_MODEL,
        base_dir: "",
        key: "event-model.gltf",
    )!!;
    fixture.clip = fixture.assets.model(fixture.model).data.clips[0];
    fixture.root = model::instantiate(&fixture.assets, &fixture.scene, fixture.model)!!;
    fixture.animator = anim::add_animator(&fixture.scene, fixture.root);
}

fn void destroy_imported_events_fixture(ImportedEventsFixture* fixture) @local {
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn void assert_imported_event_ids(Animator* animator, uint[] expected) @local {
    assert(animator.event_count == expected.len && animator.events_dropped == 0);
    foreach (index, id : expected) assert(animator.events[index].id == id);
}

fn void test_import_events_retargeted_tables_survive_source_mutation_and_removal() @test {
    ImportedEventsFixture fixture;
    create_imported_events_fixture(&fixture);
    defer destroy_imported_events_fixture(&fixture);
    ModelTemplate* template = &fixture.assets.model(fixture.model).data;
    AnimationClip* source = &fixture.assets.clip(fixture.clip).data;
    ClipId[2] copies;
    foreach (index, rest_pose : (RestPose[2]){ COPY, CORRECT }) {
        RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
        options.rest_pose = rest_pose;
        options.copy_translations = true;
        AnimationClip copied = retarget::retarget_by_name(
            allocator: mem,
            source: source,
            source_nodes: template.nodes,
            target: template,
            options: options,
        )!!;
        assert(copied.events.ptr != source.events.ptr && copied.events.len == 5);
        copies[index] = fixture.assets.add_clip_owned(&copied)!!;
    }
    assert(fixture.assets.clip(copies[0]).data.events.ptr != fixture.assets.clip(copies[1]).data.events.ptr);
    source.events[0].id = 1234;
    assert(fixture.assets.clip(copies[0]).data.events[0].id == 0);
    assert(fixture.assets.clip(copies[1]).data.events[0].id == 0);
    fixture.assets.set_clip_events(fixture.clip, { { .time = 0.25f, .id = 71 } })!!;
    fixture.assets.remove_clip(fixture.clip);
    foreach (clip : copies) {
        AnimationActionId action = fixture.animator.play(&fixture.assets, clip)!!;
        fixture.animator.action(action).loop = false;
        anim::update(&fixture.assets, &fixture.scene, 1);
        assert_imported_event_ids(fixture.animator, { 0, uint::max, 3, 3, 9 });
        assert(fixture.assets.clip(clip).data.events[1].time == 0.5f);
        fixture.animator.stop(action)!!;
    }
}

fn void test_import_events_literal_forward_reverse_loops_pause_seek_and_zero_step() @test {
    ImportedEventsFixture fixture;
    create_imported_events_fixture(&fixture);
    defer destroy_imported_events_fixture(&fixture);
    AnimationActionId id = fixture.animator.play(&fixture.assets, fixture.clip)!!;
    anim::update(&fixture.assets, &fixture.scene, 0);
    assert_imported_event_ids(fixture.animator, {});
    anim::update(&fixture.assets, &fixture.scene, 0.5f);
    assert_imported_event_ids(fixture.animator, { 0 });
    fixture.animator.action(id).playing = false;
    anim::update(&fixture.assets, &fixture.scene, 0.25f);
    assert_imported_event_ids(fixture.animator, {});
    fixture.animator.action(id).time = 0.75f;
    fixture.animator.action(id).playing = true;
    anim::update(&fixture.assets, &fixture.scene, 0);
    assert_imported_event_ids(fixture.animator, {});
    anim::update(&fixture.assets, &fixture.scene, 0.3f);
    assert_imported_event_ids(fixture.animator, { 9, 0 });
    fixture.animator.action(id).time = 0;
    anim::update(&fixture.assets, &fixture.scene, 2.25f);
    assert_imported_event_ids(fixture.animator, {
        0, uint::max, 3, 3, 9, 0, uint::max, 3, 3, 9, 0,
    });
    fixture.animator.action(id).time = 1;
    fixture.animator.action(id).speed = -1;
    anim::update(&fixture.assets, &fixture.scene, 2);
    assert_imported_event_ids(fixture.animator, {
        9, uint::max, 3, 3, 0, 9, uint::max, 3, 3, 0,
    });
    fixture.animator.action(id).time = 1;
    fixture.animator.action(id).loop = false;
    fixture.animator.action(id).playing = true;
    anim::update(&fixture.assets, &fixture.scene, 1);
    assert_imported_event_ids(fixture.animator, { 9, uint::max, 3, 3, 0 });
    anim::update(&fixture.assets, &fixture.scene, 1);
    assert_imported_event_ids(fixture.animator, {});
}

fn void test_import_events_zero_pose_weight_and_mask_still_emit_and_drops_saturate() @test {
    ImportedEventsFixture fixture;
    create_imported_events_fixture(&fixture);
    defer destroy_imported_events_fixture(&fixture);
    ModelTemplate* template = &fixture.assets.model(fixture.model).data;
    bool[] excluded = alloc::new_array(mem, bool, template.nodes.len);
    defer alloc::free(mem, excluded.ptr);
    JointMask mask = { .nodes = excluded };
    AnimationActionId id = fixture.animator.play(&fixture.assets, fixture.clip, { .mask = &mask })!!;
    fixture.animator.action(id).weight = 0;
    anim::update(&fixture.assets, &fixture.scene, 1);
    assert_imported_event_ids(fixture.animator, { 0, uint::max, 3, 3, 9 });
    ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
    foreach (uint index, pose : instance.base_pose) {
        assert(instance.present_node(index).local.position == pose.position);
    }
    fixture.animator.action(id).time = 0;
    anim::update(&fixture.assets, &fixture.scene, 4);
    uint[16] expected = {
        0, uint::max, 3, 3, 9, 0, uint::max, 3, 3, 9, 0, uint::max, 3, 3, 9, 0,
    };
    assert(fixture.animator.event_count == expected.len && fixture.animator.events_dropped == 4);
    foreach (index, event : fixture.animator.events[:fixture.animator.event_count]) assert(event.id == expected[index]);
    fixture.animator.action(id).time = 0;
    anim::update(&fixture.assets, &fixture.scene, float::max);
    assert(fixture.animator.event_count == 16 && fixture.animator.events_dropped == uint::max);
    foreach (index, event : fixture.animator.events[:fixture.animator.event_count]) assert(event.id == expected[index]);
}

fn void test_import_events_crowd_fixed_output_prefix_and_saturating_drop_count() @test {
    ImportedEventsFixture fixture;
    create_imported_events_fixture(&fixture);
    defer destroy_imported_events_fixture(&fixture);
    Transform[2] placements;
    placements[..] = maths::TRANSFORM_IDENTITY;
    uint[10] expected = { 0, uint::max, 3, 3, 9, 0, uint::max, 3, 3, 9 };
    foreach (capacity : (uint[4]){ 0, 1, anim::DEFAULT_CROWD_EVENT_CAPACITY, 2048 }) {
        CrowdPlaybackState* state = anim::create_crowd_playback(
            allocator: mem,
            template: &fixture.assets.model(fixture.model).data,
            placements: placements[..],
            actions_per_instance: 1,
            event_capacity: capacity,
        )!!;
        defer anim::destroy_crowd_playback(state);
        state.count = 2;
        for (uint instance = 0; instance < 2; instance++) {
            CrowdPlayer player = state.player(state.instance_id(instance)!!)!!;
            AnimationActionId action = player.play(&fixture.assets, fixture.clip)!!;
            player.action(action).weight = 0;
        }
        state.update(&fixture.assets, 1);
        uint retained = capacity < 10 ? capacity : 10;
        assert(state.event_count == retained && state.events_dropped == 10 - retained);
        foreach (index, event : state.events[:state.event_count]) {
            assert(event.event.id == expected[index] && event.instance.index == index / 5);
            assert(c3d::same_id(event.event.clip, fixture.clip));
        }
        state.update(&fixture.assets, 0);
        assert(state.event_count == 0 && state.events_dropped == 0);
        state.update(&fixture.assets, float::max);
        assert(state.events_dropped == uint::max);
        assert(state.event_count == capacity);
    }
}
