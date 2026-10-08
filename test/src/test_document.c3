module c3d::test::document;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::fbx;
import c3d::asset::gltf;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import std::io::path;
import std::math;
import std::sort;

const uint PAIR_BASE @local = 1000; // texture index times the base plus sampler index; indices stay below it
const usz MAX_VISITS @local = 16; // more than the fifteen slots of a physical material

struct DocumentRefs @local {
    SamplerId     sampler;
    TextureId[2]  textures;
    MaterialId    material;
    GeometryId    geometry;
    SkeletonId    skeleton;
    ClipId        clip;
}

struct PoolCounts @local {
    uint samplers;
    uint textures;
    uint materials;
    uint geometries;
    uint skeletons;
    uint clips;
    uint models;
    sz   keys;
}

fn String fixture_path(String directory, String name) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend("../fixtures", directory)!!.tappend(name)!!;
}

fn AssetStore create_store(Allocator allocator, uint max_geometries = 1, uint max_models = 1) @local {
    return asset::create_asset_store(allocator, {
        .max_geometries = max_geometries,
        .max_textures   = asset::BUILTIN_TEXTURE_COUNT + 2,
        .max_materials  = 1,
        .max_samplers   = asset::BUILTIN_SAMPLER_COUNT + 1,
        .max_skeletons  = 1,
        .max_clips      = 1,
        .max_models     = max_models,
    });
}

fn Geometry triangle(Allocator allocator) @local {
    Vec3[] positions = alloc::new_array(allocator, Vec3, 3);
    positions[0] = { 0, 0, 0 };
    positions[1] = { 1, 0, 0 };
    positions[2] = { 0, 1, 0 };
    uint[] indices = alloc::new_array(allocator, uint, 3);
    indices[0] = 0;
    indices[1] = 1;
    indices[2] = 2;
    Geometry geometry = { .topology = Topology.TRIANGLES, .positions = positions, .indices = indices };
    geometry.finalize();
    return geometry;
}

fn char[] numbered_pixels(Allocator allocator, char first) @local {
    char[] pixels = alloc::new_array(allocator, char, 16);
    foreach (index, &pixel : pixels) *pixel = first + (char)index;
    return pixels;
}

fn ModelDocument build_document(Allocator allocator, DocumentRefs* refs) @local {
    ModelDocument document = asset::create_model_document(allocator, "doc", {
        .samplers   = 1,
        .textures   = 2,
        .materials  = 1,
        .geometries = 1,
        .skeletons  = 1,
        .clips      = 1,
    });

    SamplerDesc sampler = material::sampler_desc(Filter.NEAREST, AddressMode.CLAMP_TO_EDGE, "doc_sampler");
    refs.sampler = document.push_sampler(sampler, "doc#sampler");
    TextureDesc desc = material::texture_2d_desc(2, 2, RGBA8_UNORM);
    refs.textures[0] = document.push_texture(desc, numbered_pixels(allocator, 0), "doc#tex/0");
    refs.textures[1] = document.push_texture(desc, numbered_pixels(allocator, 100), "doc#tex/1");

    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color_map = material::texture_slot(texture: refs.textures[0], sampler: refs.sampler);
    params.normal_map = material::texture_slot(texture: refs.textures[1], sampler: asset::SAMPLER_LINEAR_CLAMP);
    refs.material = document.push_material(material::standard(params), "doc#material");

    Geometry geometry = triangle(allocator);
    refs.geometry = document.push_geometry(&geometry, "doc#mesh");

    Skeleton skeleton = {
        .joint_names  = alloc::new_array(allocator, String, 1),
        .parents      = alloc::new_array(allocator, int, 1),
        .rest_pose    = alloc::new_array(allocator, Transform, 1),
        .inverse_bind = alloc::new_array(allocator, Mat4, 1),
    };
    skeleton.joint_names[0] = "root".copy(allocator);
    skeleton.parents[0] = -1;
    skeleton.rest_pose[0] = maths::TRANSFORM_IDENTITY;
    skeleton.inverse_bind[0] = matrix::IDENTITY4;
    refs.skeleton = document.push_skeleton(&skeleton, "doc#skeleton");

    AnimationClip clip = { .name = "take".copy(allocator) };
    refs.clip = document.push_clip(&clip, "doc#clip");

    ModelTemplate* template = &document.template;
    template.nodes = alloc::new_array(allocator, NodeTemplate, 2);
    template.nodes[0] = { .parent = -1, .name = "root".copy(allocator) };
    template.nodes[1] = { .parent = 0, .name = "root/primitive/0".copy(allocator) };
    template.meshes = alloc::new_array(allocator, ModelMesh, 1);
    template.meshes[0] = { .node = 1, .geometry = refs.geometry, .material = refs.material };
    uint[] joint_nodes = alloc::new_array(allocator, uint, 1);
    template.skins = alloc::new_array(allocator, ModelSkin, 1);
    template.skins[0] = { .mesh_node = 1, .skeleton = refs.skeleton, .joint_nodes = joint_nodes };
    template.clips = alloc::new_array(allocator, ClipId, 1);
    template.clips[0] = refs.clip;
    return document;
}

fn PoolCounts pool_counts(AssetStore* assets) @local {
    return {
        .samplers   = assets.samplers.free_count,
        .textures   = assets.textures.free_count,
        .materials  = assets.materials.free_count,
        .geometries = assets.geometries.free_count,
        .skeletons  = assets.skeletons.free_count,
        .clips      = assets.clips.free_count,
        .models     = assets.models.free_count,
        .keys       = assets.keys.len(),
    };
}

fn bool same_counts(PoolCounts first, PoolCounts second) @local {
    return first.samplers == second.samplers && first.textures == second.textures
        && first.materials == second.materials && first.geometries == second.geometries
        && first.skeletons == second.skeletons && first.clips == second.clips
        && first.models == second.models && first.keys == second.keys;
}

fn void assert_publish_faults(AssetStore* assets, ModelDocument* document, fault expected) @local {
    PoolCounts before = pool_counts(assets);
    assert(@catch(assets.publish_document(document)) == expected);
    assert(same_counts(pool_counts(assets), before));
}

fn void assert_document_intact(ModelDocument* document, DocumentRefs* refs) @local {
    assert(document.key == "doc");
    assert(document.textures.len == 2);
    foreach (index, pixel : document.textures[0].pixels) assert(pixel == (char)index);
    TextureRef base_color = document.materials[0].data.standard.base_color_map.texture;
    assert(c3d::same_id(base_color.asset, refs.textures[0]));
    assert(c3d::same_id(document.template.meshes[0].geometry, refs.geometry));
}

fn void assert_same_stores(
    AssetStore* loaded,
    ModelId loaded_model,
    AssetStore* published,
    ModelId published_model,
) @local {
    assert(loaded.keys.len() == published.keys.len());
    @pool() {
        foreach (key : loaded.keys.tkeys()) {
            AssetRef expected = loaded.keys.get(key)!!;
            AssetRef actual = published.keys.get(key)!!;
            assert(expected.kind == actual.kind && expected.slot == actual.slot);
            assert(expected.id.index == actual.id.index && expected.id.generation == actual.id.generation);
        }
    };

    ModelTemplate* first = &loaded.model(loaded_model).data;
    ModelTemplate* second = &published.model(published_model).data;
    assert(first.nodes.len == second.nodes.len);
    foreach (index, &node : first.nodes) {
        assert(node.name == second.nodes[index].name && node.parent == second.nodes[index].parent);
    }
    assert(first.meshes.len == second.meshes.len);
    foreach (index, &mesh : first.meshes) {
        assert(c3d::same_id(mesh.geometry, second.meshes[index].geometry));
        assert(c3d::same_id(mesh.material, second.meshes[index].material));
    }
    assert(first.skins.len == second.skins.len);
    foreach (index, &skin : first.skins) assert(c3d::same_id(skin.skeleton, second.skins[index].skeleton));
    assert(first.clips.len == second.clips.len);
    foreach (index, clip : first.clips) assert(c3d::same_id(clip, second.clips[index]));
}

fn TextureSlot numbered_slot(uint number) @local {
    return material::texture_slot(
        texture: { .index = number, .generation = 1 },
        sampler: { .index = 100 + number, .generation = 1 },
    );
}

fn uint[] visited_pairs(Material* visited) @local {
    uint[] pairs = alloc::new_array(tmem, uint, MAX_VISITS);
    usz count;
    material::@each_texture_reference(visited; TextureId* texture, SamplerId* sampler) {
        pairs[count++] = texture.index * PAIR_BASE + (sampler ? sampler.index : 0);
    };
    pairs = pairs[:count];
    sort::quicksort(pairs);
    return pairs;
}

fn uint[] numbered_pairs(uint first, uint last) @local {
    uint[] pairs = alloc::new_array(tmem, uint, (sz)(last - first + 1));
    for (uint number = first; number <= last; number++) {
        pairs[number - first] = number * PAIR_BASE + 100 + number;
    }
    return pairs;
}

fn bool same_pairs(uint[] first, uint[] second) @local {
    if (first.len != second.len) return false;
    foreach (index, pair : first) if (pair != second[index]) return false;
    return true;
}

fn Material numbered_physical() @local {
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.standard.base_color_map = numbered_slot(1);
    params.standard.metallic_roughness_map = numbered_slot(2);
    params.standard.normal_map = numbered_slot(3);
    params.standard.occlusion_map = numbered_slot(4);
    params.standard.emissive_map = numbered_slot(5);
    params.clearcoat_map = numbered_slot(6);
    params.clearcoat_roughness_map = numbered_slot(7);
    params.clearcoat_normal_map = numbered_slot(8);
    params.sheen_color_map = numbered_slot(9);
    params.sheen_roughness_map = numbered_slot(10);
    params.specular_map = numbered_slot(11);
    params.specular_color_map = numbered_slot(12);
    params.anisotropy_map = numbered_slot(13);
    params.transmission_map = numbered_slot(14);
    params.thickness_map = numbered_slot(15);
    return { .kind = MaterialKind.PHYSICAL, .common = material::MATERIAL_COMMON_DEFAULT, .physical = params };
}

fn Material numbered_standard() @local {
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color_map = numbered_slot(1);
    params.metallic_roughness_map = numbered_slot(2);
    params.normal_map = numbered_slot(3);
    params.occlusion_map = numbered_slot(4);
    params.emissive_map = numbered_slot(5);
    return material::standard(params);
}

fn void test_publish_document_remaps_every_reference() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    DocumentRefs refs;
    ModelDocument document = build_document(mem, &refs);
    defer asset::destroy_model_document(&document);

    ModelId published = assets.publish_document(&document)!!;
    ModelId model = assets.find_model("doc")!!;
    assert(c3d::same_id(published, model));
    ModelTemplate* template = &assets.model(model).data;
    assert(c3d::same_id(template.meshes[0].geometry, assets.find_geometry("doc#mesh")!!));
    assert(c3d::same_id(template.meshes[0].material, assets.find_material("doc#material")!!));
    assert(c3d::same_id(template.skins[0].skeleton, assets.find_skeleton("doc#skeleton")!!));
    assert(c3d::same_id(template.clips[0], assets.find_clip("doc#clip")!!));

    StandardParams* params = &assets.material(template.meshes[0].material).data.standard;
    assert(c3d::same_id(params.base_color_map.texture.asset, assets.find_texture("doc#tex/0")!!));
    assert(c3d::same_id(params.base_color_map.sampler, assets.find_sampler("doc#sampler")!!));
    assert(c3d::same_id(params.metallic_roughness_map.texture.asset, (TextureId){}));
    assert(c3d::same_id(params.metallic_roughness_map.sampler, (SamplerId){}));
    assert(c3d::same_id(params.normal_map.texture.asset, assets.find_texture("doc#tex/1")!!));
    assert(c3d::same_id(params.normal_map.sampler, asset::SAMPLER_LINEAR_CLAMP));
    char[] pixels = assets.texture(params.base_color_map.texture.asset).pixels;
    assert(pixels.len == 16);
    foreach (index, pixel : pixels) assert(pixel == (char)index);

    assert(!document.samplers.len && !document.textures.len && !document.materials.len);
    assert(!document.geometries.len && !document.skeletons.len && !document.clips.len);
    assert(!document.template.nodes.len && !document.key.len && document.allocator == mem);
}

fn void test_publish_document_faults_on_a_duplicate_key_before_inserting() @test {
    AssetStore assets = create_store(mem, max_geometries: 2);
    defer asset::destroy_asset_store(&assets);
    Geometry occupant = triangle(tmem);
    assets.add_geometry(&occupant, "doc#mesh")!!;
    DocumentRefs refs;
    ModelDocument document = build_document(mem, &refs);
    defer asset::destroy_model_document(&document);

    assert_publish_faults(&assets, &document, c3d::INVALID_ARGUMENT);
    assert_document_intact(&document, &refs);
}

fn void test_publish_rejects_unset_template_references() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    DocumentRefs refs;
    ModelDocument document = build_document(mem, &refs);
    defer asset::destroy_model_document(&document);
    ModelTemplate* template = &document.template;

    template.meshes[0].geometry = {};
    assert_publish_faults(&assets, &document, c3d::INVALID_ARGUMENT);
    template.meshes[0].geometry = refs.geometry;

    template.meshes[0].material = {};
    assert_publish_faults(&assets, &document, c3d::INVALID_ARGUMENT);
    template.meshes[0].material = refs.material;

    template.skins[0].skeleton = {};
    assert_publish_faults(&assets, &document, c3d::INVALID_ARGUMENT);
    template.skins[0].skeleton = refs.skeleton;

    template.clips[0] = {};
    assert_publish_faults(&assets, &document, c3d::INVALID_ARGUMENT);
    template.clips[0] = refs.clip;

    assert_document_intact(&document, &refs);
    assert(document.geometries.len == 1 && document.clips.len == 1);
}

fn void test_publish_rejects_document_references_past_the_entries() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    DocumentRefs refs;
    ModelDocument document = build_document(mem, &refs);
    defer asset::destroy_model_document(&document);

    document.template.meshes[0].geometry = { .index = (uint)document.geometries.len + 1 };
    assert_publish_faults(&assets, &document, c3d::INVALID_ARGUMENT);
}

fn void test_publish_document_rejects_a_custom_material() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    DocumentRefs refs;
    ModelDocument document = build_document(mem, &refs);
    defer asset::destroy_model_document(&document);
    document.materials[0].data = { .kind = MaterialKind.CUSTOM };

    assert_publish_faults(&assets, &document, c3d::INVALID_ARGUMENT);
}

fn void test_publish_document_faults_on_a_full_pool_before_inserting() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_store(&tracker, max_models: 1);
        defer asset::destroy_asset_store(&assets);
        ModelTemplate empty_template;
        assets.add_model_owned(&empty_template, "occupied")!!;
        DocumentRefs refs;
        ModelDocument document = build_document(&tracker, &refs);
        defer asset::destroy_model_document(&document);

        assert_publish_faults(&assets, &document, c3d::CAPACITY_EXCEEDED);
        assert(@catch(assets.find("doc#tex/0")) == NOT_FOUND);
        assert_document_intact(&document, &refs);
        assert(document.geometries[0].data.positions.len == 3);
        assert(document.skeletons[0].data.joint_names[0] == "root");
        assert(document.clips[0].data.name == "take");
    }
    assert(tracker.allocated() == 0);
}

fn void test_publish_document_faults_on_duplicate_keys_within_the_document() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    DocumentRefs refs;
    ModelDocument document = build_document(mem, &refs);
    defer asset::destroy_model_document(&document);
    asset::free_string(document.allocator, document.textures[1].key);
    document.textures[1].key = asset::copy_string(document.allocator, "doc#tex/0");

    assert_publish_faults(&assets, &document, c3d::INVALID_ARGUMENT);
}

fn void test_publish_document_faults_on_short_weights() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    DocumentRefs refs;
    ModelDocument document = build_document(mem, &refs);
    defer asset::destroy_model_document(&document);
    Geometry* geometry = &document.geometries[0].data;
    geometry.joints = alloc::new_array(document.allocator, ushort[<4>], 3);
    geometry.weights = alloc::new_array(document.allocator, Vec4, 2);
    geometry.weights[..] = (Vec4){ 1, 0, 0, 0 };

    assert_publish_faults(&assets, &document, c3d::INVALID_ARGUMENT);
}

fn void test_decode_then_publish_equals_load_model() @test {
    AssetStoreDesc desc = {
        .max_geometries = 8,
        .max_textures   = 8,
        .max_materials  = 8,
        .max_samplers   = 8,
        .max_models     = 2,
    };
    AssetStore loaded = asset::create_asset_store(mem, desc);
    defer asset::destroy_asset_store(&loaded);
    AssetStore published = asset::create_asset_store(mem, desc);
    defer asset::destroy_asset_store(&published);
    String path = fixture_path("gltf", "quad.gltf");

    ModelId loaded_model = gltf::load_model(&loaded, path)!!;
    ModelDocument document = gltf::decode_model(mem, path)!!;
    defer asset::destroy_model_document(&document);
    ModelId published_model = published.publish_document(&document)!!;
    assert_same_stores(&loaded, loaded_model, &published, published_model);
}

fn void test_fbx_decode_then_publish_equals_load_model() @test {
    AssetStoreDesc desc = {
        .max_geometries = 8,
        .max_textures   = asset::BUILTIN_TEXTURE_COUNT + 8,
        .max_materials  = 8,
        .max_samplers   = asset::BUILTIN_SAMPLER_COUNT + 2,
        .max_models     = 2,
        .max_skeletons  = 2,
        .max_clips      = 2,
    };
    AssetStore loaded = asset::create_asset_store(mem, desc);
    defer asset::destroy_asset_store(&loaded);
    AssetStore published = asset::create_asset_store(mem, desc);
    defer asset::destroy_asset_store(&published);
    String path = fixture_path("fbx", "blender_293_embedded_textures_7400_binary.fbx");

    ModelId loaded_model = fbx::load_model(&loaded, path)!!;
    ModelDocument document = fbx::decode_model(mem, path)!!;
    defer asset::destroy_model_document(&document);
    ModelId published_model = published.publish_document(&document)!!;
    assert_same_stores(&loaded, loaded_model, &published, published_model);
}

fn void test_document_references_never_resolve() @test {
    AssetStore assets = create_store(mem);
    defer asset::destroy_asset_store(&assets);
    DocumentRefs refs;
    ModelDocument document = build_document(mem, &refs);
    defer asset::destroy_model_document(&document);
    assets.publish_document(&document)!!;

    assert(@catch(assets.samplers.try_get(refs.sampler)) == c3d::INVALID_ID);
    assert(@catch(assets.textures.try_get(refs.textures[0])) == c3d::INVALID_ID);
    assert(@catch(assets.textures.try_get(refs.textures[1])) == c3d::INVALID_ID);
    assert(@catch(assets.materials.try_get(refs.material)) == c3d::INVALID_ID);
    assert(@catch(assets.geometries.try_get(refs.geometry)) == c3d::INVALID_ID);
    assert(@catch(assets.skeletons.try_get(refs.skeleton)) == c3d::INVALID_ID);
    assert(@catch(assets.clips.try_get(refs.clip)) == c3d::INVALID_ID);
}

fn void test_each_texture_reference_visits_every_slot_of_every_kind() @test {
    Material basic = material::basic({ .color = { 1, 1, 1, 1 }, .map = numbered_slot(1) });
    assert(same_pairs(visited_pairs(&basic), numbered_pairs(1, 1)));

    Material standard = numbered_standard();
    assert(same_pairs(visited_pairs(&standard), numbered_pairs(1, 5)));

    ToonParams toon_params = material::TOON_PARAMS_DEFAULT;
    toon_params.map = numbered_slot(1);
    toon_params.gradient_map = { .index = 6, .generation = 1 };
    Material toon = material::toon(toon_params);
    uint[] toon_expected = { 1 * PAIR_BASE + 101, 6 * PAIR_BASE };
    assert(same_pairs(visited_pairs(&toon), toon_expected));

    Material physical = numbered_physical();
    assert(same_pairs(visited_pairs(&physical), numbered_pairs(1, 15)));

    TextureSlot[material::MAX_CUSTOM_TEXTURE_SLOTS] custom_slots;
    foreach (uint index, &slot : custom_slots) *slot = numbered_slot(index + 1);
    Material custom = material::custom({}, slots: custom_slots);
    assert(same_pairs(visited_pairs(&custom), numbered_pairs(1, 8)));

    Material with_target = numbered_standard();
    with_target.standard.emissive_map.texture = { .kind = RENDER_TARGET, .target = { .index = 9, .generation = 1 } };
    assert(visited_pairs(&with_target).len == 4);
    TextureRef target = with_target.standard.emissive_map.texture;
    assert(target.kind == TextureRefKind.RENDER_TARGET && target.target.index == 9);

    material::@each_texture_reference(&physical; TextureId* texture, SamplerId* sampler) {
        *texture = { .index = 42, .generation = 1 };
    };
    usz rewritten;
    material::@each_texture_reference(&physical; TextureId* texture, SamplerId* sampler) {
        if (texture.index == 42) rewritten++;
    };
    assert(rewritten == 15);
}
