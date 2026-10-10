module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::hash::sha256;
import std::io;
import std::io::file;

const String CROWD_NATIVE_QUATERNIUS @private = "../../../examples/assets/quaternius/AnimationLibrary_Godot.glb";
const String CROWD_NATIVE_MORPH_CUBE @private = "../../../examples/assets/gltf/AnimatedMorphCube.glb";
const String CROWD_NATIVE_QUATERNIUS_SHA @private = "272d5c1e2c27f566595ece27b6985935d42dcee1dacee1b320af9f0c40d5c97c";
const String CROWD_NATIVE_MORPH_CUBE_SHA @private = "214ee56160a50dbf22543a1d66dbf860986e87f0efac3d89feac1359d0e6aeab";

fn ModelId? load_crowd_native_cc0(
    Fixture* fixture,
    String filename,
    String expected_hash,
) @private {
    char[] bytes = file::load(fixture.allocator, filename)!;
    defer alloc::free(fixture.allocator, bytes.ptr);
    char[32] digest = sha256::hash(bytes);
    char[64] encoded;
    foreach (index, value : digest) {
        encoded[index * 2] = "0123456789abcdef"[((uint)value & 255) >> 4];
        encoded[index * 2 + 1] = "0123456789abcdef"[(uint)value & 15];
    }
    assert((String)encoded[..] == expected_hash, "CC0 source bytes differ from the approved fixture");
    io::printfn("CC0 source=%s bytes=%s sha256=%s", filename, bytes.len, (String)encoded[..]);
    LoadOptions options = asset::LOAD_OPTIONS_DEFAULT;
    options.generate_tangents = false;
    return gltf::load_model_memory(
        assets: &fixture.assets,
        bytes: bytes,
        base_dir: "../../../examples/assets",
        key: filename,
        options: options,
    );
}

fn ClipId? crowd_native_clip_named(Fixture* fixture, ModelId model, String name) @private {
    foreach (clip : fixture.assets.model(model).data.clips) {
        if (fixture.assets.clip(clip).data.name == name) return clip;
    }
    return NOT_FOUND~;
}

fn void crowd_native_flat_source_materials(Fixture* fixture, ModelId model) @private {
    foreach (mesh : fixture.assets.model(model).data.meshes) {
        fixture.assets.material(mesh.material).data = material::basic({ .color = { 1, 1, 1, 1 } });
        fixture.assets.mark_material_dirty(mesh.material);
    }
}

fn Transform[CROWD_NATIVE_INSTANCES] crowd_native_real_placements() @private {
    Transform[CROWD_NATIVE_INSTANCES] placements;
    foreach (index, &placement : placements) {
        *placement = maths::TRANSFORM_IDENTITY;
        placement.position.x = ((float)index - 1) * 3;
        placement.scale = { index == 2 ? -0.9f : 0.9f, 1.1f, 0.8f };
    }
    return placements;
}

fn void? crowd_native_stop_all(CrowdNativePair* pair) @private {
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        CrowdPlayer player = crowd_native_player(pair, source)!;
        CrowdPlaybackSlot* slot = &player.state.slots[source];
        while (slot.action_count) player.stop(slot.order[slot.action_count - 1])!;
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        while (animator.action_count) animator.stop(animator.order[animator.action_count - 1])!;
    }
}

fn void test_crowd_native_quaternius_independent_walk_and_jog_match_animator() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ModelId model = load_crowd_native_cc0(&fixture, CROWD_NATIVE_QUATERNIUS, CROWD_NATIVE_QUATERNIUS_SHA)!!;
    crowd_native_flat_source_materials(&fixture, model);
    ClipId walk = crowd_native_clip_named(&fixture, model, "Walk_Loop")!!;
    ClipId jog = crowd_native_clip_named(&fixture, model, "Jog_Fwd_Loop")!!;
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    CrowdNativePair pair;
    create_crowd_native_pair(
        allocator: mem,
        fixture: &fixture,
        pair: &pair,
        model: model,
        clip: walk,
        bounds: { .min = { -1.5f, -0.1f, -1.5f }, .max = { 1.5f, 2.7f, 1.5f } },
        placements: placements[..],
    )!!;
    defer scene::destroy_scene(&pair.scene);
    *pair.scene.get(pair.camera, Camera) = camera::orthographic(5, 0.1f, 100);
    pair.camera.local.position = { 0, 1, 12 };
    float walk_duration = fixture.assets.clip(walk).data.duration;
    float jog_duration = fixture.assets.clip(jog).data.duration;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        CrowdPlayer player = crowd_native_player(&pair, source)!!;
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        float time = (0.125f + 0.25f * (float)source) * walk_duration;
        crowd_native_action_controls(player.base_action()!!, time, 0.75f);
        crowd_native_action_controls(animator.action(pair.ordinary_base[source]), time, 0.75f);
        crowd_native_play_both(
            fixture: &fixture,
            pair: &pair,
            source: source,
            clip: jog,
            desc: {},
            time: (0.2f + 0.2f * (float)source) * jog_duration,
            weight: 0.25f,
        )!!;
    }
    crowd_native_update(&fixture, &pair, 0);
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    assert(crowd.parts.len == 2 && crowd.joint_count == 53);
    CrowdNativeOutput output;
    create_crowd_native_output(&fixture, &output)!!;
    defer destroy_crowd_native_output(&fixture, &output);
    compare_crowd_native_paths(&fixture, &pair, &output)!!;
}

fn void test_crowd_native_animated_morph_cube_additive_and_rest_defaults_match_animator() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ModelId model = load_crowd_native_cc0(&fixture, CROWD_NATIVE_MORPH_CUBE, CROWD_NATIVE_MORPH_CUBE_SHA)!!;
    crowd_native_flat_source_materials(&fixture, model);
    ClipId clip = fixture.assets.model(model).data.clips[0];
    float duration = fixture.assets.clip(clip).data.duration;
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    foreach (&placement : placements) placement.scale *= 0.6f;
    CrowdNativePair pair;
    create_crowd_native_pair(
        allocator: mem,
        fixture: &fixture,
        pair: &pair,
        model: model,
        clip: clip,
        bounds: { .min = { -2, -2, -2 }, .max = { 2, 2, 2 } },
        placements: placements[..],
    )!!;
    defer scene::destroy_scene(&pair.scene);
    *pair.scene.get(pair.camera, Camera) = camera::orthographic(5, 0.1f, 100);
    pair.camera.local.position = { 0, 0, 12 };
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        CrowdPlayer player = crowd_native_player(&pair, source)!!;
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        float time = (0.2f + 0.25f * (float)source) * duration;
        crowd_native_action_controls(player.base_action()!!, time);
        crowd_native_action_controls(animator.action(pair.ordinary_base[source]), time);
    }
    crowd_native_play_both(
        fixture: &fixture,
        pair: &pair,
        source: 1,
        clip: clip,
        desc: { .layer = 1, .additive = true },
        time: duration * 0.5f,
        weight: 0.5f,
    )!!;
    crowd_native_update(&fixture, &pair, 0);
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    assert(crowd.parts.len == 1 && crowd.joint_count == 0);
    CrowdNativeOutput output;
    create_crowd_native_output(&fixture, &output)!!;
    defer destroy_crowd_native_output(&fixture, &output);
    compare_crowd_native_paths(&fixture, &pair, &output)!!;
    crowd_native_stop_all(&pair)!!;
    crowd_native_update(&fixture, &pair, 0);
    compare_crowd_native_paths(&fixture, &pair, &output)!!;
}

fn void test_crowd_native_u16_joint_indices_and_morph_part_match_animator() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ModelId model = add_wide_crowd_model(&fixture)!!;
    ModelTemplate* template = &fixture.assets.model(model).data;
    template.nodes[1].local.position.x = -0.7f;
    template.nodes[WIDE_JOINT_COUNT].local.position.x = 0.7f;
    crowd_native_flat_source_materials(&fixture, model);
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    CrowdNativePair pair;
    create_crowd_native_pair(
        allocator: mem,
        fixture: &fixture,
        pair: &pair,
        model: model,
        clip: template.clips[0],
        bounds: { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } },
        placements: placements[..],
    )!!;
    defer scene::destroy_scene(&pair.scene);
    *pair.scene.get(pair.camera, Camera) = camera::orthographic(5, 0.1f, 100);
    pair.camera.local.position = { 0, 0, 12 };
    crowd_native_update(&fixture, &pair, 0);
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    assert(crowd.joint_count == WIDE_JOINT_COUNT && crowd.parts.len == 2);
    CrowdNativeOutput output;
    create_crowd_native_output(&fixture, &output)!!;
    defer destroy_crowd_native_output(&fixture, &output);
    compare_crowd_native_paths(&fixture, &pair, &output)!!;
}
