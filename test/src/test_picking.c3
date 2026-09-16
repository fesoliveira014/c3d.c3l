module c3d::test::picking;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::spatial;
import std::math;

const float TOLERANCE @local = 0.0005f;

struct Fixture @local {
    AssetStore assets;
    Scene      scene;
    GeometryId box;
    GeometryId triangle;
    MaterialId opaque;
    MaterialId both_sides;
    Node*      near;
    Node*      far;
}

fn bool close(float first, float second) @local {
    return math::abs(first - second) <= TOLERANCE;
}

fn bool close_vec3(Vec3 first, Vec3 second) @local {
    return close(first.x, second.x) && close(first.y, second.y) && close(first.z, second.z);
}

fn Fixture make_fixture() @local {
    Fixture fixture;
    fixture.assets = asset::create_asset_store(mem, {
        .max_geometries = 4,
        .max_textures   = asset::BUILTIN_TEXTURE_COUNT,
        .max_materials  = 2,
        .max_samplers   = asset::BUILTIN_SAMPLER_COUNT,
    });
    @pool() {
        Geometry box = geometry::box(
            allocator: tmem,
            width:     1,
            height:    1,
            depth:     1,
        );
        fixture.box = fixture.assets.add_geometry(&box, "box")!!;

        Vec3[] positions = alloc::new_array(tmem, Vec3, 3);
        positions[0] = { 0, 0, 0 };
        positions[1] = { 1, 0, 0 };
        positions[2] = { 0, 1, 0 };
        Geometry triangle = { .topology = Topology.TRIANGLES, .positions = positions };
        triangle.finalize();
        fixture.triangle = fixture.assets.add_geometry(&triangle, "triangle")!!;
    };
    fixture.opaque = fixture.assets.add_material(material::basic(), "opaque")!!;
    fixture.both_sides = fixture.assets.add_material(
        material::basic(common: { .double_sided = true }),
        "both_sides",
    )!!;

    fixture.scene = scene::create_scene(mem, { .max_nodes = 16 });
    fixture.near = fixture.scene.add_mesh(fixture.box, fixture.opaque, name: "near")!!;
    fixture.near.local.position = { 0, 0, 1 };
    fixture.far = fixture.scene.add_mesh(fixture.box, fixture.opaque, name: "far")!!;
    fixture.far.local.position = { 0, 0, -1 };
    fixture.scene.update_world();
    return fixture;
}

fn void destroy_fixture(Fixture* fixture) @local {
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn void hide_boxes(Fixture* fixture) @local {
    fixture.near.visible = false;
    fixture.far.visible = false;
    fixture.scene.update_world();
}

fn Node* add_triangle_node(Fixture* fixture, MaterialId material) @local {
    Node* node = fixture.scene.add_mesh(fixture.triangle, material, name: "triangle")!!;
    fixture.scene.update_world();
    return node;
}

fn Ray ray_at(Vec3 origin) @local {
    return { .origin = origin, .direction = { 0, 0, -1 } };
}

fn Ray ray_behind(Vec3 origin) @local {
    return { .origin = origin, .direction = { 0, 0, 1 } };
}

fn PickHit[] pick_bounds(Fixture* fixture, Ray ray) @local {
    return spatial::pick(
        allocator: tmem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        ray:       ray,
    );
}

fn PickHit[] pick_with_layers(Fixture* fixture, Ray ray, uint layers) @local {
    PickOptions options = spatial::PICK_OPTIONS_DEFAULT;
    options.layers = layers;
    return spatial::pick(
        allocator: tmem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        ray:       ray,
        options:   options,
    );
}

fn PickHit[] pick_triangles(Fixture* fixture, Ray ray, PickFaces faces) @local {
    PickOptions options = spatial::PICK_OPTIONS_DEFAULT;
    options.precision = PickPrecision.TRIANGLES;
    options.faces = faces;
    return spatial::pick(
        allocator: tmem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        ray:       ray,
        options:   options,
    );
}

fn uint count_triangle_mode_hits(Fixture* fixture, Ray ray, PickFaces faces) @local {
    @pool() {
        PickHit[] hits = pick_triangles(fixture, ray, faces);
        return (uint)hits.len;
    };
}

fn void test_pick_returns_one_hit_per_object_nearest_first() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);

    @pool() {
        PickHit[] hits = pick_bounds(&fixture, ray_at({ 0, 0, 5 }));

        assert(hits.len == 2);
        assert(hits[0].node == fixture.near);
        assert(hits[1].node == fixture.far);
        assert(close(hits[0].distance, 3.5f));
        assert(close(hits[1].distance, 5.5f));
        assert(close_vec3(hits[0].position, { 0, 0, 1.5f }));
        assert(close_vec3(hits[1].position, { 0, 0, -0.5f }));
        assert(!hits[0].triangle_hit);
        assert(!hits[1].triangle_hit);
    };
}

fn void test_pick_skips_invisible_and_off_layer_nodes() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);

    fixture.far.visible = false;
    fixture.scene.update_world();

    @pool() {
        PickHit[] visible_only = pick_bounds(&fixture, ray_at({ 0, 0, 5 }));
        assert(visible_only.len == 1);
        assert(visible_only[0].node == fixture.near);
    };

    fixture.far.visible = true;
    fixture.far.layers = 2;
    fixture.scene.update_world();

    @pool() {
        PickHit[] near_only = pick_with_layers(&fixture, ray_at({ 0, 0, 5 }), 1);
        assert(near_only.len == 1);
        assert(near_only[0].node == fixture.near);

        PickHit[] far_only = pick_with_layers(&fixture, ray_at({ 0, 0, 5 }), 2);
        assert(far_only.len == 1);
        assert(far_only[0].node == fixture.far);
    };
}

fn void test_pick_follows_world_transform_edits() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);

    fixture.far.visible = false;
    fixture.near.local.position = { 0, 0, -1 };
    fixture.scene.update_world();

    @pool() {
        PickHit[] hits = pick_bounds(&fixture, ray_at({ 0, 0, 5 }));

        assert(hits.len == 1);
        assert(close(hits[0].distance, 5.5f));
        assert(close_vec3(hits[0].position, { 0, 0, -0.5f }));
    };
}

fn void test_pick_uses_the_authored_bound_override() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);

    fixture.far.visible = false;
    Mesh* mesh = fixture.scene.get(fixture.near, Mesh);
    mesh.has_bounds_override = true;
    mesh.local_bounds = { .min = { -2, -2, -2 }, .max = { 2, 2, 2 } };

    @pool() {
        PickHit[] hits = pick_bounds(&fixture, ray_at({ 1.5f, 0, 5 }));

        assert(hits.len == 1);
        assert(close(hits[0].distance, 2));
    };

    mesh.has_bounds_override = false;

    @pool() {
        assert(pick_bounds(&fixture, ray_at({ 1.5f, 0, 5 })).len == 0);
    };
}

fn void test_pick_ignores_removed_geometry() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);

    fixture.assets.remove_geometry(fixture.box);

    @pool() {
        assert(pick_bounds(&fixture, ray_at({ 0, 0, 5 })).len == 0);
    };
}

fn void test_pick_keeps_bounds_after_the_source_release() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);

    fixture.assets.release_geometry_cpu(fixture.box);

    @pool() {
        PickHit[] bounds = pick_bounds(&fixture, ray_at({ 0, 0, 5 }));
        assert(bounds.len == 2);
        assert(close(bounds[0].distance, 3.5f));
        assert(close(bounds[1].distance, 5.5f));

        PickHit[] triangles = pick_triangles(&fixture, ray_at({ 0, 0, 5 }), PickFaces.BOTH);
        assert(triangles.len == 2);
        assert(!triangles[0].triangle_hit);
        assert(!triangles[1].triangle_hit);
        assert(close(triangles[0].distance, 3.5f));
        assert(close(triangles[1].distance, 5.5f));
    };
}

fn void test_pick_triangle_mode_reports_the_triangle_and_barycentric() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    hide_boxes(&fixture);
    Node* node = add_triangle_node(&fixture, fixture.opaque);

    @pool() {
        PickHit[] hits = pick_triangles(&fixture, ray_at({ 0.25f, 0.25f, 3 }), PickFaces.BOTH);

        assert(hits.len == 1);
        assert(hits[0].node == node);
        assert(hits[0].triangle_hit);
        assert(hits[0].triangle_index == 0);
        assert(close(hits[0].distance, 3));
        assert(close_vec3(hits[0].position, { 0.25f, 0.25f, 0 }));
        assert(close_vec3(hits[0].barycentric, { 0.5f, 0.25f, 0.25f }));
    };
}

fn void test_pick_triangle_mode_falls_back_for_deformed_meshes() @test {
    Vec3 hit_point = { 0.25f, 0.25f, 0 };

    {
        Fixture fixture = make_fixture();
        defer destroy_fixture(&fixture);
        hide_boxes(&fixture);
        Node* node = add_triangle_node(&fixture, fixture.opaque);
        fixture.scene.add(node, (SkinBinding){ .joints = {} });

        @pool() {
            PickHit[] hits = pick_triangles(&fixture, ray_at({ 0.25f, 0.25f, 3 }), PickFaces.MATERIAL);

            assert(hits.len == 1);
            assert(!hits[0].triangle_hit);
            assert(close(hits[0].distance, 3));
            assert(close_vec3(hits[0].position, hit_point));
        };
    }

    {
        Fixture fixture = make_fixture();
        defer destroy_fixture(&fixture);
        hide_boxes(&fixture);
        Node* node = add_triangle_node(&fixture, fixture.opaque);
        Mesh* mesh = fixture.scene.get(node, Mesh);
        mesh.morph_weights = alloc::new_array(fixture.scene.allocator, float, 1);
        mesh.morph_weights[0] = 1;

        @pool() {
            PickHit[] hits = pick_triangles(&fixture, ray_at({ 0.25f, 0.25f, 3 }), PickFaces.MATERIAL);

            assert(hits.len == 1);
            assert(!hits[0].triangle_hit);
        };
    }

    {
        Fixture fixture = make_fixture();
        defer destroy_fixture(&fixture);
        hide_boxes(&fixture);
        Node* node = add_triangle_node(&fixture, fixture.opaque);
        Mesh* mesh = fixture.scene.get(node, Mesh);
        mesh.has_bounds_override = true;
        mesh.local_bounds = { .min = { 0, 0, 0 }, .max = { 1, 1, 0 } };

        @pool() {
            PickHit[] hits = pick_triangles(&fixture, ray_at({ 0.25f, 0.25f, 3 }), PickFaces.MATERIAL);

            assert(hits.len == 1);
            assert(!hits[0].triangle_hit);
            assert(close(hits[0].distance, 3));
        };
    }
}

fn void test_pick_accepts_faces_per_the_policy() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    hide_boxes(&fixture);
    Node* node = add_triangle_node(&fixture, fixture.opaque);
    Mesh* mesh = fixture.scene.get(node, Mesh);

    Ray front = ray_at({ 0.25f, 0.25f, 3 });
    Ray back = ray_behind({ 0.25f, 0.25f, -3 });

    assert(count_triangle_mode_hits(&fixture, front, PickFaces.MATERIAL) == 1);
    assert(count_triangle_mode_hits(&fixture, back, PickFaces.MATERIAL) == 0);

    mesh.material = fixture.both_sides;
    assert(count_triangle_mode_hits(&fixture, front, PickFaces.MATERIAL) == 1);
    assert(count_triangle_mode_hits(&fixture, back, PickFaces.MATERIAL) == 1);
    assert(count_triangle_mode_hits(&fixture, front, PickFaces.FRONT) == 1);
    assert(count_triangle_mode_hits(&fixture, back, PickFaces.FRONT) == 0);
    assert(count_triangle_mode_hits(&fixture, back, PickFaces.BOTH) == 1);

    mesh.material = fixture.opaque;
    assert(count_triangle_mode_hits(&fixture, back, PickFaces.BOTH) == 1);

    node.local.scale = { -1, 1, 1 };
    fixture.scene.update_world();

    Ray mirrored_front = ray_at({ -0.25f, 0.25f, 3 });
    Ray mirrored_back = ray_behind({ -0.25f, 0.25f, -3 });

    assert(count_triangle_mode_hits(&fixture, mirrored_front, PickFaces.MATERIAL) == 1);
    assert(count_triangle_mode_hits(&fixture, mirrored_back, PickFaces.MATERIAL) == 0);

    @pool() {
        PickHit[] hits = pick_triangles(&fixture, mirrored_front, PickFaces.MATERIAL);

        assert(hits.len == 1);
        assert(hits[0].triangle_hit);
        assert(close_vec3(hits[0].position, { -0.25f, 0.25f, 0 }));
        assert(close_vec3(hits[0].barycentric, { 0.5f, 0.25f, 0.25f }));
    };

    node.local.scale = { 1, 1, 1 };
    fixture.scene.update_world();
    fixture.assets.remove_material(fixture.opaque);

    assert(count_triangle_mode_hits(&fixture, front, PickFaces.MATERIAL) == 1);
    assert(count_triangle_mode_hits(&fixture, back, PickFaces.MATERIAL) == 1);
}

fn void test_pick_reports_world_distances_under_nonuniform_scale() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    hide_boxes(&fixture);
    Node* node = add_triangle_node(&fixture, fixture.opaque);
    node.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::deg_to_rad(45.0f));
    node.local.scale = { 4, 1, 1 };
    fixture.scene.update_world();

    @pool() {
        Ray ray = ray_at({ 0.25f, 0.25f, 3 });
        PickHit[] hits = pick_triangles(&fixture, ray, PickFaces.BOTH);

        assert(hits.len == 1);
        assert(hits[0].triangle_hit);
        assert(close(hits[0].distance, 3.25f));
        assert(close_vec3(hits[0].position, { 0.25f, 0.25f, -0.25f }));
        assert(close(hits[0].distance, (hits[0].position - ray.origin).length()));

        PickHit[] bounds = pick_bounds(&fixture, ray);
        assert(bounds.len == 1);
        assert(bounds[0].distance <= hits[0].distance);
    };
}

fn void test_pick_returns_nothing_when_the_ray_misses() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);

    @pool() {
        assert(pick_bounds(&fixture, ray_at({ 10, 10, 5 })).len == 0);
        assert(pick_triangles(&fixture, ray_at({ 10, 10, 5 }), PickFaces.BOTH).len == 0);
    };
}
