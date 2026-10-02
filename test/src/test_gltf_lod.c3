module c3d::test::gltf_lod;

import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::model;
import c3d::scene;
import std::io::path;
import std::math;

const String DOCUMENT @local = $embed("../fixtures/gltf/lod.gltf");
const String ANIMATED_DOCUMENT @local = $embed("../fixtures/gltf/lod_animated.gltf");

fn void test_msft_lod_imports_unequal_levels_and_local_matrices() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    ModelId model = load(&assets, DOCUMENT)!!;
    ModelTemplate* template = &assets.model(model).data;
    assert(template.lod_groups.len == 1 && template.meshes.len == 0);
    LodDesc desc = template.lod_groups[0].desc;
    assert(desc.levels.len == 3 && desc.parts.len == 6);
    assert(desc.levels[0].part_count == 2 && desc.levels[1].part_count == 1 && desc.levels[2].part_count == 3);
    assert(desc.levels[0].min_screen_size == 0.5f && desc.levels[1].min_screen_size == 0.2f);
    assert(desc.levels[2].min_screen_size == 0);
    float[6] positions = { -2, 2, 1, 1, 2, 3 };
    foreach (index, part : desc.parts) {
        assert(part.local.m03 == positions[index]);
        assert(assets.geometries.is_live(part.geometry) && assets.materials.is_live(part.material));
    }
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    model::instantiate(assets: &assets, scene: &scene, model: model)!!;
    assert(scene.count(LodGroup) == 1 && scene.count(Mesh) == 0 && scene.count(Camera) == 1);
}

fn void test_msft_lod_rejects_malformed_metadata() @test {
    String[2][10] replacements = {
        { `"ids":[1,2]`, `"ids":[1,1]` },
        { `"ids":[1,2]`, `"ids":[0,2]` },
        { `"ids":[1,2]`, `"ids":[1,99]` },
        { `"ids":[1,2]`, `"ids":["1",2]` },
        { `"MSFT_screencoverage":[0.5,0.2,0.01]`, `"MSFT_screencoverage":[0.2,0.5,0.01]` },
        { `"MSFT_screencoverage":[0.5,0.2,0.01]`, `"MSFT_screencoverage":[0.5,0.5,0.01]` },
        { `"MSFT_screencoverage":[0.5,0.2,0.01]`, `"MSFT_screencoverage":[0.5,0.2]` },
        { `"MSFT_screencoverage":[0.5,0.2,0.01]`, `"MSFT_screencoverage":["0.5",0.2,0.01]` },
        { `"MSFT_screencoverage":[0.5,0.2,0.01]`, `"MSFT_screencoverage":[1e999,0.2,0.01]` },
        { `"name":"middle"`, `"extensions":{"MSFT_lod":{"ids":[0]}},"name":"middle"` },
    };
    foreach (pair : replacements) {
        AssetStore assets = create_store(mem);
        defer asset::destroy_asset_store(&assets);
        @pool() {
            assert(@catch(load(&assets, DOCUMENT.treplace(pair[0], pair[1]))) == c3d::ASSET_FORMAT_ERROR);
        };
        assert(assets.models.free_count == 2 && assets.geometries.free_count == 4);
    }
}

fn void test_msft_lod_defaults_and_required_material_rejection() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    @pool() {
        String no_hint = DOCUMENT.treplace(`"extras":{"MSFT_screencoverage":[0.5,0.2,0.01]}`, `"extras":{}`);
        ModelId model = load(&assets, no_hint)!!;
        LodDesc desc = assets.model(model).data.lod_groups[0].desc;
        assert(desc.levels[0].min_screen_size == 0.2f && desc.levels[1].min_screen_size == 0.1f);
    };
    AssetStore second = create_store(mem);
    defer asset::destroy_asset_store(&second);
    @pool() {
        String required = DOCUMENT.treplace(`"extensionsUsed":["MSFT_lod"]`, `"extensionsRequired":["MSFT_lod"]`);
        required = required.treplace(`"pbrMetallicRoughness":`, `"extensions":{"MSFT_lod":{"ids":[1]}},"pbrMetallicRoughness":`);
        assert(@catch(load(&second, required)) == c3d::UNSUPPORTED);
    };
}

fn void test_model_lod_instances_keep_independent_descriptors() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        AssetStore assets = create_store(&tracker);
        defer asset::destroy_asset_store(&assets);
        ModelDocument document = gltf::decode_model_memory(
            allocator: &tracker,
            bytes: (char[])DOCUMENT,
            base_dir: "",
            key: "lod",
        )!!;
        defer asset::destroy_model_document(&document);
        assert(document.template.lod_groups[0].desc.parts[0].geometry.generation == 0);
        ModelId model = assets.publish_document(&document)!!;
        Scene scene = scene::create_scene(&tracker, { .max_nodes = 32 });
        defer scene::destroy_scene(&scene);
        Node* first = model::instantiate(assets: &assets, scene: &scene, model: model)!!;
        Node* second = model::instantiate(assets: &assets, scene: &scene, model: model)!!;
        ModelInstance* first_instance = scene.get(first, ModelInstance);
        ModelInstance* second_instance = scene.get(second, ModelInstance);
        LodGroupState* first_state = scene.get(first_instance.nodes[0], LodGroup).state;
        LodGroupState* second_state = scene.get(second_instance.nodes[0], LodGroup).state;
        assert(first_state.desc.parts.ptr != second_state.desc.parts.ptr);
        assets.remove_model(model);
        assert(assets.geometries.is_live(first_state.desc.parts[0].geometry));
        scene.remove(first);
        assert(second_state.desc.parts.len == 6 && second_state.desc.levels[0].part_count == 2);
    }
    assert(!tracker.has_leaks());
}

fn void test_msft_lod_preserves_owner_animation_and_falls_back_for_deformation() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    ModelId owner = load(&assets, ANIMATED_DOCUMENT)!!;
    assert(assets.model(owner).data.lod_groups.len == 1);
    assert(assets.model(owner).data.clips.len == 1);
    assert(assets.clip(assets.model(owner).data.clips[0]).data.targets[0] == 0);
    String[3] variants;
    @pool() {
        variants[0] = ANIMATED_DOCUMENT.treplace(`"target":{"node":0`, `"target":{"node":3`);
        variants[1] = ANIMATED_DOCUMENT.treplace(`"target":{"node":0`, `"target":{"node":1`);
        variants[2] = DOCUMENT.treplace(`"attributes":{"POSITION":0}`, `"attributes":{"POSITION":0},"targets":[{"POSITION":0}]`);
        foreach (source : variants) {
            AssetStore optional = create_store(mem);
            defer asset::destroy_asset_store(&optional);
            ModelId model = load(&optional, source)!!;
            assert(optional.model(model).data.lod_groups.len == 0 && optional.model(model).data.meshes.len == 2);
            AssetStore required = create_store(mem);
            defer asset::destroy_asset_store(&required);
            String strict = source.treplace(`"extensionsUsed":["MSFT_lod"]`, `"extensionsRequired":["MSFT_lod"]`);
            assert(@catch(load(&required, strict)) == c3d::UNSUPPORTED);
        }
    };
}

fn AssetStore create_store(Allocator allocator) @local {
    return asset::create_asset_store(allocator, {
        .max_geometries = 4,
        .max_textures = asset::BUILTIN_TEXTURE_COUNT,
        .max_materials = 4,
        .max_samplers = asset::BUILTIN_SAMPLER_COUNT,
        .max_models = 2,
        .max_clips = 2,
        .max_shaders = 1,
    });
}

fn void test_lod_document_rejects_unusable_parts_before_publication() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    ModelDocument document = gltf::decode_model_memory(
        allocator: mem,
        bytes: (char[])DOCUMENT,
        base_dir: "",
        key: "lod",
    )!!;
    defer asset::destroy_model_document(&document);
    LodPart* part = &document.template.lod_groups[0].desc.parts[0];
    Mat4 local = part.local;
    part.local.m03 = float::max;
    part.local.m00 = float::max;
    usz geometries = assets.geometries.free_count;
    assert(@catch(assets.publish_document(&document)) == c3d::INVALID_ARGUMENT);
    assert(assets.geometries.free_count == geometries && document.template.lod_groups.len == 1);
    part.local = local;
    char[1] bytes = { 1 };
    ShaderDesc shader_desc = { .fragment = bytes[..], .vertex = { .shaded = bytes[..], .depth = bytes[..] } };
    ShaderId shader = assets.add_shader(&shader_desc)!!;
    MaterialId material = assets.add_material(material::custom(shader, {}))!!;
    part.material = material;
    assert(@catch(assets.publish_document(&document)) == c3d::INVALID_ARGUMENT);
    assert(assets.geometries.free_count == geometries && document.template.lod_groups.len == 1);
    document.template.lod_groups[0].desc.has_bounds_override = true;
    document.template.lod_groups[0].desc.local_bounds = { .min = { -10, -10, -10 }, .max = { 10, 10, 10 } };
    assets.publish_document(&document)!!;
    assert(document.template.lod_groups.len == 0);
}

fn ModelId? load(AssetStore* assets, String document) @local {
    return gltf::load_model_memory(
        assets: assets,
        bytes: (char[])document,
        base_dir: "",
        key: "lod",
    );
}
