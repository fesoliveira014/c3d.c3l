module c3d::test::profile_integration @feat(C3D_PROFILE_CPU);

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::model;
import c3d::profile;
import c3d::scene;
import std::io::path;
import std::math;

fn void test_scene_scopes_follow_application_capture_selection() @test {
    Recorder recorder = profile::create_recorder(mem, {
        .frame_capacity = 2,
        .cpu_scopes_per_frame = 8,
        .max_depth = 4,
        .label_bytes_per_frame = 128,
    })!!;
    defer profile::destroy_recorder(&recorder);

    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    Node* parent = scene.add_node()!!;
    Node* child = scene.add_node(parent)!!;
    parent.local.position = { 1, 0, 0 };
    child.local.position = { 0, 2, 0 };

    profile::@capture(&recorder, 0) {
        profile::@scope("simulation") {
            scene.update_world();
        };
    };

    assert(child.world_position() == (Vec3){ 1, 2, 0 });
    FrameCaptureView frame = recorder.frame(0)!!;
    assert(frame.cpu_state == CaptureState.READY);
    assert(!frame.truncated && frame.dropped_cpu_scopes == 0);
    assert(frame.cpu[0].label == "simulation");
    assert(frame.cpu[0].origin == ScopeOrigin.APPLICATION);
    assert(!frame.cpu[0].has_parent && frame.cpu[0].self_complete);
    $if $feat(C3D_PROFILE_INTERNAL):
        assert(frame.cpu.len == 2);
        assert(frame.cpu[1].label == "scene.update_world");
        assert(frame.cpu[1].origin == ScopeOrigin.LIBRARY);
        assert(frame.cpu[1].has_parent && frame.cpu[1].parent_index == 0);
        assert(frame.cpu[1].self_complete);
    $else
        assert(frame.cpu.len == 1);
    $endif

    child.local.position = { 0, 3, 0 };
    scene.update_world();
    assert(child.world_position() == (Vec3){ 1, 3, 0 });
    assert(recorder.frame(0)!!.cpu.len == frame.cpu.len);

    recorder.set_enabled(false);
    profile::@capture(&recorder, 1) {
        scene.update_world();
    };
    if (catch excuse = recorder.frame(1)) {
        assert(excuse == profile::NOT_FOUND);
    } else {
        assert(false);
    }
}

fn String fixture_path(String name) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend("../fixtures/gltf", name)!!;
}

fn AssetStore create_animated_store() @local {
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

fn ClipId add_lift_clip(AssetStore* assets, uint target, float lift) @local {
    float[2] times = { 0, 1 };
    float[6] values = { 0, lift, 0, 0, lift, 0 };
    Track track = { .target = 0, .path = TargetPath.TRANSLATION, .interpolation = Interpolation.STEP };
    track.times = alloc::new_array(mem, float, times.len);
    track.times[..] = times[..];
    track.values = alloc::new_array(mem, float, values.len);
    track.values[..] = values[..];
    AnimationClip clip = { .name = "lift".copy(mem), .duration = 1 };
    clip.tracks = alloc::new_array(mem, Track, 1);
    clip.tracks[0] = track;
    clip.targets = alloc::new_array(mem, uint, 1);
    clip.targets[0] = target;
    return assets.add_clip_owned(&clip, "lift")!!;
}

fn void test_animator_scope_nests_under_application_scope() @test {
    Recorder recorder = profile::create_recorder(mem, {
        .frame_capacity = 2,
        .cpu_scopes_per_frame = 8,
        .max_depth = 4,
        .label_bytes_per_frame = 128,
    })!!;
    defer profile::destroy_recorder(&recorder);

    AssetStore assets = create_animated_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("skin.gltf"))!!;
    Node* root = model::instantiate(&assets, &scene, model)!!;
    ModelInstance* instance = scene.get(root, ModelInstance);
    ClipId clip = add_lift_clip(&assets, 3, 9);
    anim::add_animator(&scene, root).play(&assets, clip)!!;

    profile::@capture(&recorder, 0) {
        profile::@scope("simulation") {
            anim::update(&assets, &scene, 0);
        };
    };

    assert(instance.nodes[3].local.position.y == 9);
    FrameCaptureView frame = recorder.frame(0)!!;
    assert(frame.cpu_state == CaptureState.READY);
    assert(!frame.truncated && frame.dropped_cpu_scopes == 0);
    assert(frame.cpu[0].label == "simulation");
    assert(frame.cpu[0].origin == ScopeOrigin.APPLICATION);
    $if $feat(C3D_PROFILE_INTERNAL):
        assert(frame.cpu.len == 2);
        assert(frame.cpu[1].label == "anim.update");
        assert(frame.cpu[1].origin == ScopeOrigin.LIBRARY);
        assert(frame.cpu[1].has_parent && frame.cpu[1].parent_index == 0);
        assert(frame.cpu[1].self_complete);
    $else
        assert(frame.cpu.len == 1);
    $endif
}

fn void test_animator_scope_follows_disabled_capture() @test {
    Recorder recorder = profile::create_recorder(mem, {
        .frame_capacity = 2,
        .cpu_scopes_per_frame = 8,
        .max_depth = 4,
        .label_bytes_per_frame = 128,
    })!!;
    defer profile::destroy_recorder(&recorder);

    AssetStore assets = create_animated_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("skin.gltf"))!!;
    Node* root = model::instantiate(&assets, &scene, model)!!;
    ModelInstance* instance = scene.get(root, ModelInstance);
    ClipId clip = add_lift_clip(&assets, 3, 9);
    anim::add_animator(&scene, root).play(&assets, clip)!!;

    recorder.set_enabled(false);
    profile::@capture(&recorder, 0) {
        anim::update(&assets, &scene, 0);
    };

    assert(instance.nodes[3].local.position.y == 9);
    if (catch excuse = recorder.frame(0)) {
        assert(excuse == profile::NOT_FOUND);
    } else {
        assert(false);
    }
}
