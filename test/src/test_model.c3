module c3d::test::model;

import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::light;
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
    });
}

fn void test_instantiate_twice_shares_assets_and_owns_nodes() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 32 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("hierarchy.gltf"))!!;

    Node* first = model::instantiate(&assets, &scene, model, name: "first")!!;
    Node* second = model::instantiate(&assets, &scene, model)!!;
    assert(first.name == "first" && first.parent == scene.root);
    assert(scene.count(Mesh) == 4 && scene.count(Camera) == 2 && scene.count(Light) == 2);

    ModelInstance* instance = scene.get(first, ModelInstance);
    assert(instance.source.index == model.index && instance.nodes.len == 8 && instance.base_pose.len == 8);
    assert(instance.nodes[0].parent == first && instance.nodes[1].parent == instance.nodes[0]);
    assert(instance.nodes[1].name == "child_b" && instance.base_pose[1].position == (Vec3){ 0, 1, 0 });
    Mesh* first_mesh = scene.get(instance.nodes[4], Mesh);
    ModelInstance* other = scene.get(second, ModelInstance);
    Mesh* second_mesh = scene.get(other.nodes[4], Mesh);
    assert(first_mesh.geometry.index == second_mesh.geometry.index);
    assert(first_mesh.material.index == second_mesh.material.index);
    assert(scene.get(instance.nodes[2], Camera) != null && scene.get(instance.nodes[7], Light) != null);

    second.local.position = { 5, 0, 0 };
    scene.update_world();
    assert(other.nodes[1].world_position().x - instance.nodes[1].world_position().x == 5);

    scene.remove(first);
    assert(scene.count(Mesh) == 2 && assets.models.is_live(model));
    assets.remove_model(model);
    other = scene.get(second, ModelInstance);
    assert(other.nodes.len == 8 && scene.get(other.nodes[4], Mesh) != null);
}

fn void test_instantiate_over_capacity_leaves_no_partial_subtree() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("hierarchy.gltf"))!!;
    if (catch excuse = model::instantiate(&assets, &scene, model)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "expected a fault");
    }
    assert(scene.root.first_child == null && scene.count(Mesh) == 0 && scene.count(ModelInstance) == 0);
}

fn void test_instantiate_dead_model_is_invalid_id() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("strip.gltf"))!!;
    assets.remove_model(model);
    if (catch excuse = model::instantiate(&assets, &scene, model)) {
        assert(excuse == c3d::INVALID_ID);
    } else {
        assert(false, "expected a fault");
    }
}

fn void test_load_composes_import_and_instance() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    @pool() {
        LoadResult result = gltf::load(
            allocator: tmem,
            assets: &assets,
            scene: &scene,
            path: fixture_path("hierarchy.gltf"),
            options: { .lights = true, .cameras = true, .generate_tangents = true, .scale = 2 },
        )!!;
        assert(result.root.local.scale == (Vec3){ 2, 2, 2 });
        assert(assets.models.is_live(result.model));
        assert(result.geometries.len == 2 && result.materials.len == 2 && result.textures.len == 0);
        assert(result.cameras.len == 1 && scene.get(result.cameras[0], Camera) != null);
        assert(result.lights.len == 1 && scene.get(result.lights[0], Light) != null);
        assert(result.clips.len == 0 && result.skeletons.len == 0);
    };
}
fn void test_instantiate_binds_skin_joints_and_copies_clips() @test {
    AssetStore assets = asset::create_asset_store(mem, {
        .max_geometries = 8,
        .max_textures = 8,
        .max_materials = 8,
        .max_samplers = 8,
        .max_models = 2,
        .max_skeletons = 2,
        .max_clips = 2,
    });
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("skin.gltf"))!!;
    Node* first = model::instantiate(&assets, &scene, model)!!;
    Node* second = model::instantiate(&assets, &scene, model)!!;

    ModelInstance* instance = scene.get(first, ModelInstance);
    assert(instance.clips.len == 1 && instance.base_morph_weights.len == 1);
    assert(instance.base_morph_weights[0].len == 1 && instance.base_morph_weights[0][0] == 0.5f);
    assert(instance.mesh_nodes.len == 1 && instance.mesh_nodes[0] == 1);
    SkinBinding* binding = scene.get(instance.nodes[1], SkinBinding);
    assert(binding != null && binding.joints.len == 2);
    assert(binding.joints[0] == instance.nodes[2] && binding.joints[1] == instance.nodes[3]);
    Mesh* mesh = scene.get(instance.nodes[1], Mesh);
    assert(mesh.morph_weights.len == 1 && mesh.morph_weights.ptr != instance.base_morph_weights[0].ptr);

    ModelInstance* other = scene.get(second, ModelInstance);
    SkinBinding* other_binding = scene.get(other.nodes[1], SkinBinding);
    assert(other_binding.joints[0] != binding.joints[0]);
    assert(other.clips[0].index == instance.clips[0].index);

    ClipId clip = instance.clips[0];
    scene.remove(first);
    assert(scene.count(SkinBinding) == 1 && assets.clips.is_live(clip));
}
