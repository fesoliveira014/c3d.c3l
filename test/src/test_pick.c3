module c3d::test::pick;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::spatial;
import std::math;

const float TOLERANCE @local = 0.0005f;
const float THIRD @local = 1.0f / 3;

const PickOptions TRIANGLES @local = {
    .precision = PickPrecision.TRIANGLES,
    .faces     = PickFaces.MATERIAL,
    .layers    = camera::ALL_LAYERS,
};

struct Fixture @local {
    AssetStore assets;
    Scene      scene;
    GeometryId box;
    GeometryId triangle;
    MaterialId one_sided;
    MaterialId two_sided;
}

fn bool close(float first, float second) @local {
    return math::abs(first - second) <= TOLERANCE;
}

fn Ray ray_toward_minus_z(Vec3 origin) @local {
    return { .origin = origin, .direction = { 0, 0, -1 } };
}

fn PickOptions with_faces(PickFaces faces) @local {
    PickOptions options = TRIANGLES;
    options.faces = faces;
    return options;
}

fn PickHit[] pick_along(Fixture* fixture, Ray ray, PickOptions options = spatial::PICK_OPTIONS_DEFAULT) @local {
    return spatial::pick(
        allocator: tmem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        ray:       ray,
        options:   options,
    );
}

fn Fixture make_fixture() @local {
    Fixture fixture;
    fixture.assets = asset::create_asset_store(mem, {
        .max_geometries = 4,
        .max_textures   = asset::BUILTIN_TEXTURE_COUNT,
        .max_materials  = 3,
        .max_samplers   = asset::BUILTIN_SAMPLER_COUNT,
        .max_skeletons  = 2,
    });
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        fixture.box = fixture.assets.add_geometry(&box, "box")!!;
        Vec3[] corners = alloc::new_array(tmem, Vec3, 3);
        corners[0] = { -1, -1, 0 };
        corners[1] = { 1, -1, 0 };
        corners[2] = { 0, 1, 0 };
        Geometry triangle = { .positions = corners };
        triangle.finalize();
        fixture.triangle = fixture.assets.add_geometry(&triangle, "triangle")!!;
    };
    fixture.one_sided = fixture.assets.add_material(material::basic({ .color = { 1, 0, 0, 1 } }), "single")!!;
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.double_sided = true;
    fixture.two_sided = fixture.assets.add_material(material::basic({ .color = { 0, 1, 0, 1 } }, common), "double")!!;
    fixture.scene = scene::create_scene(mem, { .max_nodes = 16 });
    return fixture;
}

fn void destroy_fixture(Fixture* fixture) @local {
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn Node* add_box_at(Fixture* fixture, float z, String name) @local {
    Node* node = fixture.scene.add_mesh(fixture.box, fixture.one_sided, name: name)!!;
    node.local.position = { 0, 0, z };
    return node;
}

fn Node* add_triangle_at(Fixture* fixture, float z, MaterialId material) @local {
    Node* node = fixture.scene.add_mesh(fixture.triangle, material, name: "triangle")!!;
    node.local.position = { 0, 0, z };
    return node;
}

fn void test_bounds_pick_orders_hits_nearest_first() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Node* far = add_box_at(&fixture, -9, "far");
    Node* near = add_box_at(&fixture, -3, "near");
    Node* middle = add_box_at(&fixture, -6, "middle");
    fixture.scene.update_world();

    @pool() {
        PickHit[] hits = pick_along(&fixture, ray_toward_minus_z({ 0, 0, 0 }));
        assert(hits.len == 3);
        assert(hits[0].node == near && hits[1].node == middle && hits[2].node == far);
        assert(close(hits[0].distance, 2.5f) && close(hits[1].distance, 5.5f) && close(hits[2].distance, 8.5f));
        assert(close(hits[0].position.z, -2.5f));
        foreach (hit : hits) assert(!hit.triangle_hit && !hit.instanced);
    };
}

fn void test_pick_skips_hidden_off_layer_and_dangling_meshes() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Node* hidden = add_box_at(&fixture, -3, "hidden");
    hidden.visible = false;
    Node* off_layer = add_box_at(&fixture, -6, "off_layer");
    off_layer.layers = 2;
    GeometryId dead = { .index = 3, .generation = 7 };
    Node* dangling = fixture.scene.add_mesh(dead, fixture.one_sided, name: "dangling")!!;
    dangling.local.position = { 0, 0, -9 };
    fixture.scene.update_world();

    @pool() {
        Ray ray = ray_toward_minus_z({ 0, 0, 0 });
        PickOptions options = spatial::PICK_OPTIONS_DEFAULT;
        options.layers = scene::DEFAULT_LAYERS;
        assert(pick_along(&fixture, ray, options).len == 0);
        options.layers = 2;
        PickHit[] hits = pick_along(&fixture, ray, options);
        assert(hits.len == 1 && hits[0].node == off_layer);
    };
}

fn void test_pick_follows_transform_after_update_world() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Node* box = add_box_at(&fixture, -3, "box");
    fixture.scene.update_world();

    @pool() {
        Ray ray = ray_toward_minus_z({ 0, 0, 0 });
        assert(close(pick_along(&fixture, ray)[0].distance, 2.5f));
        box.local.position.z = -10;
        fixture.scene.update_world();
        assert(close(pick_along(&fixture, ray)[0].distance, 9.5f));
    };
}

fn void test_bounds_override_replaces_geometry_bounds() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Node* box = add_box_at(&fixture, -5, "box");
    Mesh* mesh = fixture.scene.get(box, Mesh);
    mesh.has_bounds_override = true;
    mesh.local_bounds = { .min = { -1, -1, -3 }, .max = { 1, 1, 3 } };
    fixture.scene.update_world();

    @pool() {
        Ray ray = ray_toward_minus_z({ 0, 0, 0 });
        PickHit[] bounds = pick_along(&fixture, ray);
        assert(bounds.len == 1 && close(bounds[0].distance, 2));
        PickHit[] triangles = pick_along(&fixture, ray, TRIANGLES);
        assert(triangles.len == 1 && close(triangles[0].distance, 2) && !triangles[0].triangle_hit);
    };
}

fn void test_triangle_distance_is_world_distance_under_nonuniform_scale() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Node* box = add_box_at(&fixture, -10, "box");
    box.local.scale = { 2, 3, 4 };
    fixture.scene.update_world();

    @pool() {
        Ray ray = ray_toward_minus_z({ 0, 0, 0 });
        PickHit[] triangles = pick_along(&fixture, ray, TRIANGLES);
        assert(triangles.len == 1 && triangles[0].triangle_hit);
        assert(close(triangles[0].distance, 8) && close(triangles[0].position.z, -8));
        PickHit[] bounds = pick_along(&fixture, ray);
        assert(bounds.len == 1 && close(bounds[0].distance, 8));
    };
}

fn void test_triangle_hit_reports_index_and_barycentric() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    add_triangle_at(&fixture, -5, fixture.one_sided);
    fixture.scene.update_world();

    @pool() {
        PickHit[] hits = pick_along(&fixture, ray_toward_minus_z({ 0, -THIRD, 0 }), TRIANGLES);
        assert(hits.len == 1 && hits[0].triangle_hit && hits[0].triangle_index == 0);
        assert(close(hits[0].distance, 5));
        Vec3 weights = hits[0].barycentric;
        assert(close(weights.x, THIRD) && close(weights.y, THIRD) && close(weights.z, THIRD));

        Ray corner = ray_toward_minus_z({ 0.9f, 0.9f, 0 });
        assert(pick_along(&fixture, corner, TRIANGLES).len == 0);
        assert(pick_along(&fixture, corner).len == 1);
    };
}

fn void test_triangle_pick_indexed_box_hits_front_face() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    add_box_at(&fixture, -5, "box");
    fixture.scene.update_world();

    @pool() {
        PickHit[] hits = pick_along(&fixture, ray_toward_minus_z({ 0, 0, 0 }), TRIANGLES);
        assert(hits.len == 1 && hits[0].triangle_hit);
        assert(close(hits[0].distance, 4.5f) && hits[0].triangle_index < 12);
    };
}

fn void test_faces_policy_rejects_back_faces() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Node* triangle = add_triangle_at(&fixture, -5, fixture.one_sided);
    fixture.scene.update_world();
    Ray from_behind = { .origin = { 0, -THIRD, -10 }, .direction = { 0, 0, 1 } };

    @pool() {
        assert(pick_along(&fixture, from_behind, TRIANGLES).len == 0);
        assert(pick_along(&fixture, from_behind, with_faces(PickFaces.BOTH)).len == 1);
        fixture.scene.get(triangle, Mesh).material = fixture.two_sided;
        assert(pick_along(&fixture, from_behind, TRIANGLES).len == 1);
        assert(pick_along(&fixture, from_behind, with_faces(PickFaces.FRONT)).len == 0);
    };
}

fn void test_mirrored_node_keeps_local_front_faces() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Node* triangle = add_triangle_at(&fixture, -5, fixture.one_sided);
    triangle.local.scale = { -1, 1, 1 };
    fixture.scene.update_world();

    @pool() {
        PickHit[] hits = pick_along(&fixture, ray_toward_minus_z({ 0, -THIRD, 0 }), with_faces(PickFaces.FRONT));
        assert(hits.len == 1 && hits[0].triangle_hit && close(hits[0].distance, 5));
    };
}

fn void test_released_geometry_falls_back_to_bounds() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    add_box_at(&fixture, -5, "box");
    fixture.scene.update_world();
    fixture.assets.release_geometry_cpu(fixture.box);

    @pool() {
        PickHit[] hits = pick_along(&fixture, ray_toward_minus_z({ 0, 0, 0 }), TRIANGLES);
        assert(hits.len == 1 && !hits[0].triangle_hit && close(hits[0].distance, 4.5f));
    };
}

fn void test_skinned_mesh_uses_joint_bounds_not_triangles() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Skeleton skeleton = {
        .joint_names  = alloc::new_array(mem, String, 1),
        .parents      = alloc::new_array(mem, int, 1),
        .rest_pose    = alloc::new_array(mem, Transform, 1),
        .inverse_bind = alloc::new_array(mem, Mat4, 1),
    };
    skeleton.parents[0] = -1;
    skeleton.rest_pose[0] = maths::TRANSFORM_IDENTITY;
    skeleton.inverse_bind[0] = matrix::IDENTITY4;
    SkeletonId skeleton_id = fixture.assets.add_skeleton_owned(&skeleton, "skeleton")!!;
    Node* joint = fixture.scene.add_node(name: "joint")!!;
    joint.local.position = { 0, 20, 0 };
    Node* skinned = add_box_at(&fixture, 0, "skinned");
    Node*[] joints = alloc::new_array(fixture.scene.allocator, Node*, 1);
    joints[0] = joint;
    fixture.scene.add(skinned, (SkinBinding){ .skeleton = skeleton_id, .joints = joints });
    fixture.scene.update_world();

    @pool() {
        Ray downward = { .origin = { 0, 30, 0 }, .direction = { 0, -1, 0 } };
        PickHit[] hits = pick_along(&fixture, downward, TRIANGLES);
        assert(hits.len == 1 && hits[0].node == skinned && !hits[0].triangle_hit);
        assert(hits[0].distance > 9 && hits[0].distance < 10);
    };
}

fn bool meets(Ray ray, float* distance, Vec3* barycentric) @local {
    return maths::ray_intersects_triangle(
        ray:         ray,
        a:           { -1, -1, 0 },
        b:           { 1, -1, 0 },
        c:           { 0, 1, 0 },
        distance:    distance,
        barycentric: barycentric,
    );
}

fn void test_ray_intersects_triangle_reports_parameter_and_misses_parallel() @test {
    float distance;
    Vec3 barycentric;

    Ray unnormalized = { .origin = { 0, -THIRD, 2 }, .direction = { 0, 0, -2 } };
    assert(meets(unnormalized, &distance, &barycentric));
    assert(close(distance, 1));
    assert(close(barycentric.x + barycentric.y + barycentric.z, 1));

    Ray planar = { .origin = { 0, 0, 0 }, .direction = { 1, 0, 0 } };
    assert(!meets(planar, &distance, &barycentric));
    Ray away = { .origin = { 0, 0, 2 }, .direction = { 0, 0, 1 } };
    assert(!meets(away, &distance, &barycentric));
}
