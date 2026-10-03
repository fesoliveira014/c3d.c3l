module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import std::math;

const uint WIDE_JOINT_COUNT @private = 257; // one past the 8-bit joint index range

fn ModelId? add_wide_crowd_model(Fixture* fixture) @private {
    AssetStore* assets = &fixture.assets;
    GeometryId wide;
    GeometryId morphed;
    @pool() {
        Geometry first = geometry::box(tmem, 0.5f, 0.5f, 0.5f);
        first.joints = alloc::new_array(tmem, ushort[<4>], first.positions.len);
        first.weights = alloc::new_array(tmem, Vec4, first.positions.len);
        foreach (index, &weights : first.weights) {
            first.joints[index] = { (ushort)(WIDE_JOINT_COUNT - 1), 0, 0, 0 };
            *weights = { 1, 0, 0, 0 };
        }
        wide = assets.add_geometry(&first)!;

        Geometry second = geometry::box(tmem, 0.5f, 0.5f, 0.5f);
        second.joints = alloc::new_array(tmem, ushort[<4>], second.positions.len);
        second.weights = alloc::new_array(tmem, Vec4, second.positions.len);
        foreach (index, &weights : second.weights) {
            second.joints[index] = { 0, 0, 0, 0 };
            *weights = { 1, 0, 0, 0 };
        }
        second.targets = alloc::new_array(tmem, MorphTarget, 1);
        second.targets[0] = {
            .position_deltas = alloc::new_array(tmem, Vec3, second.positions.len),
            .normal_deltas   = alloc::new_array(tmem, Vec3, second.positions.len),
        };
        morphed = assets.add_geometry(&second)!;
    };

    Skeleton skeleton = {
        .joint_names  = alloc::new_array(assets.allocator, String, WIDE_JOINT_COUNT),
        .parents      = alloc::new_array(assets.allocator, int, WIDE_JOINT_COUNT),
        .rest_pose    = alloc::new_array(assets.allocator, Transform, WIDE_JOINT_COUNT),
        .inverse_bind = alloc::new_array(assets.allocator, Mat4, WIDE_JOINT_COUNT),
    };
    foreach (index, &parent : skeleton.parents) {
        *parent = -1;
        skeleton.rest_pose[index] = maths::TRANSFORM_IDENTITY;
        skeleton.inverse_bind[index] = matrix::IDENTITY4;
    }
    SkeletonId skeleton_id = assets.add_skeleton_owned(&skeleton)!;

    AnimationClip clip = {
        .name     = "still".copy(assets.allocator),
        .duration = 1,
        .tracks   = alloc::new_array(assets.allocator, Track, 0),
        .targets  = alloc::new_array(assets.allocator, uint, 0),
    };
    ClipId still = assets.add_clip_owned(&clip)!;

    uint node_count = WIDE_JOINT_COUNT + 3;
    ModelTemplate template = {
        .nodes  = alloc::new_array(assets.allocator, NodeTemplate, node_count),
        .meshes = alloc::new_array(assets.allocator, ModelMesh, 2),
        .skins  = alloc::new_array(assets.allocator, ModelSkin, 2),
        .clips  = alloc::new_array(assets.allocator, ClipId, 1),
    };
    foreach (index, &node : template.nodes) {
        node.parent = index == 0 ? -1 : 0;
        node.name = string::format(assets.allocator, "node%d", index);
        node.local = maths::TRANSFORM_IDENTITY;
        node.layers = scene::DEFAULT_LAYERS;
        node.visible = true;
    }
    template.meshes[0] = { .node = WIDE_JOINT_COUNT + 1, .geometry = wide, .material = fixture.plain };
    template.meshes[1] = { .node = WIDE_JOINT_COUNT + 2, .geometry = morphed, .material = fixture.plain };
    foreach (index, &skin : template.skins) {
        skin.mesh_node = WIDE_JOINT_COUNT + 1 + (uint)index;
        skin.skeleton = skeleton_id;
        skin.joint_nodes = alloc::new_array(assets.allocator, uint, WIDE_JOINT_COUNT);
        foreach (joint, &node : skin.joint_nodes) *node = (uint)joint + 1;
    }
    template.clips[0] = still;
    return assets.add_model_owned(&template);
}

fn void test_crowd_variants_draw_with_validation() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    enable_motion_blur(&fixture, fixture.view)!!;
    ModelId model = add_wide_crowd_model(&fixture)!!;
    ClipId still = fixture.assets.model(model).data.clips[0];

    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&scene);
    CrowdInstance[3] instances;
    foreach (index, &instance : instances) {
        Transform placement = maths::TRANSFORM_IDENTITY;
        placement.position = { (float)index - 1, 0, 0 };
        if (index == 1) placement.scale = { -1, 1, 1 };
        *instance = {
            .placement = placement,
            .pose      = { .clip = still, .speed = 1, .loop = true },
            .color     = { 1, 1, 1, 1 },
        };
    }
    Aabb pose_bounds = { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } };
    model::add_crowd(&fixture.assets, &scene, model, 4, pose_bounds, instances[..])!!;
    Node* sun = scene.add_light(light::directional({ 1, 1, 1 }, 2))!!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.3f, -1, -0.2f }.normalize(), { 0, 1, 0 });
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f))!!;
    camera_node.local.position = { 0, 0, 5 };

    for (uint frame = 0; frame < 2; frame++) {
        anim::crowd_update(&fixture.assets, &scene, 0.016f);
        scene.update_world();
        renderer.begin_frame()!!;
        renderer.render_view(&scene, camera_node, fixture.view)!!;
        renderer.finish_view(fixture.view)!!;
        renderer.end_frame()!!;
    }
    assert(renderer.deformation.crowd_palettes.len() == 1);
    Vec3 offset = { 65536, 0, 65536 };
    scene.root.local.position = offset;
    scene.update_world();
    for (uint frame = 0; frame < 3; frame++) {
        Vec3 reference = offset + (frame ? (Vec3){ 256, 0, -256 } : (Vec3){});
        renderer.begin_frame({ .time = 1.25, .reference_position = reference })!!;
        renderer.render_view(&scene, camera_node, fixture.view)!!;
        renderer.finish_view(fixture.view)!!;
        renderer.render_view(&scene, camera_node, fixture.second_view)!!;
        renderer.finish_view(fixture.second_view)!!;
        renderer.end_frame()!!;
        assert(renderer.deformation.crowd_palettes.len() == 1);
    }
    check_validation(renderer);
}
