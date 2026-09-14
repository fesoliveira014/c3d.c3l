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

fn Track make_track(TargetPath path, Interpolation interpolation, float[] times, float[] values, uint target = 0) @local {
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

fn ClipId add_clip(AssetStore* assets, String key, Track[] tracks, uint[] targets, float duration) @local {
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
    return make_track(TargetPath.TRANSLATION, Interpolation.STEP, times[..], values[..]);
}

fn Track step_translation() @local {
    float[3] times = { 0, 1, 2 };
    float[9] values = { 0, 0, 0, 1, 1, 1, 2, 2, 2 };
    return make_track(TargetPath.TRANSLATION, Interpolation.STEP, times[..], values[..]);
}

fn Track linear_translation() @local {
    float[3] times = { 0, 1, 2 };
    float[9] values = { 0, 0, 0, 1, 1, 1, 2, 2, 2 };
    return make_track(TargetPath.TRANSLATION, Interpolation.LINEAR, times[..], values[..]);
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
    anim::sample_track(&track, 0.99f, &cursor, out[..]);
    assert(out[0] == 0 && cursor == 0);
    anim::sample_track(&track, 1, &cursor, out[..]);
    assert(out[0] == 1 && cursor == 1);
    anim::sample_track(&track, 5, &cursor, out[..]);
    assert(out[0] == 2 && out[2] == 2);
    anim::sample_track(&track, -1, &cursor, out[..]);
    assert(out[0] == 0 && cursor == 0);
}

fn void test_sample_linear_interpolates_between_keys() @test {
    Track track = linear_translation();
    defer free_track(&track);
    float[3] out;
    uint cursor;
    anim::sample_track(&track, 0.5f, &cursor, out[..]);
    assert(approx(out[0], 0.5f) && approx(out[2], 0.5f));
    anim::sample_track(&track, 1.75f, &cursor, out[..]);
    assert(approx(out[1], 1.75f) && cursor == 1);
}

fn void test_sample_rotation_takes_short_path() @test {
    float[2] times = { 0, 1 };
    float[8] values = { 0, 0, 0, 1, 0, -0.7071068f, 0, -0.7071068f };
    Track track = make_track(TargetPath.ROTATION, Interpolation.LINEAR, times[..], values[..]);
    defer free_track(&track);
    float[4] out;
    uint cursor;
    anim::sample_track(&track, 0.5f, &cursor, out[..]);
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
    Track track = make_track(TargetPath.TRANSLATION, Interpolation.CUBIC_SPLINE, times[..], values[..]);
    defer free_track(&track);
    assert(track.stride() == 3);
    float[3] out;
    uint cursor;
    anim::sample_track(&track, 1, &cursor, out[..]);
    assert(approx(out[0], 1.25f) && out[1] == 0);
    anim::sample_track(&track, 2, &cursor, out[..]);
    assert(out[0] == 2);
}

fn void test_cursor_reseeks_after_backwards_jump() @test {
    Track track = linear_translation();
    defer free_track(&track);
    float[3] out;
    uint cursor;
    anim::sample_track(&track, 1.5f, &cursor, out[..]);
    assert(cursor == 1);
    anim::sample_track(&track, 0.2f, &cursor, out[..]);
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
    ClipId clip = add_clip(&assets, "lift", tracks[..], targets[..], 1);

    Animator* animator = anim::add_animator(&scene, root);
    Action* action = animator.play(&assets, clip)!!;
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
    ClipId low_clip = add_clip(&assets, "low", low[..], targets[..], 1);
    ClipId high_clip = add_clip(&assets, "high", high[..], targets[..], 1);

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
    Action* paused = anim::add_animator(&scene, second).play(&assets, clip)!!;
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
    ClipId clip = add_clip(&assets, "lift", tracks[..], targets[..], 1);

    Animator* animator = anim::add_animator(&scene, root);
    Action* action = animator.play(&assets, clip)!!;
    anim::update(&assets, &scene, 0);
    assert(approx(tip.local.position.y, 9));

    animator.stop(action, 1);
    anim::update(&assets, &scene, 0.5f);
    assert(approx(tip.local.position.y, 5) && animator.actions.len() == 1);
    anim::update(&assets, &scene, 0.6f);
    assert(animator.actions.len() == 0 && approx(tip.local.position.y, 1));
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
    ClipId high_clip = add_clip(&assets, "high", high[..], targets[..], 1);
    ClipId low_clip = add_clip(&assets, "low", low[..], targets[..], 1);

    Animator* animator = anim::add_animator(&scene, root);
    animator.play(&assets, high_clip)!!;
    animator.play(&assets, low_clip, fade_in: 10)!!;
    animator.cross_fade(&animator.actions[0], &animator.actions[1], 1);
    anim::update(&assets, &scene, 0.5f);
    assert(approx(tip.local.position.y, 7));
    anim::update(&assets, &scene, 0.5f);
    assert(animator.actions.len() == 1 && approx(tip.local.position.y, 5));
    assert(animator.actions[0].clip.index == low_clip.index);
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
    Track[1] tracks = { make_track(TargetPath.TRANSLATION, Interpolation.LINEAR, times[..], values[..]) };
    uint[1] targets = { 3 };
    ClipId clip = add_clip(&assets, "rise", tracks[..], targets[..], 1);

    Animator* animator = anim::add_animator(&scene, root);
    Action* once = animator.play(&assets, clip)!!;
    once.loop = false;
    anim::update(&assets, &scene, 2);
    assert(once.time == 1 && !once.playing && approx(tip.local.position.y, 9));

    animator.play(&assets, clip)!!;
    anim::update(&assets, &scene, 1.5f);
    assert(approx(animator.actions[1].time, 0.5f) && animator.actions[1].playing);
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
    ClipId foreign = add_clip(&assets, "foreign", tracks[..], targets[..], 1);
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
    assert(animator.actions.len() == 0);
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
