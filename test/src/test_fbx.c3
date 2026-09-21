module c3d::test::fbx;

import c3d;
import c3d::anim;
import c3d::anim::retarget;
import c3d::asset;
import c3d::asset::fbx;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::io::path;
import std::math;

const float TOLERANCE @local = 0.0005f;

fn String fixture_path(String name) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend("../fixtures/fbx", name)!!;
}

fn AssetStore create_store() @local {
    return asset::create_asset_store(mem, {
        .max_geometries = 8,
        .max_textures   = asset::BUILTIN_TEXTURE_COUNT + 8,
        .max_materials  = 8,
        .max_samplers   = asset::BUILTIN_SAMPLER_COUNT + 2,
        .max_models     = 2,
        .max_skeletons  = 2,
        .max_clips      = 2,
    });
}

fn bool close(float first, float second, float tolerance = TOLERANCE) @local {
    return math::abs(first - second) <= tolerance;
}

fn bool close_vec3(Vec3 first, Vec3 second) @local {
    return close(first.x, second.x) && close(first.y, second.y) && close(first.z, second.z);
}

fn void test_cube_converts_to_meters_with_part_child_and_keys() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    String path = fixture_path("maya_cube_7400_binary.fbx");
    ModelId model = fbx::load_model(&assets, path)!!;
    assert(assets.find_model(path)!!.index == model.index);

    ModelTemplate* template = &assets.model(model).data;
    assert(template.nodes.len == 2 && template.meshes.len == 1 && template.skins.len == 0);
    assert(template.nodes[0].name == "pCube1" && template.nodes[0].parent == -1);
    assert(template.nodes[1].name == "pCube1/part/0" && template.nodes[1].parent == 0);
    assert(template.meshes[0].node == 1 && template.meshes[0].default_morph_weights.len == 0);

    GeometryId geometry_id = assets.find_geometry(string::tformat("%s#mesh/0/0", path))!!;
    assert(template.meshes[0].geometry.index == geometry_id.index);
    Geometry* geometry = &assets.geometry(geometry_id).data;
    assert(geometry.topology == Topology.TRIANGLES && geometry.indices.len == 36);
    assert(geometry.positions.len == 24 && geometry.normals.len == 24 && geometry.uv0.len == 24);
    assert(close_vec3(geometry.bounds.min, { -0.005f, -0.005f, -0.005f }));
    assert(close_vec3(geometry.bounds.max, { 0.005f, 0.005f, 0.005f }));

    MaterialId material_id = assets.find_material(string::tformat("%s#material/0", path))!!;
    assert(template.meshes[0].material.index == material_id.index);
    Material* material = &assets.material(material_id).data;
    assert(material.kind == MaterialKind.STANDARD && material.common.alpha_mode == AlphaMode.OPAQUE);
    assert(close_vec3(material.standard.base_color.xyz, { 0.4f, 0.4f, 0.4f }) && material.standard.base_color.w == 1);
    assert(material.standard.roughness == 1 && material.standard.metallic == 0);
    assert(material.standard.emissive == (Vec3){ 0, 0, 0 });

    assert(template.clips.len == 1);
    AnimationClip* clip = &assets.clip(template.clips[0]).data;
    assert(clip.name == "Take 001" && clip.tracks.len == 0);
}

fn void test_half_skinned_binds_unweighted_vertices_to_the_mesh() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    String path = fixture_path("blender_293_half_skinned_7400_binary.fbx");
    ModelTemplate* template = &assets.model(fbx::load_model(&assets, path)!!).data;
    assert(template.nodes.len == 5);
    assert(template.nodes[0].name == "Plane" && template.nodes[1].name == "Plane/part/0");
    assert(template.nodes[2].name == "Armature" && template.nodes[3].name == "Bone");
    assert(template.nodes[4].name == "Bone_end");
    assert(template.nodes[3].parent == 2 && template.nodes[4].parent == 3);

    assert(template.skins.len == 1);
    ModelSkin* skin = &template.skins[0];
    assert(skin.mesh_node == 1 && skin.joint_nodes.len == 2);
    assert(skin.joint_nodes[0] == 3 && skin.joint_nodes[1] == 1);
    SkeletonId skeleton_id = assets.find_skeleton(string::tformat("%s#skeleton/0", path))!!;
    assert(skin.skeleton.index == skeleton_id.index);

    Skeleton* skeleton = &assets.skeleton(skeleton_id).data;
    assert(skeleton.joint_names.len == 2);
    assert(skeleton.joint_names[0] == "Bone" && skeleton.joint_names[1] == "Plane");
    assert(skeleton.parents[0] == -1 && skeleton.parents[1] == -1);
    assert(close_vec3(skeleton.rest_pose[0].position, { 0, 0, 1 }));
    assert(close(skeleton.rest_pose[0].rotation.v.x, 0.7071f) && close(skeleton.rest_pose[0].rotation.v.w, 0.7071f));
    assert(close_vec3(maths::transform_point(skeleton.inverse_bind[0], { 0, 1, 0 }), { 0, 0, -1 }));
    assert(close_vec3(maths::transform_point(skeleton.inverse_bind[1], { 1, 2, 3 }), { 1, 2, 3 }));

    Geometry* geometry = &assets.geometry(assets.find_geometry(string::tformat("%s#mesh/0/0", path))!!).data;
    assert(geometry.positions.len == 4 && geometry.joints.len == 4 && geometry.weights.len == 4);
    foreach (index, position : geometry.positions) {
        ushort expected = position.y < 0 ? 0 : 1;
        assert(geometry.joints[index][0] == expected);
        assert(geometry.weights[index] == (Vec4){ 1, 0, 0, 0 });
    }
    MaterialId default_material = assets.find_material(string::tformat("%s#material/default", path))!!;
    assert(template.meshes[0].material.index == default_material.index);
}

fn void test_in_between_channels_convert_with_their_weight_track() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    String path = fixture_path("maya_blend_inbetween_7500_binary.fbx");
    ModelId model = fbx::load_model(&assets, path)!!;
    ModelTemplate* template = &assets.model(model).data;
    assert(template.nodes.len == 2 && template.meshes.len == 1);
    float[] defaults = template.meshes[0].default_morph_weights;
    assert(defaults.len == 2 && close(defaults[0], -1) && close(defaults[1], 2));

    Geometry* geometry = &assets.geometry(template.meshes[0].geometry).data;
    assert(geometry.targets.len == 5 && geometry.channels.len == 2);
    MorphChannel* lift = &geometry.channels[0];
    MorphChannel* side = &geometry.channels[1];
    assert(lift.name == "KeyBlend.LiftTop" && lift.first_target == 0 && lift.full_weights.len == 2);
    assert(close(lift.full_weights[0], 0.5f) && close(lift.full_weights[1], 1));
    assert(side.name == "KeyBlend.MoveToSide" && side.first_target == 2 && side.full_weights.len == 3);
    assert(close(side.full_weights[0], -0.499f, 0.001f) && close(side.full_weights[1], -0.249f, 0.001f));
    assert(geometry.targets[4].name == "MoveToSide");
    float largest_delta;
    foreach (&target : geometry.targets) {
        assert(target.position_deltas.len == geometry.positions.len);
        assert(target.normal_deltas.len == geometry.positions.len);
        foreach (delta : target.position_deltas) largest_delta = math::max(largest_delta, delta.length());
    }
    assert(largest_delta > 0.007f && largest_delta < 0.008f);

    AnimationClip* clip = &assets.clip(template.clips[0]).data;
    assert(clip.tracks.len == 1);
    Track* track = &clip.tracks[0];
    assert(clip.targets[track.target] == 1);
    assert(track.path == TargetPath.MORPH_WEIGHTS && track.interpolation == Interpolation.LINEAR);
    assert(track.stride() == 2 && track.times.len == 31 && track.values.len == 62);
    assert(track.times[0] == 0 && close(track.times[30], 4.95833f, 0.001f));
    assert(close(track.values[0], -1) && close(track.values[1], 2));
    assert(close(track.values[60], 2) && close(track.values[61], -1));
    assert(close(clip.duration, 4.95833f, 0.001f));

    Scene scene = scene::create_scene(mem, { .max_nodes = 8 });
    defer scene::destroy_scene(&scene);
    Node* root = model::instantiate(&assets, &scene, model)!!;
    Animator* animator = anim::add_animator(&scene, root);
    animator.play(&assets, template.clips[0])!!;
}

fn void test_embedded_textures_pack_roughness_metalness_and_opacity() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    String path = fixture_path("blender_293_embedded_textures_7400_binary.fbx");
    fbx::load_model(&assets, path)!!;

    Material* material = &assets.material(assets.find_material(string::tformat("%s#material/0", path))!!).data;
    assert(material.kind == MaterialKind.STANDARD && material.common.alpha_mode == AlphaMode.BLEND);
    assert(material.standard.base_color == (Vec4){ 1, 1, 1, 1 });
    assert(material.standard.roughness == 1 && material.standard.metallic == 1);
    assert(material.standard.emissive == (Vec3){ 1, 1, 1 });

    TextureId packed_id = assets.find_texture(string::tformat("%s#image/3+4/metallic_roughness/direct", path))!!;
    assert(material.standard.metallic_roughness_map.texture.asset.index == packed_id.index);
    TextureAsset* packed = assets.texture(packed_id);
    assert(packed.desc.width == 128 && packed.desc.height == 128 && packed.desc.format == RGBA8_UNORM);
    assert(packed.pixels[0] == 0 && packed.pixels[1] == 95 && packed.pixels[2] == 99 && packed.pixels[3] == 255);
    for (usz pixel = 0; pixel < 128 * 128; pixel++) {
        assert(packed.pixels[pixel * 4] == 0 && packed.pixels[pixel * 4 + 3] == 255);
    }

    TextureId base_id = assets.find_texture(string::tformat("%s#image/0+1/srgb", path))!!;
    assert(material.standard.base_color_map.texture.asset.index == base_id.index);
    TextureAsset* base = assets.texture(base_id);
    assert(base.desc.format == RGBA8_SRGB && base.desc.width == 128);
    assert(base.pixels[0] == 124 && base.pixels[1] == 81 && base.pixels[2] == 81 && base.pixels[3] == 111);

    TextureId emissive_id = assets.find_texture(string::tformat("%s#image/2/srgb", path))!!;
    assert(material.standard.emissive_map.texture.asset.index == emissive_id.index);
}

fn void test_unreadable_texture_file_faults_and_leaves_store_unchanged() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    String path = fixture_path("blender_279_internal_textures_7400_binary.fbx");
    sz keys_before = assets.keys.len();
    if (catch excuse = fbx::load_model(&assets, path)) {
        assert(excuse == c3d::ASSET_IO_ERROR);
    } else {
        assert(false, "expected a fault");
    }
    assert(assets.keys.len() == keys_before);
}

fn void test_missing_file_is_an_io_fault() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    if (catch excuse = fbx::load_model(&assets, fixture_path("__missing__.fbx"))) {
        assert(excuse == c3d::ASSET_IO_ERROR);
    } else {
        assert(false, "expected a fault");
    }
}

fn void test_duplicate_model_key_faults_before_insertion() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    String path = fixture_path("maya_cube_7400_binary.fbx");
    fbx::load_model(&assets, path)!!;
    sz keys_before = assets.keys.len();
    if (catch excuse = fbx::load_model(&assets, path)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "expected a fault");
    }
    assert(assets.keys.len() == keys_before);
}

fn void test_load_animations_rebinds_a_file_onto_a_model() @test {
    AssetStore assets = asset::create_asset_store(mem, {
        .max_geometries = 8,
        .max_textures   = asset::BUILTIN_TEXTURE_COUNT + 8,
        .max_materials  = 8,
        .max_samplers   = asset::BUILTIN_SAMPLER_COUNT + 2,
        .max_models     = 2,
        .max_skeletons  = 2,
        .max_clips      = 4,
    });
    defer asset::destroy_asset_store(&assets);
    String path = fixture_path("maya_kenney_character_7700_binary.fbx");
    ModelId model = fbx::load_model(&assets, path)!!;
    ModelTemplate* template = &assets.model(model).data;

    ClipId[] clips = fbx::load_animations(mem, &assets, path, model)!!;
    defer alloc::free(mem, clips.ptr);
    assert(clips.len == 1);
    ClipId keyed = assets.find_clip(string::tformat("%s#anim/0#%s#keep", path, path))!!;
    assert(keyed.index == clips[0].index);
    AnimationClip* clip = &assets.clip(clips[0]).data;
    assert(clip.tracks.len == 119);
    foreach (target : clip.targets) assert(target < template.nodes.len);
    bool root_translation;
    foreach (&track : clip.tracks) {
        if (track.path != TargetPath.TRANSLATION) continue;
        assert(template.nodes[clip.targets[track.target]].name == "Root");
        root_translation = true;
    }
    assert(root_translation);

    RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
    options.copy_translations = true;
    options.root_motion = RootMotion.STRIP_XZ;
    ClipId[] full = fbx::load_animations(mem, &assets, path, model, options)!!;
    defer alloc::free(mem, full.ptr);
    assert(full.len == 1 && assets.clip(full[0]).data.tracks.len == 177);

    Scene scene = scene::create_scene(mem, { .max_nodes = 128 });
    defer scene::destroy_scene(&scene);
    Node* root = model::instantiate(&assets, &scene, model)!!;
    Animator* animator = anim::add_animator(&scene, root);
    animator.play(&assets, clips[0])!!;
}

fn void test_load_animations_rolls_back_on_key_collision() @test {
    AssetStore assets = asset::create_asset_store(mem, {
        .max_geometries = 8,
        .max_textures   = asset::BUILTIN_TEXTURE_COUNT + 8,
        .max_materials  = 8,
        .max_samplers   = asset::BUILTIN_SAMPLER_COUNT + 2,
        .max_models     = 2,
        .max_skeletons  = 2,
        .max_clips      = 4,
    });
    defer asset::destroy_asset_store(&assets);
    String path = fixture_path("maya_kenney_character_7700_binary.fbx");
    ModelId model = fbx::load_model(&assets, path)!!;
    ClipId[] clips = fbx::load_animations(mem, &assets, path, model)!!;
    defer alloc::free(mem, clips.ptr);
    sz keys_before = assets.keys.len();
    if (catch excuse = fbx::load_animations(mem, &assets, path, model)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "expected a fault");
    }
    assert(assets.keys.len() == keys_before);
}
