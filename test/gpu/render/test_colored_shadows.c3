module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import gpu;
import std::math;

fn void test_colored_shadows_toggle_allocates_once_and_costs_nothing_while_off() @test {
    const uint VIEW_SIZE = 64;
    const uint SHADOW_RESOLUTION = 256;

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Renderer renderer = render::create_renderer(
        allocator: mem,
        assets:    &assets,
        desc:      {
            .validation        = true,
            .application_name  = "render_acceptance",
            .shadow_resolution = SHADOW_RESOLUTION,
        },
    )!!;
    defer render::destroy_renderer(&renderer);

    GeometryId plane;
    @pool() {
        Geometry plane_geometry = geometry::plane(tmem, 1, 1);
        plane = assets.add_geometry(&plane_geometry)!!;
    };
    MaterialCommon blend_common = material::MATERIAL_COMMON_DEFAULT;
    blend_common.alpha_mode = AlphaMode.BLEND;
    blend_common.double_sided = true;
    StandardParams pane_params = material::STANDARD_PARAMS_DEFAULT;
    pane_params.base_color = { 0.9f, 0.2f, 0.2f, 0.5f };
    MaterialId ground_material = assets.add_material(material::standard())!!;
    MaterialId pane_material = assets.add_material(material::standard(pane_params, blend_common))!!;

    Node* ground = scene.add_mesh(plane, ground_material)!!;
    ground.local.scale = { 8, 1, 8 };
    Node* pane = scene.add_mesh(plane, pane_material)!!;
    pane.local.position = { 0, 1.5f, 0 };
    Light sun = light::directional({ 1, 1, 1 }, 3);
    sun.shadow.max_distance = 30;
    Node* sun_node = scene.add_light(sun)!!;
    Vec3 sun_travel = { 0.2f, -1, -0.3f };
    sun_node.local.rotation = maths::look_rotation(sun_travel.normalize(), { 0, 1, 0 });
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f))!!;
    camera_node.local.position = { 0, 4, 5 };
    Vec3 camera_travel = { 0, -0.6f, -0.8f };
    camera_node.local.rotation = maths::look_rotation(camera_travel.normalize(), { 0, 1, 0 });
    scene.update_world();

    RenderTargetId target = render::create_render_target(
        renderer: &renderer,
        desc:     render::render_target_desc(VIEW_SIZE, VIEW_SIZE),
    )!!;
    ViewId view = render::create_view(&renderer, render::texture_view_desc(target))!!;

    bool[6] colored_steps = { false, true, false, true, true, false };
    uint[6] draws;
    gpu::TextureHandle transmittance;
    gpu::TextureHandle depth;
    ulong pipeline_calls;
    foreach (step, colored : colored_steps) {
        renderer.set_colored_shadows(colored);
        renderer.begin_frame()!!;
        uint draws_before = renderer.stats.draws;
        renderer.render_view(&scene, camera_node, view)!!;
        renderer.finish_view(view)!!;
        draws[step] = renderer.stats.draws - draws_before;
        renderer.end_frame()!!;

        ColoredShadows* images = &renderer.shadow_atlas.colored;
        if (step == 0) assert(!images.transmittance.is_valid() && !images.depth.is_valid());
        if (step == 1) {
            assert(images.transmittance.is_valid() && images.depth.is_valid());
            assert(images.layers.len == renderer.max_shadow_layers);
            transmittance = images.transmittance;
            depth = images.depth;
            pipeline_calls = renderer.pipelines.creations.calls;
        }
        if (step > 1) {
            // Disabling keeps the images; enabling again reuses them and every pipeline.
            assert(images.transmittance == transmittance && images.depth == depth);
            assert(renderer.pipelines.creations.calls == pipeline_calls);
        }
    }

    // The translucent depth and transmittance passes add draws while on and none while off.
    assert(draws[1] > draws[0]);
    assert(draws[2] == draws[0] && draws[5] == draws[0]);
    assert(draws[3] == draws[1] && draws[4] == draws[1]);

    render::wait_frames(&renderer)!!;
    DebugEntry[render::DEBUG_LOG_ENTRIES] entries;
    usz count = renderer.log.recent(entries[..]);
    foreach (entry : entries[:count]) {
        if (!entry.category.backend || !entry.category.validation) continue;
        assert(entry.severity != gpu::DebugMessageSeverity.ERROR);
        assert(entry.severity != gpu::DebugMessageSeverity.WARNING);
    }
}

fn void test_forward_and_deferred_views_share_one_colored_shadow_set() @test {
    const uint VIEW_SIZE = 64;
    const uint SHADOW_RESOLUTION = 256;

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Renderer renderer = render::create_renderer(
        allocator: mem,
        assets:    &assets,
        desc:      {
            .validation        = true,
            .application_name  = "render_acceptance",
            .shadow_resolution = SHADOW_RESOLUTION,
        },
    )!!;
    defer render::destroy_renderer(&renderer);

    GeometryId plane;
    @pool() {
        Geometry plane_geometry = geometry::plane(tmem, 1, 1);
        plane = assets.add_geometry(&plane_geometry)!!;
    };
    MaterialCommon glass_common = material::MATERIAL_COMMON_DEFAULT;
    glass_common.double_sided = true;
    PhysicalParams glass = material::PHYSICAL_PARAMS_DEFAULT;
    glass.standard.base_color = { 0.4f, 0.8f, 0.5f, 1 };
    glass.standard.roughness = 0.1f;
    glass.transmission = 1;
    glass.thickness = 0.5f;
    glass.attenuation_color = { 0.9f, 0.5f, 0.3f };
    glass.attenuation_distance = 1;
    MaterialId ground_material = assets.add_material(material::standard())!!;
    MaterialId glass_material = assets.add_material(material::physical(glass, glass_common))!!;

    Node* ground = scene.add_mesh(plane, ground_material)!!;
    ground.local.scale = { 8, 1, 8 };
    Node* slab = scene.add_mesh(plane, glass_material)!!;
    slab.local.position = { 0, 1.5f, 0 };
    Light sun = light::directional({ 1, 1, 1 }, 3);
    sun.shadow.max_distance = 30;
    Node* sun_node = scene.add_light(sun)!!;
    Vec3 sun_travel = { 0.2f, -1, -0.3f };
    sun_node.local.rotation = maths::look_rotation(sun_travel.normalize(), { 0, 1, 0 });
    Camera lens = camera::perspective_deg(60, 0.1f);
    lens.aspect = 1;
    Node* camera_node = scene.add_camera(lens)!!;
    camera_node.local.position = { 0, 4, 5 };
    Vec3 camera_travel = { 0, -0.6f, -0.8f };
    camera_node.local.rotation = maths::look_rotation(camera_travel.normalize(), { 0, 1, 0 });
    scene.update_world();

    ViewId[2] views;
    ShadingPath[2] paths = { ShadingPath.FORWARD, ShadingPath.DEFERRED };
    foreach (index, &view : views) {
        RenderTargetId target = render::create_render_target(
            renderer: &renderer,
            desc:     render::render_target_desc(VIEW_SIZE, VIEW_SIZE),
        )!!;
        ViewDesc desc = render::texture_view_desc(target);
        desc.shading = paths[index];
        *view = render::create_view(&renderer, desc)!!;
    }

    renderer.set_colored_shadows(true);
    renderer.begin_frame()!!;
    foreach (view : views) {
        renderer.render_view(&scene, camera_node, view)!!;
        renderer.finish_view(view)!!;
    }
    renderer.end_frame()!!;

    assert(renderer.stats.shadow_sets_recorded == 1 && renderer.stats.shadow_sets_shared == 1);
    assert(renderer.shadow_atlas.colored.transmittance.is_valid() && renderer.shadow_atlas.colored.depth.is_valid());

    render::wait_frames(&renderer)!!;
    DebugEntry[render::DEBUG_LOG_ENTRIES] entries;
    usz count = renderer.log.recent(entries[..]);
    foreach (entry : entries[:count]) {
        if (!entry.category.backend || !entry.category.validation) continue;
        assert(entry.severity != gpu::DebugMessageSeverity.ERROR);
        assert(entry.severity != gpu::DebugMessageSeverity.WARNING);
    }
}
