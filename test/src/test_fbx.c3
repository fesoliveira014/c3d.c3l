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

struct ProfileFbxSource @local {
    String text;
    uint reads;
}

struct ProfileFbxFixture @local {
    AssetStore assets;
    ModelDocument source_document;
    ProfileFbxSource source;
    String path;
    ModelId target;
    RetargetProfileDesc desc;
    RetargetProfile profile;
}

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

fn char[]? read_profile_fbx_source(void* user, Allocator allocator, String path) @local {
    ProfileFbxSource* source = user;
    source.reads++;
    char[] copy = alloc::new_array_try(allocator, char, source.text.len) ?? c3d::ASSET_IO_ERROR~!;
    copy[..] = source.text[..];
    return copy;
}

fn void create_profile_fbx_fixture(
    Allocator allocator,
    ProfileFbxFixture* fixture,
    uint clip_capacity = 8,
) @local {
    Path directory = path::tnew($$FILEPATH)!!.parent()!!;
    fixture.path = (String)directory.tappend("../fixtures/animation_contact/profile_animation_v1.fbx")!!;
    FileSource disk;
    fixture.source.text = (String)disk.read_path(tmem, fixture.path)!!;
    FileSource provider = { .read = &read_profile_fbx_source, .user = &fixture.source };
    fixture.source_document = fbx::decode_model(
        allocator: allocator,
        path: fixture.path,
        options: { .animations = false },
        file_source: provider,
    )!!;
    NodeTemplate[] source = fixture.source_document.template.nodes;
    assert(source.len == 3 && fixture.source_document.template.meshes.len == 0);
    assert(source[0].name == "Carrier" && source[0].parent == -1);
    assert(source[1].name == "Hip" && source[1].parent == 0);
    assert(source[2].name == "Foot" && source[2].parent == 1);
    assert(close_vec3(source[0].local.position, {}));
    assert(close_vec3(source[1].local.position, { 0, 1, 0 }));
    assert(close_vec3(source[2].local.position, { 0, -1, 0 }));
    fixture.assets = asset::create_asset_store(allocator, {
        .max_geometries = 1,
        .max_textures = asset::BUILTIN_TEXTURE_COUNT,
        .max_materials = 1,
        .max_samplers = asset::BUILTIN_SAMPLER_COUNT,
        .max_models = 1,
        .max_clips = clip_capacity,
        .file_source = provider,
    });
    ModelTemplate target = { .nodes = alloc::new_array(allocator, NodeTemplate, source.len) };
    target.nodes[..] = source[..];
    foreach (&node : target.nodes) node.name = node.name.copy(allocator);
    fixture.target = fixture.assets.add_model_owned(&target, "profile_target")!!;
    fixture.desc = retarget::RETARGET_PROFILE_DESC_DEFAULT;
    fixture.desc.mapping_mode = ProfileMappingMode.BY_INDEX;
    fixture.desc.index_map = alloc::new_array(tmem, NodeIndexMapping, 2);
    fixture.desc.index_map[..] = (NodeIndexMapping[2]){
        { .source_node = 1, .target_node = 1 },
        { .source_node = 2, .target_node = 2 },
    }[..];
    fixture.desc.source_calibration = alloc::new_array(tmem, Quat, source.len);
    fixture.desc.target_calibration = alloc::new_array(tmem, Quat, target.nodes.len);
    foreach (index, &node : source) fixture.desc.source_calibration[index] = node.local.rotation;
    foreach (index, &node : target.nodes) fixture.desc.target_calibration[index] = node.local.rotation;
    fixture.desc.source_motion_node = 1;
    fixture.desc.target_motion_node = 1;
    fixture.desc.target_carrier = 0;
    fixture.profile = retarget::create_retarget_profile(
        allocator: allocator,
        source_nodes: source,
        target: &fixture.assets.model(fixture.target).data,
        desc: fixture.desc,
    )!!;
}

fn void destroy_profile_fbx_fixture(ProfileFbxFixture* fixture) @local {
    retarget::destroy_retarget_profile(&fixture.profile);
    asset::destroy_model_document(&fixture.source_document);
    asset::destroy_asset_store(&fixture.assets);
    *fixture = {};
}

fn String clean_profile_fbx(String text) @local {
    assert(text.contains("a: 1,2"));
    return text.treplace("a: 1,2", "a: 1,1");
}

fn String empty_profile_fbx(String text) @local {
    sz start = text.index_of("    AnimationStack: 200")!!;
    return string::tformat(
        "%s}\nConnections: {\n    C: \"OO\", 100,0\n    C: \"OO\", 101,100\n"
        "    C: \"OO\", 102,101\n}\n",
        text[:start],
    );
}

fn ClipId[] load_profile_fbx(ProfileFbxFixture* fixture, String variant, RetargetProfile* profile = null) @local {
    RetargetProfile* prepared = profile ?: &fixture.profile;
    return fbx::load_animations_with_profile(
        allocator: mem,
        assets: &fixture.assets,
        path: fixture.path,
        target: fixture.target,
        profile: prepared,
        variant: variant,
    )!!;
}

fn Vec3 profiled_fbx_position(
    AnimationClip* clip,
    ModelTemplate* target,
    uint node,
    float time,
) @local {
    Vec3 position = target.nodes[node].local.position;
    foreach (&track : clip.tracks) {
        if (clip.targets[track.target] != node || track.path != TargetPath.TRANSLATION) continue;
        float[3] values;
        uint cursor;
        anim::sample_track(
            track: track,
            time: time,
            cursor: &cursor,
            out: values[..],
        );
        position = { values[0], values[1], values[2] };
    }
    return position;
}

fn Quat profiled_fbx_rotation(AnimationClip* clip, uint node, float time) @local {
    foreach (&track : clip.tracks) {
        if (clip.targets[track.target] != node || track.path != TargetPath.ROTATION) continue;
        float[4] values;
        uint cursor;
        anim::sample_track(
            track: track,
            time: time,
            cursor: &cursor,
            out: values[..],
        );
        return { .v = { values[0], values[1], values[2], values[3] } };
    }
    return maths::TRANSFORM_IDENTITY.rotation;
}

fn void test_profiled_fbx_variants_have_distinct_keys_and_owned_clips() @test {
    @pool() {
        ProfileFbxFixture fixture;
        create_profile_fbx_fixture(mem, &fixture);
        defer destroy_profile_fbx_fixture(&fixture);
        fixture.source.text = clean_profile_fbx(fixture.source.text);
        fixture.desc.target_calibration[1] = quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 4);
        RetargetProfile alternate = retarget::create_retarget_profile(
            allocator: mem,
            source_nodes: fixture.source_document.template.nodes,
            target: &fixture.assets.model(fixture.target).data,
            desc: fixture.desc,
        )!!;
        defer retarget::destroy_retarget_profile(&alternate);
        ClipId[] first = load_profile_fbx(&fixture, "t_pose");
        defer alloc::free(mem, first.ptr);
        ClipId[] second = load_profile_fbx(&fixture, "a_pose:#profile/7:value", &alternate);
        defer alloc::free(mem, second.ptr);
        assert(first.len == 2 && second.len == 2);
        assert(!c3d::same_id(first[0], second[0]) && !c3d::same_id(first[1], second[1]));
        String first_key = string::tformat("%s#anim/0#profile_target#keep#profile/6:t_pose", fixture.path);
        String alternate_key = string::tformat(
            "%s#anim/0#profile_target#keep#profile/%d:%s",
            fixture.path,
            "a_pose:#profile/7:value".len,
            "a_pose:#profile/7:value",
        );
        assert(c3d::same_id(fixture.assets.find_clip(first_key)!!, first[0]));
        assert(c3d::same_id(fixture.assets.find_clip(alternate_key)!!, second[0]));
        ModelTemplate* target = &fixture.assets.model(fixture.target).data;
        AnimationClip* translated = &fixture.assets.clip(first[0]).data;
        assert(translated.name == "Translate" && close(translated.duration, 1));
        assert(close_vec3(profiled_fbx_position(
            clip: translated,
            target: target,
            node: 1,
            time: 0.5f,
        ), { 0.5f, 1, 0 }));
        assert(close_vec3(profiled_fbx_position(
            clip: translated,
            target: target,
            node: 1,
            time: 1,
        ), { 1, 1, 0 }));
        Quat primary = profiled_fbx_rotation(translated, 1, 0);
        Quat calibrated = profiled_fbx_rotation(&fixture.assets.clip(second[0]).data, 1, 0);
        assert(math::abs(primary.v.w) > 0.99999f);
        assert(close(calibrated.v.z, math::sin((float)math::PI / 8)));
        assert(close(calibrated.v.w, math::cos((float)math::PI / 8)));
        retarget::destroy_retarget_profile(&fixture.profile);
        retarget::destroy_retarget_profile(&alternate);
        assert(close_vec3(profiled_fbx_position(
            clip: translated,
            target: target,
            node: 1,
            time: 1,
        ), { 1, 1, 0 }));
        assert(fixture.assets.clip(second[0]).data.name == "Translate");
        ClipId[] legacy = fbx::load_animations(mem, &fixture.assets, fixture.path, fixture.target)!!;
        defer alloc::free(mem, legacy.ptr);
        String legacy_key = string::tformat("%s#anim/0#profile_target#keep", fixture.path);
        assert(c3d::same_id(fixture.assets.find_clip(legacy_key)!!, legacy[0]));
        assert(!c3d::same_id(legacy[0], first[0]) && !c3d::same_id(legacy[0], second[0]));
    };
}

fn void test_profiled_fbx_repeated_and_empty_variant_preserve_the_store() @test {
    @pool() {
        ProfileFbxFixture fixture;
        create_profile_fbx_fixture(mem, &fixture);
        defer destroy_profile_fbx_fixture(&fixture);
        fixture.source.text = clean_profile_fbx(fixture.source.text);
        ClipId[] published = load_profile_fbx(&fixture, "stable");
        defer alloc::free(mem, published.ptr);
        sz keys = fixture.assets.keys.len();
        uint free_clips = fixture.assets.clips.free_count;
        foreach (variant : (String[2]){ "stable", "" }) {
            bool failed;
            RetargetDiagnostic diagnostic = { .reason = RetargetReason.INVALID_CLIP };
            if (catch excuse = fbx::load_animations_with_profile(
                allocator: mem,
                assets: &fixture.assets,
                path: fixture.path,
                target: fixture.target,
                profile: &fixture.profile,
                variant: variant,
                diagnostic: &diagnostic,
            )) {
                failed = true;
                assert(excuse == c3d::INVALID_ARGUMENT);
            }
            assert(failed && diagnostic.reason == RetargetReason.NONE);
            assert(fixture.assets.keys.len() == keys && fixture.assets.clips.free_count == free_clips);
            foreach (id : published) assert(fixture.assets.clips.is_live(id));
        }
    };
}

fn void test_profiled_fbx_checks_actual_source_and_current_target_templates() @test {
    @pool() {
        ProfileFbxFixture fixture;
        create_profile_fbx_fixture(mem, &fixture);
        defer destroy_profile_fbx_fixture(&fixture);
        String original = fixture.source.text;
        fixture.source.text = clean_profile_fbx(original).treplace("Model::Hip", "Model::RenamedHip");
        sz keys = fixture.assets.keys.len();
        bool failed;
        RetargetDiagnostic diagnostic;
        if (catch excuse = fbx::load_animations_with_profile(
            allocator: mem,
            assets: &fixture.assets,
            path: fixture.path,
            target: fixture.target,
            profile: &fixture.profile,
            variant: "renamed_source",
            diagnostic: &diagnostic,
        )) {
            failed = true;
            assert(excuse == c3d::INVALID_ARGUMENT);
        }
        assert(failed && diagnostic.reason == RetargetReason.TEMPLATE_LAYOUT_MISMATCH);
        assert(diagnostic.source_node == 1 && fixture.assets.keys.len() == keys);
        fixture.source.text = clean_profile_fbx(original);
        ModelTemplate* target = &fixture.assets.model(fixture.target).data;
        target.nodes[1].local.position.y += 0.25f;
        failed = false;
        if (catch excuse = fbx::load_animations_with_profile(
            allocator: mem,
            assets: &fixture.assets,
            path: fixture.path,
            target: fixture.target,
            profile: &fixture.profile,
            variant: "changed_target",
            diagnostic: &diagnostic,
        )) {
            failed = true;
            assert(excuse == c3d::INVALID_ARGUMENT);
        }
        assert(failed && diagnostic.reason == RetargetReason.TEMPLATE_REFERENCE_MISMATCH);
        assert(diagnostic.target_node == 1 && fixture.assets.keys.len() == keys);
        assert(target.nodes[1].local.position.y == 1.25f);
    };
}

fn void test_profiled_fbx_later_stack_failure_removes_every_new_clip() @test {
    @pool() {
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        ProfileFbxFixture fixture;
        create_profile_fbx_fixture(&tracker, &fixture);
        defer destroy_profile_fbx_fixture(&fixture);
        sz keys = fixture.assets.keys.len();
        uint free_clips = fixture.assets.clips.free_count;
        sz bytes = tracker.allocated();
        bool failed;
        RetargetDiagnostic diagnostic;
        if (catch excuse = fbx::load_animations_with_profile(
            allocator: mem,
            assets: &fixture.assets,
            path: fixture.path,
            target: fixture.target,
            profile: &fixture.profile,
            variant: "unsupported_scale",
            diagnostic: &diagnostic,
        )) {
            failed = true;
            assert(excuse == c3d::UNSUPPORTED);
        }
        assert(failed && diagnostic.reason == RetargetReason.UNSUPPORTED_ANIMATED_TRANSFORM);
        assert(diagnostic.source_node == 1);
        assert(fixture.assets.keys.len() == keys && fixture.assets.clips.free_count == free_clips);
        assert(tracker.allocated() == bytes);
        String key = string::tformat(
            "%s#anim/0#profile_target#keep#profile/17:unsupported_scale",
            fixture.path,
        );
        assert(@catch(fixture.assets.find_clip(key)) == NOT_FOUND);
    };
}

fn void test_profiled_fbx_capacity_failure_after_one_stack_rolls_back() @test {
    @pool() {
        ProfileFbxFixture fixture;
        create_profile_fbx_fixture(mem, &fixture, 1);
        defer destroy_profile_fbx_fixture(&fixture);
        fixture.source.text = clean_profile_fbx(fixture.source.text);
        sz keys = fixture.assets.keys.len();
        bool failed;
        if (catch excuse = fbx::load_animations_with_profile(
            allocator: mem,
            assets: &fixture.assets,
            path: fixture.path,
            target: fixture.target,
            profile: &fixture.profile,
            variant: "capacity",
        )) {
            failed = true;
            assert(excuse == c3d::CAPACITY_EXCEEDED);
        }
        assert(failed && fixture.assets.keys.len() == keys && fixture.assets.clips.free_count == 1);
    };
}

fn void test_profiled_fbx_empty_stacks_still_validate_the_actual_template() @test {
    @pool() {
        ProfileFbxFixture fixture;
        create_profile_fbx_fixture(mem, &fixture);
        defer destroy_profile_fbx_fixture(&fixture);
        fixture.source.text = empty_profile_fbx(fixture.source.text);
        ClipId[] empty = load_profile_fbx(&fixture, "empty");
        defer alloc::free(mem, empty.ptr);
        assert(empty.len == 0);
        sz keys = fixture.assets.keys.len();
        fixture.source.text = fixture.source.text.treplace("Model::Hip", "Model::RenamedHip");
        bool failed;
        RetargetDiagnostic diagnostic;
        if (catch excuse = fbx::load_animations_with_profile(
            allocator: mem,
            assets: &fixture.assets,
            path: fixture.path,
            target: fixture.target,
            profile: &fixture.profile,
            variant: "empty_mismatch",
            diagnostic: &diagnostic,
        )) {
            failed = true;
            assert(excuse == c3d::INVALID_ARGUMENT);
        }
        assert(failed && diagnostic.reason == RetargetReason.TEMPLATE_LAYOUT_MISMATCH);
        assert(diagnostic.source_node == 1 && fixture.assets.keys.len() == keys);
    };
}
