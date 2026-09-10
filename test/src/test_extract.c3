module c3d::test::extract;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::render;
import c3d::scene;
import std::math;

const Vec2 VIEWPORT @local = { 1600, 900 };

struct Fixture @local {
    AssetStore assets;
    Scene      scene;
    GeometryId box;
    MaterialId red;
    Node*      camera_node;
    Node*      visible;
    Node*      hidden;
    Node*      off_layer;
    Node*      outside;
    Node*      dangling;
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
        Geometry box = geometry::box(tmem, 1, 1, 1);
        fixture.box = fixture.assets.add_geometry(&box, "box")!!;
    };
    fixture.red = fixture.assets.add_material(material::basic({ .color = { 1, 0, 0, 1 } }), "red")!!;

    fixture.scene = scene::create_scene(mem, { .max_nodes = 16 });
    fixture.camera_node = fixture.scene.add_camera(camera::perspective_deg(60, 0.1f))!!;
    fixture.camera_node.local.position = { 0, 0, 5 };
    fixture.visible = fixture.scene.add_mesh(fixture.box, fixture.red, name: "visible")!!;
    fixture.hidden = fixture.scene.add_mesh(fixture.box, fixture.red, name: "hidden")!!;
    fixture.hidden.visible = false;
    fixture.off_layer = fixture.scene.add_mesh(fixture.box, fixture.red, name: "off_layer")!!;
    fixture.off_layer.layers = 2;
    fixture.outside = fixture.scene.add_mesh(fixture.box, fixture.red, name: "outside")!!;
    fixture.outside.local.position = { 100, 0, 0 };
    GeometryId dead = { .index = 3, .generation = 7 };
    fixture.dangling = fixture.scene.add_mesh(dead, fixture.red, name: "dangling")!!;
    fixture.scene.update_world();
    return fixture;
}

fn void destroy_fixture(Fixture* fixture) @local {
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn CameraMatrices matrices_of(Fixture* fixture) @local {
    Camera* camera = fixture.scene.get(fixture.camera_node, Camera);
    return camera::derive_matrices(*camera, fixture.camera_node.world, VIEWPORT);
}

fn void test_extract_includes_only_visible_in_layer_in_frustum_live_meshes() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    fixture.scene.get(fixture.visible, Mesh).receive_shadow = false;
    CameraMatrices matrices = matrices_of(&fixture);
    @pool() {
        render::ExtractCounts counts;
        render::MeshCandidate[] candidates = render::extract_candidates(
            allocator: tmem,
            scene:     &fixture.scene,
            assets:    &fixture.assets,
            camera:    &matrices,
            layers:    scene::DEFAULT_LAYERS,
            counts:    &counts,
        );
        assert(candidates.len == 1);
        assert(candidates[0].node == fixture.visible);
        assert(!candidates[0].receive_shadow);
        assert(counts.visible == 1 && counts.culled == 1 && counts.dangling == 1);
    };
}

fn void test_extract_layer_mask_selects_nodes() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    CameraMatrices matrices = matrices_of(&fixture);
    @pool() {
        render::ExtractCounts counts;
        render::MeshCandidate[] candidates = render::extract_candidates(
            allocator: tmem,
            scene:     &fixture.scene,
            assets:    &fixture.assets,
            camera:    &matrices,
            layers:    2,
            counts:    &counts,
        );
        assert(candidates.len == 1);
        assert(candidates[0].node == fixture.off_layer);
        assert(candidates[0].receive_shadow);
        assert(counts.culled == 0 && counts.dangling == 0);
    };
}

fn void test_extract_bounds_override_replaces_geometry_bounds() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Mesh* mesh = fixture.scene.get(fixture.visible, Mesh);
    mesh.has_bounds_override = true;
    mesh.local_bounds = { .min = { 99, -1, -1 }, .max = { 101, 1, 1 } };
    CameraMatrices matrices = matrices_of(&fixture);
    @pool() {
        render::ExtractCounts counts;
        render::MeshCandidate[] candidates = render::extract_candidates(
            allocator: tmem,
            scene:     &fixture.scene,
            assets:    &fixture.assets,
            camera:    &matrices,
            layers:    scene::DEFAULT_LAYERS,
            counts:    &counts,
        );
        assert(candidates.len == 0);
        assert(counts.culled == 2);
    };
}

fn void test_extract_depth_is_nearer_for_closer_mesh() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Node* closer = fixture.scene.add_mesh(fixture.box, fixture.red, name: "closer")!!;
    closer.local.position = { 0, 0, 2 };
    fixture.scene.update_world();
    CameraMatrices matrices = matrices_of(&fixture);
    @pool() {
        render::ExtractCounts counts;
        render::MeshCandidate[] candidates = render::extract_candidates(
            allocator: tmem,
            scene:     &fixture.scene,
            assets:    &fixture.assets,
            camera:    &matrices,
            layers:    scene::DEFAULT_LAYERS,
            counts:    &counts,
        );
        assert(candidates.len == 2);
        float origin_depth = candidates[0].node == fixture.visible ? candidates[0].ndc_depth : candidates[1].ndc_depth;
        float closer_depth = candidates[0].node == closer ? candidates[0].ndc_depth : candidates[1].ndc_depth;
        assert(closer_depth > origin_depth);
        assert(origin_depth > 0 && closer_depth < 1);
    };
}
