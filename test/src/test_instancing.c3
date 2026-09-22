module c3d::test::instancing;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::spatial;
import std::math;

const Vec4 WHITE @local = { 1, 1, 1, 1 };
const Vec4 RED @local = { 1, 0, 0, 1 };
const Vec4 GREEN @local = { 0, 1, 0, 1 };

struct Fixture @local {
    AssetStore assets;
    Scene      scene;
    GeometryId box;
    MaterialId red;
}

fn Fixture make_fixture(Allocator allocator = mem) @local {
    Fixture fixture;
    fixture.assets = asset::create_asset_store(allocator, {
        .max_geometries = 2,
        .max_textures   = asset::BUILTIN_TEXTURE_COUNT,
        .max_materials  = 2,
        .max_samplers   = asset::BUILTIN_SAMPLER_COUNT,
        .max_shaders    = 1,
    });
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        fixture.box = fixture.assets.add_geometry(&box, "box")!!;
    };
    fixture.red = fixture.assets.add_material(material::basic({ .color = RED }), "red")!!;
    fixture.scene = scene::create_scene(allocator, { .max_nodes = 8 });
    return fixture;
}

fn void destroy_fixture(Fixture* fixture) @local {
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn Transform at(Vec3 position) @local {
    Transform transform = maths::TRANSFORM_IDENTITY;
    transform.position = position;
    return transform;
}

fn bool same_transform(Transform first, Transform second) @local {
    return first.position == second.position && first.scale == second.scale
        && first.rotation.v == second.rotation.v;
}

fn uint live_nodes(Scene* scene) @local {
    uint count;
    foreach (&node : scene.nodes) {
        if (scene.world.is_alive(node.id)) count++;
    }
    return count;
}

fn void test_add_instanced_mesh_copies_into_capacity() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Transform[2] transforms = { at({ -1, 0, 0 }), at({ 1, 0, 0 }) };
    Vec4[1] colors = { GREEN };

    Node* node = fixture.scene.add_instanced_mesh(
        geometry:   fixture.box,
        material:   fixture.red,
        capacity:   4,
        transforms: transforms[..],
        colors:     colors[..],
    )!!;
    transforms[0].position = { 9, 9, 9 };
    colors[0] = RED;

    InstancedMesh* batch = fixture.scene.get(node, InstancedMesh);
    assert(batch.count == 2);
    assert(batch.transforms.len == 4 && batch.colors.len == 4);
    assert(batch.transforms[0].position == (Vec3){ -1, 0, 0 });
    assert(batch.colors[0] == GREEN);
    for (usz index = 1; index < 4; index++) assert(batch.colors[index] == WHITE);
    assert(batch.cast_shadow && batch.receive_shadow);
}

fn void test_add_instanced_mesh_rejects_bad_counts() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Transform[3] transforms = { at({ 0, 0, 0 }), at({ 1, 0, 0 }), at({ 2, 0, 0 }) };
    Vec4[3] colors = { RED, GREEN, WHITE };
    uint nodes_before = live_nodes(&fixture.scene);

    Node*? oversized = fixture.scene.add_instanced_mesh(fixture.box, fixture.red, 2, transforms[..]);
    assert(@catch(oversized) == c3d::CAPACITY_EXCEEDED);
    Node*? extra_colors = fixture.scene.add_instanced_mesh(
        geometry:   fixture.box,
        material:   fixture.red,
        capacity:   4,
        transforms: transforms[:2],
        colors:     colors[..],
    );
    assert(@catch(extra_colors) == c3d::INVALID_ARGUMENT);

    assert(fixture.scene.count(InstancedMesh) == 0);
    assert(live_nodes(&fixture.scene) == nodes_before);
}

fn void test_resize_instances_fills_new_slots() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Transform[1] transforms = { at({ 3, 0, 0 }) };
    transforms[0].scale = { 2, 2, 2 };
    Node* node = fixture.scene.add_instanced_mesh(fixture.box, fixture.red, 4, transforms[..])!!;

    fixture.scene.resize_instances(node, 3)!!;
    InstancedMesh* batch = fixture.scene.get(node, InstancedMesh);
    assert(batch.count == 3);
    assert(same_transform(batch.transforms[0], transforms[0]));
    for (usz index = 1; index < 3; index++) {
        assert(same_transform(batch.transforms[index], maths::TRANSFORM_IDENTITY));
        assert(batch.colors[index] == WHITE);
    }

    assert(@catch(fixture.scene.resize_instances(node, 5)) == c3d::CAPACITY_EXCEEDED);
    assert(fixture.scene.get(node, InstancedMesh).count == 3);
}

fn void test_set_instances_copies_and_sets_count() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Node* node = fixture.scene.add_instanced_mesh(fixture.box, fixture.red, 4)!!;
    Transform[5] transforms = { at({ 0, 0, 0 }), at({ 1, 0, 0 }), at({ 2, 0, 0 }), at({ 3, 0, 0 }), at({ 4, 0, 0 }) };
    Vec4[1] colors = { GREEN };

    fixture.scene.set_instances(node, transforms[:3], colors[..])!!;
    InstancedMesh* batch = fixture.scene.get(node, InstancedMesh);
    assert(batch.count == 3);
    assert(batch.transforms[2].position == (Vec3){ 2, 0, 0 });
    assert(batch.colors[0] == GREEN && batch.colors[1] == WHITE && batch.colors[2] == WHITE);

    assert(@catch(fixture.scene.set_instances(node, transforms[..])) == c3d::CAPACITY_EXCEEDED);
    batch = fixture.scene.get(node, InstancedMesh);
    assert(batch.count == 3 && batch.colors[0] == GREEN);
}

fn void test_remove_batch_node_frees_arrays() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        Fixture fixture = make_fixture(&tracker);
        defer destroy_fixture(&fixture);
        Node* node = fixture.scene.add_instanced_mesh(fixture.box, fixture.red, 1000)!!;
        sz before = tracker.allocated();

        fixture.scene.remove(node);

        assert(before - tracker.allocated() >= 1000 * (Transform::size + Vec4::size));
        assert(fixture.assets.geometries.is_live(fixture.box));
    }
}

fn void test_instanced_world_bounds_merges_instances() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Transform[2] transforms = { at({ -2, 0, 0 }), at({ 2, 0, 0 }) };
    Node* node = fixture.scene.add_instanced_mesh(fixture.box, fixture.red, 2, transforms[..])!!;
    node.local.scale = { 2, 2, 2 };
    fixture.scene.update_world();
    InstancedMesh* batch = fixture.scene.get(node, InstancedMesh);

    Aabb merged = spatial::instanced_world_bounds(&fixture.assets, node, batch);
    assert(merged.min == (Vec3){ -5, -1, -1 } && merged.max == (Vec3){ 5, 1, 1 });

    batch.has_bounds_override = true;
    batch.local_bounds = { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } };
    Aabb overridden = spatial::instanced_world_bounds(&fixture.assets, node, batch);
    assert(overridden.min == (Vec3){ -2, -2, -2 } && overridden.max == (Vec3){ 2, 2, 2 });
}

fn void test_pick_reports_instance_index() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Transform[3] transforms = { at({ -3, 0, 0 }), at({ 0, 0, 0 }), at({ 3, 0, 0 }) };
    fixture.scene.add_instanced_mesh(fixture.box, fixture.red, 3, transforms[..])!!;
    fixture.scene.update_world();
    Ray ray = { .origin = { 0, 0, 10 }, .direction = { 0, 0, -1 } };
    PickOptions options = spatial::PICK_OPTIONS_DEFAULT;
    options.precision = PickPrecision.TRIANGLES;

    @pool() {
        PickHit[] hits = spatial::pick(tmem, &fixture.assets, &fixture.scene, ray, options);
        assert(hits.len == 1);
        assert(hits[0].instanced && hits[0].instance_index == 1);
        assert(hits[0].triangle_hit);
        assert(math::abs(hits[0].distance - 9.5f) < 0.0001f);
    };
}

fn void test_shader_desc_rejects_half_instanced_pair() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    char[4] stage = { 1, 2, 3, 4 };
    ShaderDesc half = {
        .fragment = stage[..],
        .vertex   = { .shaded = stage[..], .depth = stage[..], .instanced_shaded = stage[..] },
    };
    assert(@catch(fixture.assets.add_shader(&half, "half")) == c3d::INVALID_ARGUMENT);

    ShaderDesc unpaired = {
        .fragment = stage[..],
        .vertex   = { .instanced_shaded = stage[..], .instanced_depth = stage[..] },
    };
    assert(@catch(fixture.assets.add_shader(&unpaired, "unpaired")) == c3d::INVALID_ARGUMENT);

    ShaderDesc complete = {
        .fragment = stage[..],
        .vertex   = {
            .shaded           = stage[..],
            .depth            = stage[..],
            .instanced_shaded = stage[..],
            .instanced_depth  = stage[..],
        },
    };
    ShaderId shader = fixture.assets.add_shader(&complete, "complete")!!;
    assert(fixture.assets.shader(shader).desc.vertex.instanced_depth.len == 4);
}
