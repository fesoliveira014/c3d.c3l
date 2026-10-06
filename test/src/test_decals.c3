module c3d::test::decals;

import c3d;
import c3d::scene;
import std::math;

fn void test_add_decal_scales_node_and_rejects_partial_add() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);

    MaterialId material = { .index = 7, .generation = 3 };
    DecalDesc desc = scene::default_decal_desc(material);
    assert(desc.size == (Vec3){ 1, 1, 1 });
    desc.size = { 2, 1, 0.5f };
    Node* node = scene.add_decal(desc)!!;
    assert(node.local.scale == desc.size);
    Decal* decal = scene.get(node, Decal);
    assert(decal != null);
    assert(c3d::same_id(decal.material, material));
    assert(decal.weights.base_color == 1 && decal.weights.normal == 1);
    assert(decal.weights.roughness == 1 && decal.weights.metallic == 1);
    assert(math::abs(decal.fade_angle - (float)math::PI * 4 / 9) < 1e-6f);
    assert(decal.receiver_layers == uint::max && decal.order == 0);

    if (catch excuse = scene.add_decal(desc)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "a full scene added a decal");
    }
    assert(scene.count(Decal) == 1);
    assert(scene.root.first_child == node && node.next_sibling == null);

    desc.size.x = 0;
    reject_decal_without_mutation(&scene, desc);
}

fn void test_invalid_decal_descriptions_preserve_scene() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 2 });
    defer scene::destroy_scene(&scene);
    scene.add_node()!!;
    DecalDesc valid = scene::default_decal_desc((MaterialId){});

    float[4] bad_sizes = { 0, -1, float::inf, float::nan };
    for (uint axis = 0; axis < 3; axis++) {
        foreach (float size : bad_sizes) {
            DecalDesc desc = valid;
            desc.size[axis] = size;
            reject_decal_without_mutation(&scene, desc);
        }
    }

    float[4] bad_weights = { -0.01f, 1.01f, float::inf, float::nan };
    for (uint channel = 0; channel < 4; channel++) {
        foreach (float weight : bad_weights) {
            DecalDesc desc = valid;
            switch (channel) {
                case 0: desc.decal.weights.base_color = weight;
                case 1: desc.decal.weights.normal = weight;
                case 2: desc.decal.weights.roughness = weight;
                case 3: desc.decal.weights.metallic = weight;
            }
            reject_decal_without_mutation(&scene, desc);
        }
    }

    float[4] bad_angles = { -0.01f, (float)math::PI / 2 + 0.01f, float::inf, float::nan };
    foreach (float angle : bad_angles) {
        DecalDesc desc = valid;
        desc.decal.fade_angle = angle;
        reject_decal_without_mutation(&scene, desc);
    }

    valid.decal.weights = { .base_color = 0, .normal = 1, .roughness = 0, .metallic = 1 };
    valid.decal.fade_angle = 0;
    Node* node = scene.add_decal(valid)!!;
    scene.remove(node);
    valid.decal.fade_angle = (float)math::PI / 2;
    scene.add_decal(valid)!!;
    assert(scene.count(Decal) == 1);
}

fn void reject_decal_without_mutation(Scene* scene, DecalDesc desc) @local {
    Node* first_child = scene.root.first_child;
    uint free_count = scene.world.entities.free_count;
    uint decal_count = scene.count(Decal);
    if (catch excuse = scene.add_decal(desc)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        unreachable("expected an invalid decal description fault");
    }
    assert(scene.root.first_child == first_child);
    assert(scene.world.entities.free_count == free_count);
    assert(scene.count(Decal) == decal_count);
}
