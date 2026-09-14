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

fn void test_draw_list_prefers_transmission_over_blend() @test {
    PhysicalParams transmissive = material::PHYSICAL_PARAMS_DEFAULT;
    transmissive.transmission = 0.5f;
    Material[7] materials = {
        material::basic(),
        material::standard(),
        material::physical(),
        material::physical(transmissive),
        material::physical(transmissive),
        material::physical(transmissive),
        material::toon(),
    };
    materials[1].common.alpha_mode = AlphaMode.BLEND;
    materials[4].common.alpha_mode = AlphaMode.MASK;
    materials[5].common.alpha_mode = AlphaMode.BLEND;
    materials[6].common.alpha_mode = AlphaMode.BLEND;
    DrawList[7] expected = {
        DrawList.OPAQUE, DrawList.TRANSPARENT, DrawList.OPAQUE,
        DrawList.TRANSMISSION, DrawList.TRANSMISSION, DrawList.TRANSMISSION,
        DrawList.TRANSPARENT,
    };
    foreach (index, &material : materials) {
        assert(render::draw_list(material) == expected[index]);
    }
}

fn void test_skinned_candidate_bounds_follow_joints() @test {
    AssetStore assets = asset::create_asset_store(mem, {
        .max_geometries = 4,
        .max_textures   = asset::BUILTIN_TEXTURE_COUNT,
        .max_materials  = 2,
        .max_samplers   = asset::BUILTIN_SAMPLER_COUNT,
        .max_skeletons  = 2,
    });
    defer asset::destroy_asset_store(&assets);
    GeometryId box;
    @pool() {
        Geometry cube = geometry::box(tmem, 1, 1, 1);
        box = assets.add_geometry(&cube, "box")!!;
    };
    MaterialId red = assets.add_material(material::basic({ .color = { 1, 0, 0, 1 } }), "red")!!;
    Skeleton skeleton = {
        .joint_names  = alloc::new_array(mem, String, 1),
        .parents      = alloc::new_array(mem, int, 1),
        .rest_pose    = alloc::new_array(mem, Transform, 1),
        .inverse_bind = alloc::new_array(mem, Mat4, 1),
    };
    skeleton.parents[0] = -1;
    skeleton.rest_pose[0] = maths::TRANSFORM_IDENTITY;
    skeleton.inverse_bind[0] = matrix::IDENTITY4;
    SkeletonId skeleton_id = assets.add_skeleton_owned(&skeleton, "skeleton")!!;

    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f))!!;
    camera_node.local.position = { 0, 20, 5 };
    Node* joint = scene.add_node(name: "joint")!!;
    joint.local.position = { 0, 20, 0 };
    Node* skinned = scene.add_mesh(box, red, name: "skinned")!!;
    Node*[] joints = alloc::new_array(scene.allocator, Node*, 1);
    joints[0] = joint;
    scene.add(skinned, (SkinBinding){ .skeleton = skeleton_id, .joints = joints });
    Node* rigid = scene.add_mesh(box, red, name: "rigid")!!;
    Node* dead = scene.add_mesh(box, red, name: "dead")!!;
    Node*[] dead_joints = alloc::new_array(scene.allocator, Node*, 1);
    dead_joints[0] = joint;
    scene.add(dead, (SkinBinding){ .skeleton = { .index = 1, .generation = 9 }, .joints = dead_joints });
    scene.update_world();

    Camera* camera = scene.get(camera_node, Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, camera_node.world, VIEWPORT);
    @pool() {
        render::ExtractCounts counts;
        render::MeshCandidate[] candidates = render::extract_candidates(
            allocator: tmem,
            scene:     &scene,
            assets:    &assets,
            camera:    &matrices,
            layers:    scene::DEFAULT_LAYERS,
            counts:    &counts,
        );
        assert(candidates.len == 1 && candidates[0].node == skinned && candidates[0].skin != null);
        Aabb bounds = candidates[0].world_bounds;
        assert(bounds.min.y < 20 && bounds.max.y > 20 && bounds.min.y > 19 && bounds.max.y < 21);
        assert(counts.culled == 1 && counts.dangling == 1);

        render::MeshCandidate[] casters = render::extract_shadow_candidates(tmem, &scene, &assets, &counts);
        assert(casters.len == 2 && counts.dangling == 1);
    };
}
