module c3d::test::model;

import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::ecs;
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
    assert(instance.present_node(0).parent == first && instance.present_node(1).parent == instance.present_node(0));
    assert(instance.present_node(1).name == "child_b" && instance.base_pose[1].position == (Vec3){ 0, 1, 0 });
    Mesh* first_mesh = scene.get(instance.present_node(4), Mesh);
    ModelInstance* other = scene.get(second, ModelInstance);
    Mesh* second_mesh = scene.get(other.present_node(4), Mesh);
    assert(first_mesh.geometry.index == second_mesh.geometry.index);
    assert(first_mesh.material.index == second_mesh.material.index);
    assert(scene.get(instance.present_node(2), Camera) != null && scene.get(instance.present_node(7), Light) != null);

    second.local.position = { 5, 0, 0 };
    scene.update_world();
    assert(other.present_node(1).world_position().x - instance.present_node(1).world_position().x == 5);

    scene.remove(first);
    assert(scene.count(Mesh) == 2 && assets.models.is_live(model));
    assets.remove_model(model);
    other = scene.get(second, ModelInstance);
    assert(other.nodes.len == 8 && scene.get(other.present_node(4), Mesh) != null);
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
    SkinBinding* binding = scene.get(instance.present_node(1), SkinBinding);
    assert(binding != null && binding.joints.len == 2);
    assert(binding.joints[0] == instance.present_node(2) && binding.joints[1] == instance.present_node(3));
    Mesh* mesh = scene.get(instance.present_node(1), Mesh);
    assert(mesh.morph_weights.len == 1 && mesh.morph_weights.ptr != instance.base_morph_weights[0].ptr);

    ModelInstance* other = scene.get(second, ModelInstance);
    SkinBinding* other_binding = scene.get(other.present_node(1), SkinBinding);
    assert(other_binding.joints[0] != binding.joints[0]);
    assert(other.clips[0].index == instance.clips[0].index);

    ClipId clip = instance.clips[0];
    scene.remove(first);
    assert(scene.count(SkinBinding) == 1 && assets.clips.is_live(clip));
}

fn void test_absent_model_node_never_resolves_reused_slot() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("hierarchy.gltf"))!!;
    Node* root = model::instantiate(&assets, &scene, model)!!;
    ModelInstance* instance = scene.get(root, ModelInstance);
    Node* removed = instance.present_node(2);
    Entity identity = removed.id;
    Transform baseline = instance.base_pose[2];
    Node* moved = instance.present_node(7);
    scene.reparent(moved, scene.root);
    assert(instance.present_node(7) == moved);

    scene.remove(removed);
    Node* replacement = scene.add_node(root, "replacement")!!;
    assert(replacement == removed && replacement.id.index == identity.index);
    assert(replacement.id.generation != identity.generation);
    assert(instance.present_node(2) == null);
    assert(instance.nodes.len == 8 && instance.node_entities.len == 8 && instance.base_pose.len == 8);
    assert(c3d::same_id(instance.node_entities[2], identity));
    assert(instance.base_pose[2].position == baseline.position);
    assert(instance.present_node(1).name == "child_b");
    assert(instance.present_node(7) == moved);
    scene.remove(replacement);
    assert(instance.present_node(2) == null);
}

fn void test_removing_model_subtree_keeps_all_template_slots_absent() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    ModelId model = gltf::load_model(&assets, fixture_path("hierarchy.gltf"))!!;
    Node* root = model::instantiate(&assets, &scene, model)!!;
    ModelInstance* instance = scene.get(root, ModelInstance);
    Node* removed = instance.present_node(3);
    Node* application_child = scene.add_node(instance.present_node(6), "application")!!;
    Entity application_id = application_child.id;
    assert(removed.name == "mesh_c" && instance.present_node(6).parent == removed);

    scene.remove(removed);
    assert(!scene.world.is_alive(application_id));
    for (usz index = 3; index <= 6; index++) assert(instance.present_node(index) == null);
    for (uint index = 0; index < 5; index++) scene.add_node(root, "replacement")!!;
    for (usz index = 3; index <= 6; index++) assert(instance.present_node(index) == null);
    assert(instance.present_node(0).name == "root_a" && instance.present_node(7).name == "lamp");
    assert(instance.nodes.len == 8 && instance.node_entities.len == 8 && instance.base_pose.len == 8);
}
