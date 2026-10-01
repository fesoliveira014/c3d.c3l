module c3d::test::anim;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::io::path;
import std::math;

struct LayerFixture @local {
    AssetStore assets;
    Scene scene;
    ModelId model;
    Node* root;
    Animator* animator;
}


fn String fixture_path(String name) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend("../fixtures/gltf", name)!!;
}

fn AssetStore create_store() @local {
    return asset::create_asset_store(mem, {
        .max_geometries = 8,
        .max_textures = 8,
        .max_materials = 8,
        .max_samplers = 8,
        .max_models = 2,
        .max_skeletons = 2,
        .max_clips = 8,
    });
}

fn Track make_track(
    TargetPath path,
    Interpolation interpolation,
    float[] times,
    float[] values,
    uint target = 0,
) @local {
    Track track = { .target = target, .path = path, .interpolation = interpolation };
    track.times = alloc::new_array(mem, float, times.len);
    track.times[..] = times[..];
    track.values = alloc::new_array(mem, float, values.len);
    track.values[..] = values[..];
    return track;
}

fn void free_track(Track* track) @local {
    alloc::free(mem, track.times.ptr);
    alloc::free(mem, track.values.ptr);
}

fn ClipId add_clip(
    AssetStore* assets,
    String key,
    Track[] tracks,
    uint[] targets,
    float duration,
) @local {
    AnimationClip clip = { .name = key.copy(mem), .duration = duration };
    clip.tracks = alloc::new_array(mem, Track, tracks.len);
    clip.tracks[..] = tracks[..];
    clip.targets = alloc::new_array(mem, uint, targets.len);
    clip.targets[..] = targets[..];
    return assets.add_clip_owned(&clip, key)!!;
}

fn Track constant_translation(Vec3 value) @local {
    float[2] times = { 0, 1 };
    float[6] values = { value.x, value.y, value.z, value.x, value.y, value.z };
    return make_track(
        path: TargetPath.TRANSLATION,
        interpolation: Interpolation.STEP,
        times: times[..],
        values: values[..],
    );
}

fn Track step_translation() @local {
    float[3] times = { 0, 1, 2 };
    float[9] values = { 0, 0, 0, 1, 1, 1, 2, 2, 2 };
    return make_track(
        path: TargetPath.TRANSLATION,
        interpolation: Interpolation.STEP,
        times: times[..],
        values: values[..],
    );
}

fn Track linear_translation() @local {
    float[3] times = { 0, 1, 2 };
    float[9] values = { 0, 0, 0, 1, 1, 1, 2, 2, 2 };
    return make_track(
        path: TargetPath.TRANSLATION,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: values[..],
    );
}

fn bool approx(float a, float b) @local => math::abs(a - b) < 1e-4f;

fn bool rotates_x_to(Quat rotation, Vec3 expected) @local {
    Vec3 rotated = rotation.rotate_vec3({ 1, 0, 0 });
    return approx(rotated.x, expected.x) && approx(rotated.y, expected.y) && approx(rotated.z, expected.z);
}

fn void test_sample_step_holds_previous_key() @test {
    Track track = step_translation();
    defer free_track(&track);
    float[3] out;
    uint cursor;
    anim::sample_track(
        track: &track,
        time: 0.99f,
        cursor: &cursor,
        out: out[..],
    );
    assert(out[0] == 0 && cursor == 0);
    anim::sample_track(
        track: &track,
        time: 1,
        cursor: &cursor,
        out: out[..],
    );
    assert(out[0] == 1 && cursor == 1);
    anim::sample_track(
        track: &track,
        time: 5,
        cursor: &cursor,
        out: out[..],
    );
    assert(out[0] == 2 && out[2] == 2);
    anim::sample_track(
        track: &track,
        time: -1,
        cursor: &cursor,
        out: out[..],
    );
    assert(out[0] == 0 && cursor == 0);
}

fn void test_sample_linear_interpolates_between_keys() @test {
    Track track = linear_translation();
    defer free_track(&track);
    float[3] out;
    uint cursor;
    anim::sample_track(
        track: &track,
        time: 0.5f,
        cursor: &cursor,
        out: out[..],
    );
    assert(approx(out[0], 0.5f) && approx(out[2], 0.5f));
    anim::sample_track(
        track: &track,
        time: 1.75f,
        cursor: &cursor,
        out: out[..],
    );
    assert(approx(out[1], 1.75f) && cursor == 1);
}

fn void test_sample_rotation_takes_short_path() @test {
    float[2] times = { 0, 1 };
    float[8] values = { 0, 0, 0, 1, 0, -0.7071068f, 0, -0.7071068f };
    Track track = make_track(
        path: TargetPath.ROTATION,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: values[..],
    );
    defer free_track(&track);
    float[4] out;
    uint cursor;
    anim::sample_track(
        track: &track,
        time: 0.5f,
        cursor: &cursor,
        out: out[..],
    );
    Quat sampled = { .v = { out[0], out[1], out[2], out[3] } };
    assert(approx(sampled.length(), 1));
    assert(rotates_x_to(sampled, { 0.7071068f, 0, -0.7071068f }));
}

fn void test_sample_cubic_spline_scales_tangents_by_duration() @test {
    float[2] times = { 0, 2 };
    float[18] values = {
        0, 0, 0, 0, 0, 0, 1, 0, 0,
        0, 0, 0, 2, 0, 0, 0, 0, 0,
    };
    Track track = make_track(
        path: TargetPath.TRANSLATION,
        interpolation: Interpolation.CUBIC_SPLINE,
        times: times[..],
        values: values[..],
    );
    defer free_track(&track);
    assert(track.stride() == 3);
    float[3] out;
    uint cursor;
    anim::sample_track(
        track: &track,
        time: 1,
        cursor: &cursor,
        out: out[..],
    );
    assert(approx(out[0], 1.25f) && out[1] == 0);
    anim::sample_track(
        track: &track,
        time: 2,
        cursor: &cursor,
        out: out[..],
    );
    assert(out[0] == 2);
}

fn void test_cursor_reseeks_after_backwards_jump() @test {
    Track track = linear_translation();
    defer free_track(&track);
    float[3] out;
    uint cursor;
    anim::sample_track(
        track: &track,
        time: 1.5f,
        cursor: &cursor,
        out: out[..],
    );
    assert(cursor == 1);
    anim::sample_track(
        track: &track,
        time: 0.2f,
        cursor: &cursor,
        out: out[..],
    );
    assert(approx(out[0], 0.2f) && cursor == 0);
}

fn void test_quarter_weight_blends_toward_baseline() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("skin.gltf"))!!;
    Node* root = model::instantiate(&assets, &scene, model)!!;
    ModelInstance* instance = scene.get(root, ModelInstance);
    Track[1] tracks = { constant_translation({ 0, 9, 0 }) };
    uint[1] targets = { 3 };
    ClipId clip = add_clip(
        assets: &assets,
        key: "lift",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );

    Animator* animator = anim::add_animator(&scene, root);
    AnimationActionId action_id = animator.play(&assets, clip)!!;
    Action* action = animator.action(action_id);
    action.weight = 0.25f;
    anim::update(&assets, &scene, 0);

    Node* tip = instance.nodes[3];
    assert(approx(tip.local.position.y, 3) && tip.local.position.x == 0);
    assert(tip.local.rotation.v == instance.base_pose[3].rotation.v);
    assert(tip.local.scale == instance.base_pose[3].scale);
}

fn void test_missing_channel_keeps_baseline_and_writes_morphs() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("skin.gltf"))!!;
    Node* root = model::instantiate(&assets, &scene, model)!!;
    ModelInstance* instance = scene.get(root, ModelInstance);

    Animator* animator = anim::add_animator(&scene, root);
    animator.play(&assets, instance.clips[0])!!;
    anim::update(&assets, &scene, 0.5f);

    Node* tip = instance.nodes[3];
    assert(tip.local.position == (Vec3){ 0, 1, 0 } && tip.local.scale == (Vec3){ 1, 1, 1 });
    assert(rotates_x_to(tip.local.rotation, { 0.7071068f, 0, -0.7071068f }));
    Mesh* mesh = scene.get(instance.nodes[1], Mesh);
    assert(mesh.morph_weights[0] == 0);
}

fn void test_two_actions_over_unit_weight_normalize() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("skin.gltf"))!!;
    Node* root = model::instantiate(&assets, &scene, model)!!;
    ModelInstance* instance = scene.get(root, ModelInstance);
    uint[1] targets = { 3 };
    Track[1] low = { constant_translation({ 0, 2, 0 }) };
    Track[1] high = { constant_translation({ 0, 4, 0 }) };
    ClipId low_clip = add_clip(
        assets: &assets,
        key: "low",
        tracks: low[..],
        targets: targets[..],
        duration: 1,
    );
    ClipId high_clip = add_clip(
        assets: &assets,
        key: "high",
        tracks: high[..],
        targets: targets[..],
        duration: 1,
    );

    Animator* animator = anim::add_animator(&scene, root);
    animator.play(&assets, low_clip)!!;
    animator.play(&assets, high_clip)!!;
    anim::update(&assets, &scene, 0);

    assert(approx(instance.nodes[3].local.position.y, 3));
}

fn void test_two_instances_animate_independently() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("skin.gltf"))!!;
    Node* first = model::instantiate(&assets, &scene, model)!!;
    Node* second = model::instantiate(&assets, &scene, model)!!;
    ClipId clip = scene.get(first, ModelInstance).clips[0];

    anim::add_animator(&scene, first).play(&assets, clip)!!;
    AnimationActionId paused_id = anim::add_animator(&scene, second).play(&assets, clip)!!;
    Action* paused = scene.get(second, Animator).action(paused_id);
    paused.playing = false;
    anim::update(&assets, &scene, 0.5f);

    Node* first_tip = scene.get(first, ModelInstance).nodes[3];
    Node* second_tip = scene.get(second, ModelInstance).nodes[3];
    assert(rotates_x_to(first_tip.local.rotation, { 0.7071068f, 0, -0.7071068f }));
    assert(rotates_x_to(second_tip.local.rotation, { 1, 0, 0 }));
    assert(scene.get(scene.get(second, ModelInstance).nodes[1], Mesh).morph_weights[0] == 0);
}

fn void test_fade_out_removes_action_and_returns_to_baseline() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("skin.gltf"))!!;
    Node* root = model::instantiate(&assets, &scene, model)!!;
    Node* tip = scene.get(root, ModelInstance).nodes[3];
    Track[1] tracks = { constant_translation({ 0, 9, 0 }) };
    uint[1] targets = { 3 };
    ClipId clip = add_clip(
        assets: &assets,
        key: "lift",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );

    Animator* animator = anim::add_animator(&scene, root);
    AnimationActionId action_id = animator.play(&assets, clip)!!;
    anim::update(&assets, &scene, 0);
    assert(approx(tip.local.position.y, 9));

    animator.stop(action_id, 1)!!;
    anim::update(&assets, &scene, 0.5f);
    assert(approx(tip.local.position.y, 5) && animator.action_count == 1);
    anim::update(&assets, &scene, 0.6f);
    assert(animator.action_count == 0 && approx(tip.local.position.y, 1));
}

fn void test_cross_fade_hands_weight_over() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("skin.gltf"))!!;
    Node* root = model::instantiate(&assets, &scene, model)!!;
    Node* tip = scene.get(root, ModelInstance).nodes[3];
    uint[1] targets = { 3 };
    Track[1] high = { constant_translation({ 0, 9, 0 }) };
    Track[1] low = { constant_translation({ 0, 5, 0 }) };
    ClipId high_clip = add_clip(
        assets: &assets,
        key: "high",
        tracks: high[..],
        targets: targets[..],
        duration: 1,
    );
    ClipId low_clip = add_clip(
        assets: &assets,
        key: "low",
        tracks: low[..],
        targets: targets[..],
        duration: 1,
    );

    Animator* animator = anim::add_animator(&scene, root);
    animator.play(&assets, high_clip)!!;
    animator.play(&assets, low_clip, desc: { .fade_in = 10 })!!;
    animator.cross_fade(animator.order[0], animator.order[1], 1)!!;
    anim::update(&assets, &scene, 0.5f);
    assert(approx(tip.local.position.y, 7));
    anim::update(&assets, &scene, 0.5f);
    assert(animator.action_count == 1 && approx(tip.local.position.y, 5));
    assert(animator.action(animator.order[0]).clip.index == low_clip.index);

    AnimationActionId target = animator.order[0];
    animator.action(target).weight = 2;
    AnimationActionId source = animator.play(&assets, high_clip)!!;
    animator.cross_fade(source, target, 1)!!;
    anim::update(&assets, &scene, 0.5f);
    assert(approx(animator.action(target).weight, 1.5f));
    assert(approx(tip.local.position.y, 6));
    anim::update(&assets, &scene, 0.6f);
    assert(approx(animator.action(target).weight, 1));
    assert(approx(tip.local.position.y, 5));
}

fn void test_stop_with_fade_at_zero_weight_removes_on_next_update() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("skin.gltf"))!!;
    Node* root = model::instantiate(&assets, &scene, model)!!;
    Track[1] tracks = { constant_translation({ 0, 9, 0 }) };
    uint[1] targets = { 3 };
    ClipId clip = add_clip(
        assets: &assets,
        key: "lift",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );

    Animator* animator = anim::add_animator(&scene, root);
    AnimationActionId action_id = animator.play(&assets, clip, desc: { .fade_in = 0.5f })!!;
    animator.stop(action_id, 0.3f)!!;
    anim::update(&assets, &scene, 0.1f);
    assert(animator.action_count == 0);
}

fn void test_cross_fade_from_zero_weight_removes_it_on_next_update() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("skin.gltf"))!!;
    Node* root = model::instantiate(&assets, &scene, model)!!;
    uint[1] targets = { 3 };
    Track[1] high = { constant_translation({ 0, 9, 0 }) };
    Track[1] low = { constant_translation({ 0, 5, 0 }) };
    ClipId high_clip = add_clip(
        assets: &assets,
        key: "high",
        tracks: high[..],
        targets: targets[..],
        duration: 1,
    );
    ClipId low_clip = add_clip(
        assets: &assets,
        key: "low",
        tracks: low[..],
        targets: targets[..],
        duration: 1,
    );

    Animator* animator = anim::add_animator(&scene, root);
    animator.play(&assets, high_clip)!!;
    animator.play(&assets, low_clip, desc: { .fade_in = 0.5f })!!;
    animator.cross_fade(animator.order[1], animator.order[0], 0.3f)!!;
    anim::update(&assets, &scene, 0.1f);
    assert(animator.action_count == 1);
    assert(animator.action(animator.order[0]).clip.index == high_clip.index && animator.action(animator.order[0]).weight == 1);
}

fn void test_looping_wraps_and_non_looping_clamps() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("skin.gltf"))!!;
    Node* root = model::instantiate(&assets, &scene, model)!!;
    Node* tip = scene.get(root, ModelInstance).nodes[3];
    float[2] times = { 0, 1 };
    float[6] values = { 0, 0, 0, 0, 9, 0 };
    Track[1] tracks = { make_track(
        path: TargetPath.TRANSLATION,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: values[..],
    ) };
    uint[1] targets = { 3 };
    ClipId clip = add_clip(
        assets: &assets,
        key: "rise",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );

    Animator* animator = anim::add_animator(&scene, root);
    AnimationActionId once_id = animator.play(&assets, clip)!!;
    Action* once = animator.action(once_id);
    once.loop = false;
    anim::update(&assets, &scene, 2);
    assert(once.time == 1 && !once.playing && approx(tip.local.position.y, 9));

    animator.play(&assets, clip)!!;
    anim::update(&assets, &scene, 1.5f);
    assert(approx(animator.action(animator.order[1]).time, 0.5f) && animator.action(animator.order[1]).playing);
}

fn void test_play_rejects_dead_or_foreign_clip() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("skin.gltf"))!!;
    Node* root = model::instantiate(&assets, &scene, model)!!;
    Track[1] tracks = { constant_translation({ 0, 9, 0 }) };
    uint[1] targets = { 7 };
    ClipId foreign = add_clip(
        assets: &assets,
        key: "foreign",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
    Animator* animator = anim::add_animator(&scene, root);

    if (catch excuse = animator.play(&assets, foreign)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "expected a fault");
    }
    assets.remove_clip(foreign);
    if (catch excuse = animator.play(&assets, foreign)) {
        assert(excuse == c3d::INVALID_ID);
    } else {
        assert(false, "expected a fault");
    }
    assert(animator.action_count == 0);
}

fn void test_remove_instance_frees_animator_and_keeps_clip() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("skin.gltf"))!!;
    Node* root = model::instantiate(&assets, &scene, model)!!;
    ClipId clip = scene.get(root, ModelInstance).clips[0];
    anim::add_animator(&scene, root).play(&assets, clip)!!;
    assert(scene.count(Animator) == 1);

    scene.remove(root);
    assert(scene.count(Animator) == 0 && assets.clips.is_live(clip));
}

fn void test_find_joint_returns_index_or_not_found() @test {
    String[3] names = { "hips", "spine", "head" };
    Skeleton skeleton = { .joint_names = names[..] };
    assert(skeleton.find_joint("spine")!! == 1);
    assert(@catch(skeleton.find_joint("tail")) == NOT_FOUND);
}

fn void create_layer_fixture(LayerFixture* fixture, Allocator allocator = mem) @local {
    fixture.assets = create_store();
    fixture.scene = scene::create_scene(allocator, { .max_nodes = 16 });
    fixture.model = gltf::load_model(&fixture.assets, fixture_path("skin.gltf"))!!;
    fixture.root = model::instantiate(&fixture.assets, &fixture.scene, fixture.model)!!;
    fixture.animator = anim::add_animator(&fixture.scene, fixture.root);
}

fn void destroy_layer_fixture(LayerFixture* fixture) @local {
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn ClipId layer_translation(LayerFixture* fixture, Vec3 value, uint target = 3) @local {
    Track[1] tracks = { constant_translation(value) };
    uint[1] targets = { target };
    return add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
}

fn void test_action_ids_survive_other_actions_and_reject_reuse() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    ClipId clip = layer_translation(&fixture, { 0, 2, 0 });
    AnimationActionId first = fixture.animator.play(&fixture.assets, clip)!!;
    fixture.animator.action(first).speed = 0.25f;
    AnimationActionId second = fixture.animator.play(&fixture.assets, clip)!!;
    fixture.animator.stop(second)!!;
    assert(fixture.animator.action(first).speed == 0.25f);
    AnimationActionId reused = fixture.animator.play(&fixture.assets, clip)!!;
    assert(reused.index == second.index && reused.generation != second.generation);
    if (catch excuse = fixture.animator.try_action(second)) {
        assert(excuse == c3d::INVALID_ID);
    } else {
        assert(false);
    }

    fixture.animator.stop(first, 0.1f)!!;
    anim::update(&fixture.assets, &fixture.scene, 0.2f);
    if (catch excuse = fixture.animator.try_action(first)) {
        assert(excuse == c3d::INVALID_ID);
    } else {
        assert(false);
    }

    assert(fixture.animator.action_count == 1);
    assert(c3d::same_id(fixture.animator.order[0], reused));
}

fn void test_action_capacity_and_invalid_edits_are_atomic() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    LayerFixture fixture;
    create_layer_fixture(&fixture, &tracker);
    defer destroy_layer_fixture(&fixture);

    ClipId clip = layer_translation(&fixture, { 0, 2, 0 });
    AnimationActionId first = fixture.animator.play(&fixture.assets, clip)!!;
    AnimationActionId removed = fixture.animator.play(&fixture.assets, clip)!!;
    fixture.animator.stop(removed)!!;
    if (catch excuse = fixture.animator.cross_fade(first, removed, 1)) {
        assert(excuse == c3d::INVALID_ID);
    } else {
        assert(false);
    }

    assert(fixture.animator.action(first).fade_target == 1);
    assert(fixture.animator.action(first).fade_rate == 0);
    if (catch excuse = fixture.animator.stop(removed)) {
        assert(excuse == c3d::INVALID_ID);
    } else {
        assert(false);
    }

    if (catch excuse = fixture.animator.cross_fade(first, first, 1)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }

    if (catch excuse = fixture.animator.stop(first, -1)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }

    sz allocations = tracker.total_allocation_count();
    if (catch excuse = fixture.animator.play(&fixture.assets, clip, { .layer = anim::MAX_ANIMATION_LAYERS })) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }

    if (catch excuse = fixture.animator.play(&fixture.assets, clip, { .fade_in = -1 })) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }

    if (catch excuse = fixture.animator.play(&fixture.assets, (ClipId){})) {
        assert(excuse == c3d::INVALID_ID);
    } else {
        assert(false);
    }

    assert(fixture.animator.action_count == 1);
    assert(tracker.total_allocation_count() == allocations);
    for (uint index = 1; index < anim::MAX_ACTIONS; index++) fixture.animator.play(&fixture.assets, clip)!!;
    allocations = tracker.total_allocation_count();
    if (catch excuse = fixture.animator.play(&fixture.assets, clip)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }

    assert(fixture.animator.action_count == anim::MAX_ACTIONS);
    assert(tracker.total_allocation_count() == allocations);
}

fn void test_layers_fold_in_index_order_and_keep_missing_channels() @test {
    for (uint reverse = 0; reverse < 2; reverse++) {
        LayerFixture fixture;
        create_layer_fixture(&fixture);
        defer destroy_layer_fixture(&fixture);

        ClipId lower = layer_translation(&fixture, { 0, 2, 0 });
        ClipId upper = layer_translation(&fixture, { 0, 6, 0 });
        AnimationActionId base;
        AnimationActionId overlay;
        if (reverse) {
            overlay = fixture.animator.play(&fixture.assets, upper, { .layer = 1 })!!;
            base = fixture.animator.play(&fixture.assets, lower)!!;
        } else {
            base = fixture.animator.play(&fixture.assets, lower)!!;
            overlay = fixture.animator.play(&fixture.assets, upper, { .layer = 1 })!!;
        }
        fixture.animator.action(base).weight = 0.25f;
        fixture.animator.action(overlay).weight = 0.5f;
        anim::update(&fixture.assets, &fixture.scene, 0);
        ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
        assert(approx(instance.nodes[3].local.position.y, 3.625f));
        assert(instance.nodes[3].local.scale == instance.base_pose[3].scale);
        assert(instance.nodes[3].local.rotation.v == instance.base_pose[3].rotation.v);
        fixture.animator.action(overlay).weight = 0;
        anim::update(&fixture.assets, &fixture.scene, 0);
        assert(approx(instance.nodes[3].local.position.y, 1.25f));
    }
}

fn void test_mask_names_descendants_empty_and_missing() @test {
    NodeTemplate[4] nodes = {
        { .parent = -1, .name = "root" },
        { .parent = 0, .name = "arm" },
        { .parent = 1, .name = "hand" },
        { .parent = 0, .name = "arm" },
    };
    ModelTemplate template = { .nodes = nodes[..] };
    String[2] names = { "arm", "arm" };
    JointMask mask = anim::create_joint_mask(mem, &template, names[..])!!;
    defer anim::destroy_joint_mask(&mask);
    assert(mask.nodes.len == 4 && !mask.nodes[0]);
    assert(mask.nodes[1] && mask.nodes[2] && mask.nodes[3]);
    JointMask exact = anim::create_joint_mask(
        allocator: mem,
        template: &template,
        names: names[..],
        include_descendants: false,
    )!!;
    defer anim::destroy_joint_mask(&exact);
    assert(exact.nodes[1] && !exact.nodes[2] && exact.nodes[3]);
    JointMask empty = anim::create_joint_mask(mem, &template, {})!!;
    defer anim::destroy_joint_mask(&empty);
    foreach (selected : empty.nodes) assert(!selected);
    String[1] absent = { "missing" };
    if (catch excuse = anim::create_joint_mask(mem, &template, absent[..])) {
        assert(excuse == NOT_FOUND);
    } else {
        assert(false);
    }
}

fn void test_upper_rotation_uses_lower_pose_hemisphere() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    float[2] times = { 0, 1 };
    float[8] lower_values = { 0, 0, 0.9961947f, 0.08715574f, 0, 0, 0.9961947f, 0.08715574f };
    float[8] upper_values = { 0, 0, -0.9961947f, 0.08715574f, 0, 0, -0.9961947f, 0.08715574f };
    Track[1] lower_tracks = { make_track(
        path: TargetPath.ROTATION,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: lower_values[..],
    ) };
    Track[1] upper_tracks = { make_track(
        path: TargetPath.ROTATION,
        interpolation: Interpolation.LINEAR,
        times: times[..],
        values: upper_values[..],
    ) };
    uint[1] targets = { 3 };
    ClipId lower = add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: lower_tracks[..],
        targets: targets[..],
        duration: 1,
    );
    ClipId upper = add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: upper_tracks[..],
        targets: targets[..],
        duration: 1,
    );
    fixture.animator.play(&fixture.assets, lower)!!;
    AnimationActionId overlay = fixture.animator.play(&fixture.assets, upper, { .layer = 1 })!!;
    fixture.animator.action(overlay).weight = 0.5f;
    anim::update(&fixture.assets, &fixture.scene, 0);
    Node* tip = fixture.scene.get(fixture.root, ModelInstance).nodes[3];
    assert(rotates_x_to(tip.local.rotation, { -1, 0, 0 }));
}

fn void test_play_copies_masks_and_rejects_wrong_node_count() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    Track[2] tracks = { constant_translation({ 5, 0, 0 }), constant_translation({ 0, 6, 0 }) };
    tracks[1].target = 1;
    uint[2] targets = { 2, 3 };
    ClipId clip = add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
    AnimationActionId masked;
    {
        String[1] names = { "joint_tip" };
        JointMask mask = anim::create_joint_mask(mem, &fixture.assets.model(fixture.model).data, names[..])!!;
        defer anim::destroy_joint_mask(&mask);
        masked = fixture.animator.play(&fixture.assets, clip, { .layer = 1, .mask = &mask })!!;
        mask.nodes[..] = false;
    }
    anim::update(&fixture.assets, &fixture.scene, 0);
    ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
    assert(instance.nodes[2].local.position == instance.base_pose[2].position);
    assert(approx(instance.nodes[3].local.position.y, 6));
    NodeTemplate[1] nodes = { { .parent = -1, .name = "only" } };
    ModelTemplate small = { .nodes = nodes[..] };
    JointMask wrong = anim::create_joint_mask(mem, &small, {})!!;
    defer anim::destroy_joint_mask(&wrong);
    if (catch excuse = fixture.animator.play(&fixture.assets, clip, { .mask = &wrong })) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }

    assert(fixture.animator.action_count == 1);
    fixture.animator.stop(masked)!!;
    AnimationActionId unmasked = fixture.animator.play(&fixture.assets, clip)!!;
    anim::update(&fixture.assets, &fixture.scene, 0);
    assert(approx(instance.nodes[2].local.position.x, 5));
    fixture.animator.stop(unmasked)!!;
    JointMask empty = anim::create_joint_mask(mem, &fixture.assets.model(fixture.model).data, {})!!;
    defer anim::destroy_joint_mask(&empty);
    fixture.animator.play(&fixture.assets, clip, { .mask = &empty })!!;
    anim::update(&fixture.assets, &fixture.scene, 0);
    assert(instance.nodes[2].local.position == instance.base_pose[2].position);
    assert(instance.nodes[3].local.position == instance.base_pose[3].position);
}

fn void test_masks_and_playback_support_nodes_past_512() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 600 });
    defer scene::destroy_scene(&scene);
    ModelTemplate template = { .nodes = alloc::new_array(mem, NodeTemplate, 520) };
    foreach (index, &node : template.nodes) {
        *node = {
            .parent = index ? (int)index - 1 : -1,
            .name = (index == 512 ? "high" : "node").copy(mem),
            .local = maths::TRANSFORM_IDENTITY,
            .visible = true,
        };
    }
    ModelId model = assets.add_model_owned(&template)!!;
    Node* root = model::instantiate(&assets, &scene, model)!!;
    Animator* animator = anim::add_animator(&scene, root);
    String[1] names = { "high" };
    JointMask mask = anim::create_joint_mask(mem, &assets.model(model).data, names[..])!!;
    defer anim::destroy_joint_mask(&mask);
    assert(mask.nodes.len == 520 && !mask.nodes[511] && mask.nodes[512] && mask.nodes[519]);
    Track[1] tracks = { constant_translation({ 0, 7, 0 }) };
    uint[1] targets = { 519 };
    ClipId clip = add_clip(
        assets: &assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
    animator.play(&assets, clip, { .mask = &mask, .layer = 1 })!!;
    anim::update(&assets, &scene, 0);
    ModelInstance* instance = scene.get(root, ModelInstance);
    assert(approx(instance.nodes[519].local.position.y, 7));
    assert(instance.nodes[511].local.position == (Vec3){});
}

fn void test_base_cross_fade_preserves_upper_layer() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    ClipId upper = layer_translation(&fixture, { 5, 0, 0 }, 2);
    ClipId high = layer_translation(&fixture, { 0, 9, 0 });
    ClipId low = layer_translation(&fixture, { 0, 5, 0 });
    fixture.animator.play(&fixture.assets, upper, { .layer = 1 })!!;
    AnimationActionId from = fixture.animator.play(&fixture.assets, high)!!;
    AnimationActionId to = fixture.animator.play(&fixture.assets, low, { .fade_in = 1 })!!;
    fixture.animator.cross_fade(from, to, 1)!!;
    anim::update(&fixture.assets, &fixture.scene, 0.5f);
    ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
    assert(approx(instance.nodes[3].local.position.y, 7));
    assert(approx(instance.nodes[2].local.position.x, 5));
    anim::update(&fixture.assets, &fixture.scene, 0.6f);
    assert(approx(instance.nodes[3].local.position.y, 5));
    assert(approx(instance.nodes[2].local.position.x, 5));
    assert(fixture.animator.action_count == 2);
}

fn void test_additive_reference_preserves_base_and_applies_all_channels() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    float[2] times = { 0, 1 };
    float[2] base_morph = { 0.25f, 0.25f };
    Track[2] base_tracks = {
        constant_translation({ 0, 2, 0 }),
        make_track(
            path: TargetPath.MORPH_WEIGHTS,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: base_morph[..],
            target: 1,
        ),
    };
    uint[2] targets = { 3, 1 };
    ClipId base = add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: base_tracks[..],
        targets: targets[..],
        duration: 1,
    );
    float[6] positions = { 0, 0, 0, 0, 4, 0 };
    float[8] rotations = { 0, 0, 0.7071068f, 0.7071068f, 0, 0, 1, 0 };
    float[6] scales = { 1, 2, 1, 3, 4, 1 };
    float[2] morphs = { 0.2f, 0.6f };
    Track[4] tracks = {
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
        make_track(
            path: TargetPath.SCALE,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: scales[..],
        ),
        make_track(
            path: TargetPath.MORPH_WEIGHTS,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: morphs[..],
            target: 1,
        ),
    };
    ClipId overlay = add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
    fixture.animator.play(&fixture.assets, base)!!;
    AnimationActionId action = fixture.animator.play(&fixture.assets, overlay, { .layer = 1, .additive = true })!!;
    fixture.animator.action(action).weight = 0.5f;
    anim::update(&fixture.assets, &fixture.scene, 0);
    ModelInstance* instance = fixture.scene.get(fixture.root, ModelInstance);
    Node* tip = instance.nodes[3];
    Mesh* mesh = fixture.scene.get(instance.nodes[1], Mesh);
    assert(approx(tip.local.position.y, 2));
    assert(rotates_x_to(tip.local.rotation, { 1, 0, 0 }));
    assert(tip.local.scale == (Vec3){ 1, 1, 1 });
    assert(approx(mesh.morph_weights[0], 0.25f));
    anim::update(&fixture.assets, &fixture.scene, 0.5f);
    assert(approx(tip.local.position.y, 3));
    assert(rotates_x_to(tip.local.rotation, { 0.9238795f, 0.3826834f, 0 }));
    assert((tip.local.scale - (Vec3){ 1.5f, 1.5f, 1 }).length() < 1e-4f);
    assert(approx(mesh.morph_weights[0], 0.35f));
}

fn void test_additive_cubic_reference_reads_key_value_not_tangents() @test {
    LayerFixture fixture;
    create_layer_fixture(&fixture);
    defer destroy_layer_fixture(&fixture);

    float[2] times = { 0, 1 };
    float[18] values = { 9, 9, 9, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 7, 0, 8, 8, 8 };
    Track[1] tracks = { make_track(
        path: TargetPath.TRANSLATION,
        interpolation: Interpolation.CUBIC_SPLINE,
        times: times[..],
        values: values[..],
    ) };
    uint[1] targets = { 3 };
    ClipId clip = add_clip(
        assets: &fixture.assets,
        key: "",
        tracks: tracks[..],
        targets: targets[..],
        duration: 1,
    );
    fixture.animator.play(&fixture.assets, clip, { .additive = true })!!;
    anim::update(&fixture.assets, &fixture.scene, 0);
    Node* tip = fixture.scene.get(fixture.root, ModelInstance).nodes[3];
    assert(approx(tip.local.position.y, 1));
    anim::update(&fixture.assets, &fixture.scene, 0.5f);
    assert(approx(tip.local.position.y, 3));
}

fn void test_additive_rotations_follow_play_order_and_shortest_hemisphere() @test {
    for (uint reverse = 0; reverse < 2; reverse++) {
        LayerFixture fixture;
        create_layer_fixture(&fixture);
        defer destroy_layer_fixture(&fixture);

        float[2] times = { 0, 1 };
        float[8] z_values = { 0, 0, 0, 1, 0, 0, -0.7071068f, -0.7071068f };
        float[8] y_values = { 0, 0, 0, 1, 0, 0.7071068f, 0, 0.7071068f };
        Track[1] z_track = { make_track(
            path: TargetPath.ROTATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: z_values[..],
        ) };
        Track[1] y_track = { make_track(
            path: TargetPath.ROTATION,
            interpolation: Interpolation.LINEAR,
            times: times[..],
            values: y_values[..],
        ) };
        uint[1] targets = { 3 };
        ClipId z_clip = add_clip(
            assets: &fixture.assets,
            key: "",
            tracks: z_track[..],
            targets: targets[..],
            duration: 1,
        );
        ClipId y_clip = add_clip(
            assets: &fixture.assets,
            key: "",
            tracks: y_track[..],
            targets: targets[..],
            duration: 1,
        );
        AnimationActionId first = fixture.animator.play(
            assets: &fixture.assets,
            clip: reverse ? y_clip : z_clip,
            desc: { .additive = true },
        )!!;
        AnimationActionId second = fixture.animator.play(
            assets: &fixture.assets,
            clip: reverse ? z_clip : y_clip,
            desc: { .additive = true },
        )!!;
        fixture.animator.action(first).time = 1;
        fixture.animator.action(second).time = 1;
        fixture.animator.action(first).playing = false;
        fixture.animator.action(second).playing = false;
        anim::update(&fixture.assets, &fixture.scene, 0);
        Node* tip = fixture.scene.get(fixture.root, ModelInstance).nodes[3];
        assert(rotates_x_to(tip.local.rotation, reverse ? (Vec3){ 0, 1, 0 } : (Vec3){ 0, 0, -1 }));
    }
}

fn void test_masks_references_and_action_pool_release_with_animator() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        LayerFixture fixture;
        create_layer_fixture(&fixture, &tracker);
        defer destroy_layer_fixture(&fixture);

        ClipId clip = layer_translation(&fixture, { 0, 2, 0 });
        fixture.animator.play(&fixture.assets, clip, { .additive = true })!!;
        sz allocations = tracker.total_allocation_count();
        for (uint frame = 0; frame < 100; frame++) anim::update(&fixture.assets, &fixture.scene, 0.01f);
        assert(tracker.total_allocation_count() == allocations);
        sz bytes = tracker.allocated();
        fixture.scene.remove_component(fixture.root, Animator);
        assert(tracker.allocated() < bytes);
        fixture.animator = anim::add_animator(&fixture.scene, fixture.root);
        fixture.animator.play(&fixture.assets, clip)!!;
        anim::update(&fixture.assets, &fixture.scene, 0);
    }
    assert(!tracker.has_leaks());
}
