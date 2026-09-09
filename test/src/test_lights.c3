module c3d::test::lights;

import c3d;
import c3d::light;
import c3d::camera;
import c3d::material;
import c3d::maths;
import c3d::render;
import c3d::scene;
import c3d::shader;
import std::math;
import gpu;

fn Frustum box_frustum() @local {
    return {
        .planes = {
            { .normal = { 1, 0, 0 }, .d = 1 },
            { .normal = { -1, 0, 0 }, .d = 1 },
            { .normal = { 0, 1, 0 }, .d = 1 },
            { .normal = { 0, -1, 0 }, .d = 1 },
            { .normal = { 0, 0, 1 }, .d = 1 },
            { .normal = { 0, 0, -1 }, .d = 1 },
        },
        .plane_count = 6,
    };
}

fn void test_sphere_culling_keeps_tangent_and_infinite_far() @test {
    Frustum frustum = box_frustum();
    assert(maths::frustum_intersects_sphere(&frustum, { .center = { 2, 0, 0 }, .radius = 1 }));
    assert(!maths::frustum_intersects_sphere(&frustum, { .center = { 2.01f, 0, 0 }, .radius = 1 }));
    assert(!maths::frustum_intersects_sphere(&frustum, { .center = { 0, 0, 10 }, .radius = 1 }));

    frustum.plane_count = 5;
    assert(maths::frustum_intersects_sphere(&frustum, { .center = { 0, 0, 10 }, .radius = 1 }));
}

fn void test_light_inclusion_precedes_budget_and_preserves_receiver_mask() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 8 });
    defer scene::destroy_scene(&scene);
    Node* hidden_parent = scene.add_node()!!;
    hidden_parent.visible = false;
    scene.add_light(light::point({ 1, 1, 1 }, 1), hidden_parent)!!;
    Node* off_layer = scene.add_light(light::point({ 1, 1, 1 }, 2))!!;
    off_layer.layers = 2;
    Light no_receivers = light::point({ 1, 1, 1 }, 3);
    no_receivers.layers = 0;
    scene.add_light(no_receivers)!!;
    scene.add_light(light::point({ 1, 1, 1 }, 0))!!;
    Node* outside = scene.add_light(light::point({ 1, 1, 1 }, 4, 1))!!;
    outside.local.position = { 10, 0, 0 };
    Light eligible = light::point({ 1, 1, 1 }, 5);
    eligible.layers = 3;
    scene.add_light(eligible)!!;
    scene.update_world();

    Frustum frustum = box_frustum();
    LightCounts counts;
    @pool() {
        LightGpu[] packed = render::extract_lights(
            allocator: tmem,
            scene: &scene,
            frustum: &frustum,
            view_layers: 1,
            capacity: 1,
            counts: &counts,
        );
        assert(packed.len == 1 && packed[0].color_intensity.w == 5);
        assert(packed[0].layers == 3);
        assert(counts.packed == 1 && counts.culled == 1 && counts.dropped == 0);
    };
}

fn void test_unbounded_and_directional_lights_survive_spatial_culling() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    Node* directional = scene.add_light(light::directional({ 1, 1, 1 }, 1))!!;
    directional.local.position = { 100, 0, 0 };
    Node* point = scene.add_light(light::point({ 1, 1, 1 }, 2))!!;
    point.local.position = { 100, 0, 0 };
    Node* spot = scene.add_light(light::spot(
        color: { 1, 1, 1 },
        intensity: 3,
        inner: 0.2f,
        outer: 0.5f,
    ))!!;
    spot.local.position = { 100, 0, 0 };
    Node* finite = scene.add_light(light::point({ 1, 1, 1 }, 4, 1))!!;
    finite.local.position = { 100, 0, 0 };
    scene.update_world();

    Frustum frustum = box_frustum();
    LightCounts counts;
    @pool() {
        LightGpu[] packed = render::extract_lights(
            allocator: tmem,
            scene: &scene,
            frustum: &frustum,
            view_layers: 1,
            capacity: 4,
            counts: &counts,
        );
        assert(packed.len == 3 && counts.culled == 1 && counts.dropped == 0);
        assert(packed[0].kind == (uint)LightKind.DIRECTIONAL.ordinal);
        assert(packed[1].kind == (uint)LightKind.POINT.ordinal);
        assert(packed[2].kind == (uint)LightKind.SPOT.ordinal);
    };
}

fn void test_light_budget_follows_current_component_order() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 3 });
    defer scene::destroy_scene(&scene);
    Node* first = scene.add_light(light::point({ 1, 1, 1 }, 1))!!;
    scene.add_light(light::point({ 1, 1, 1 }, 2))!!;
    scene.add_light(light::point({ 1, 1, 1 }, 3))!!;
    scene.update_world();

    Frustum frustum = box_frustum();
    LightCounts counts;
    @pool() {
        LightGpu[] packed = render::extract_lights(
            allocator: tmem,
            scene: &scene,
            frustum: &frustum,
            view_layers: 1,
            capacity: 2,
            counts: &counts,
        );
        assert(packed.len == 2 && counts.dropped == 1);
        assert(packed[0].color_intensity.w == 1 && packed[1].color_intensity.w == 2);
    };

    scene.remove(first);
    @pool() {
        LightGpu[] packed = render::extract_lights(
            allocator: tmem,
            scene: &scene,
            frustum: &frustum,
            view_layers: 1,
            capacity: 1,
            counts: &counts,
        );
        assert(packed.len == 1 && counts.packed == 1 && counts.dropped == 1);
        assert(packed[0].color_intensity.w == 3);
    };
}

fn void test_spot_world_pose_does_not_scale_range_or_intensity() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 2 });
    defer scene::destroy_scene(&scene);
    Node* parent = scene.add_node()!!;
    parent.local.position = { 4, 2, 3 };
    parent.local.scale = { 2, 2, 2 };
    parent.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI / 2);
    Node* node = scene.add_light(light::spot(
        color: { 0.25f, 0.5f, 1 },
        intensity: 7,
        inner: 0.2f,
        outer: 0.6f,
        range: 9,
    ), parent)!!;
    node.local.position = { 0, 0, -1 };
    scene.update_world();

    Frustum frustum = box_frustum();
    LightCounts counts;
    @pool() {
        LightGpu[] packed = render::extract_lights(
            allocator: tmem,
            scene: &scene,
            frustum: &frustum,
            view_layers: 1,
            capacity: 1,
            counts: &counts,
        );
        assert(packed.len == 1);
        assert((packed[0].position_range.xyz - (Vec3){ 2, 2, 3 }).length() < 0.0001f);
        assert((packed[0].direction_cos_outer.xyz - (Vec3){ -1, 0, 0 }).length() < 0.0001f);
        assert(packed[0].position_range.w == 9 && packed[0].color_intensity.w == 7);
        assert(math::abs(packed[0].cos_inner - math::cos(0.2f)) < 0.0001f);
        assert(math::abs(packed[0].direction_cos_outer.w - math::cos(0.6f)) < 0.0001f);
    };
}

fn void test_scene_light_capacity_does_not_add_partial_component() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);
    scene.add_light(light::directional({ 1, 1, 1 }, 1))!!;

    if (catch excuse = scene.add_light(light::point({ 1, 1, 1 }, 1))) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "Full scene accepted another light");
    }
    assert(scene.count(Light) == 1);
}

fn void test_material_packing_switches_active_union_arm() @test {
    char[render::MATERIAL_STRIDE] storage @align(16);
    char[] bytes = storage[..];
    Material material = material::basic({ .color = { 1, 0, 0, 1 } });
    render::write_material_block(bytes, &material, {});
    assert(((BasicMaterialGpu*)bytes.ptr).color.r == 1);

    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = { 0.2f, 0.4f, 0.6f, 0.3f };
    params.metallic = 0.25f;
    params.roughness = 0.75f;
    params.emissive = { 2, 3, 4 };
    params.emissive_strength = 5;
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.MASK;
    common.double_sided = true;
    common.alpha_cutoff = 0.4f;
    material = material::standard(params, common);
    render::write_material_block(bytes, &material, {});

    StandardMaterialGpu* standard = (StandardMaterialGpu*)bytes.ptr;
    assert(standard.kind == (uint)MaterialKind.STANDARD.ordinal);
    assert(standard.flags == 3 && standard.alpha_cutoff == 0.4f);
    assert(standard.metallic == 0.25f && standard.roughness == 0.75f);
    assert(standard.base_color.a == 0.3f && standard.emissive_strength.w == 5);
    assert(standard.emissive_strength.r == 2 && standard.emissive_strength.b == 4);

    material = material::basic({ .color = { 0, 1, 0, 1 } });
    render::write_material_block(bytes, &material, {});
    BasicMaterialGpu* basic = (BasicMaterialGpu*)bytes.ptr;
    assert(basic.kind == (uint)MaterialKind.BASIC.ordinal && basic.flags == 0);
    assert(basic.color.g == 1 && basic.map_present == 0);
}

fn void test_roots_preserve_light_and_receiver_data() @test {
    Camera camera = camera::perspective_deg(60, 0.1f);
    CameraMatrices matrices = camera::derive_matrices(camera, matrix::IDENTITY4, { 800, 600 });
    FrameRoot frame;
    render::write_frame_root(
        root: &frame,
        matrices: &matrices,
        camera: &camera,
        viewport: { 800, 600 },
        info: {},
        frame_index: 3,
        lights: (gpu::GpuAddress)4096,
        light_count: 2,
        ambient: { 0.1f, 0.2f, 0.3f, 0 },
    );
    assert(frame.lights == (gpu::GpuAddress)4096 && frame.light_count == 2);
    assert(frame.ambient == (Vec4){ 0.1f, 0.2f, 0.3f, 0 });

    DrawRoot draw;
    render::write_draw_root(
        root: &draw,
        world: matrix::IDENTITY4,
        frame: (gpu::GpuAddress)0,
        geometry: (gpu::GpuAddress)0,
        material: (gpu::GpuAddress)0,
        object_id: 7,
        layers: 0x80000002,
    );
    assert(draw.layers == 0x80000002 && draw.object_id == 7);
}

fn void test_light_receiver_mask_is_not_restricted_to_camera_bits() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);
    Light light = light::directional({ 1, 1, 1 }, 1);
    light.layers = 2;
    scene.add_light(light)!!;
    scene.update_world();

    Frustum frustum = box_frustum();
    LightCounts counts;
    @pool() {
        LightGpu[] packed = render::extract_lights(
            allocator: tmem,
            scene: &scene,
            frustum: &frustum,
            view_layers: 1,
            capacity: 1,
            counts: &counts,
        );
        assert(packed.len == 1 && packed[0].layers == 2);
        assert(counts.dropped == 0);
    };
}
