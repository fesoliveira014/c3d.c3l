module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import gpu;
import std::math;

fn void test_weighted_view_allocates_its_targets_and_records_the_composite() @test {
    const uint VIEW_SIZE = 64;
    const float QUAD_YAW = 0.6f;

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Renderer renderer = render::create_renderer(
        allocator: mem,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "render_acceptance" },
    )!!;
    defer render::destroy_renderer(&renderer);

    GeometryId plane;
    @pool() {
        Geometry plane_geometry = geometry::plane(tmem, 1, 1);
        plane = assets.add_geometry(&plane_geometry)!!;
    };
    MaterialCommon opaque_common = material::MATERIAL_COMMON_DEFAULT;
    opaque_common.double_sided = true;
    MaterialCommon blend_common = opaque_common;
    blend_common.alpha_mode = AlphaMode.BLEND;
    MaterialCommon additive_common = blend_common;
    additive_common.blend_mode = BlendMode.ADDITIVE;
    MaterialId backdrop = assets.add_material(material::basic({ .color = { 0.1f, 0.2f, 0.3f, 1 } }, opaque_common))!!;
    MaterialId red = assets.add_material(material::basic({ .color = { 0.9f, 0.2f, 0.1f, 0.5f } }, blend_common))!!;
    MaterialId blue = assets.add_material(material::basic({ .color = { 0.1f, 0.3f, 0.9f, 0.5f } }, blend_common))!!;
    MaterialId glow = assets.add_material(material::basic({ .color = { 0.2f, 0.2f, 0.2f, 1 } }, additive_common))!!;

    Quaternionf upright = maths::look_rotation({ 0, 1, 0 }, { 0, 0, 1 });
    Node* backdrop_node = scene.add_mesh(plane, backdrop)!!;
    backdrop_node.local.position = { 0, 0, -3 };
    backdrop_node.local.rotation = upright;
    backdrop_node.local.scale = { 4, 4, 4 };
    Node* first_quad = scene.add_mesh(plane, red)!!;
    first_quad.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, QUAD_YAW) * upright;
    Node* second_quad = scene.add_mesh(plane, blue)!!;
    second_quad.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, -QUAD_YAW) * upright;
    Node* glow_quad = scene.add_mesh(plane, glow)!!;
    glow_quad.local.position = { 0, 0, 1 };
    glow_quad.local.rotation = upright;
    Node* camera_node = scene.add_camera(camera::orthographic(2, 0.1f, 100))!!;
    camera_node.local.position = { 0, 0, 3 };
    scene.update_world();

    RenderTargetId sorted_target = render::create_render_target(
        renderer: &renderer,
        desc:     render::render_target_desc(VIEW_SIZE, VIEW_SIZE),
    )!!;
    RenderTargetId weighted_target = render::create_render_target(
        renderer: &renderer,
        desc:     render::render_target_desc(VIEW_SIZE, VIEW_SIZE),
    )!!;
    ViewId sorted_view = render::create_view(&renderer, render::texture_view_desc(sorted_target))!!;
    ViewDesc weighted_desc = render::texture_view_desc(weighted_target);
    weighted_desc.transparency = TransparencyMode.WEIGHTED;
    ViewId weighted_view = render::create_view(&renderer, weighted_desc)!!;

    renderer.begin_frame()!!;
    uint draws_before = renderer.stats.draws;
    renderer.render_view(&scene, camera_node, sorted_view)!!;
    renderer.finish_view(sorted_view)!!;
    uint sorted_draws = renderer.stats.draws - draws_before;
    draws_before = renderer.stats.draws;
    renderer.render_view(&scene, camera_node, weighted_view)!!;
    renderer.finish_view(weighted_view)!!;
    uint weighted_draws = renderer.stats.draws - draws_before;
    renderer.end_frame()!!;

    ViewRecord* sorted_record = renderer.views.get(sorted_view);
    ViewRecord* weighted_record = renderer.views.get(weighted_view);
    assert(!sorted_record.weighted_accum.texture.is_valid());
    assert(!sorted_record.weighted_revealage.texture.is_valid());
    assert(weighted_record.weighted_accum.texture.is_valid());
    assert(weighted_record.weighted_revealage.texture.is_valid());
    assert(weighted_record.weighted_accum.width == VIEW_SIZE);
    assert(weighted_record.weighted_revealage.height == VIEW_SIZE);
    assert(weighted_draws == sorted_draws + 1);

    render::wait_frames(&renderer)!!;
    DebugEntry[render::DEBUG_LOG_ENTRIES] entries;
    usz count = renderer.log.recent(entries[..]);
    foreach (entry : entries[:count]) {
        bool validation_error = entry.category.backend && entry.category.validation
            && entry.severity == gpu::DebugMessageSeverity.ERROR;
        assert(!validation_error);
    }
}

fn void test_transparency_mode_toggle_reuses_targets_and_pipelines_with_mirrored_meshes() @test {
    const uint VIEW_SIZE = 64;
    const uint CYCLES = 3;
    const float QUAD_YAW = 0.6f;

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Renderer renderer = render::create_renderer(
        allocator: mem,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "render_acceptance" },
    )!!;
    defer render::destroy_renderer(&renderer);

    GeometryId plane;
    @pool() {
        Geometry plane_geometry = geometry::plane(tmem, 1, 1);
        plane = assets.add_geometry(&plane_geometry)!!;
    };
    MaterialCommon blend_common = material::MATERIAL_COMMON_DEFAULT;
    blend_common.alpha_mode = AlphaMode.BLEND;
    MaterialId backdrop = assets.add_material(material::basic({ .color = { 0.1f, 0.2f, 0.3f, 1 } }))!!;
    MaterialId red = assets.add_material(material::basic({ .color = { 0.9f, 0.2f, 0.1f, 0.5f } }, blend_common))!!;
    MaterialId green = assets.add_material(material::basic({ .color = { 0.2f, 0.8f, 0.3f, 0.5f } }, blend_common))!!;

    Quaternionf upright = maths::look_rotation({ 0, 1, 0 }, { 0, 0, 1 });
    Node* backdrop_node = scene.add_mesh(plane, backdrop)!!;
    backdrop_node.local.position = { 0, 0, -3 };
    backdrop_node.local.rotation = upright;
    backdrop_node.local.scale = { 4, 4, 4 };
    Node* quad = scene.add_mesh(plane, red)!!;
    quad.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, QUAD_YAW) * upright;
    Node* mirrored = scene.add_mesh(plane, green)!!;
    mirrored.local.position = { 0.2f, 0, 0.5f };
    mirrored.local.rotation = upright;
    mirrored.local.scale = { -1, 1, 1 };
    Transform[2] panels = {
        { .position = { -0.4f, 0, 0.2f }, .rotation = upright, .scale = { 0.5f, 1, 0.5f } },
        { .position = { 0.4f, 0, -0.2f }, .rotation = upright, .scale = { 0.5f, 1, 0.5f } },
    };
    scene.add_instanced_mesh(
        geometry:   plane,
        material:   green,
        capacity:   panels.len,
        transforms: panels[..],
    )!!;
    Node* camera_node = scene.add_camera(camera::orthographic(2, 0.1f, 100))!!;
    camera_node.local.position = { 0, 0, 3 };
    scene.update_world();

    RenderTargetId target = render::create_render_target(
        renderer: &renderer,
        desc:     render::render_target_desc(VIEW_SIZE, VIEW_SIZE),
    )!!;
    ViewDesc desc = render::texture_view_desc(target);
    ViewId view = render::create_view(&renderer, desc)!!;

    gpu::TextureHandle accum_texture;
    gpu::TextureHandle revealage_texture;
    ulong pipeline_calls;
    for (uint cycle = 0; cycle < CYCLES; cycle++) {
        TransparencyMode[2] modes = { TransparencyMode.SORTED, TransparencyMode.WEIGHTED };
        foreach (mode : modes) {
            desc.transparency = mode;
            render::configure_view(&renderer, view, desc)!!;
            renderer.begin_frame()!!;
            renderer.render_view(&scene, camera_node, view)!!;
            renderer.finish_view(view)!!;
            renderer.end_frame()!!;

            ViewRecord* record = renderer.views.get(view);
            if (mode == TransparencyMode.WEIGHTED && cycle == 0) {
                accum_texture = record.weighted_accum.texture;
                revealage_texture = record.weighted_revealage.texture;
                assert(accum_texture.is_valid() && revealage_texture.is_valid());
            }
            if (cycle > 0 || mode == TransparencyMode.WEIGHTED) {
                assert(record.weighted_accum.texture == accum_texture);
                assert(record.weighted_revealage.texture == revealage_texture);
            }
        }
        // Both modes have rendered once after the first cycle, so no later frame creates a pipeline.
        if (cycle == 0) pipeline_calls = renderer.pipelines.creations.calls;
        assert(renderer.pipelines.creations.calls == pipeline_calls);
    }

    render::wait_frames(&renderer)!!;
    DebugEntry[render::DEBUG_LOG_ENTRIES] entries;
    usz count = renderer.log.recent(entries[..]);
    foreach (entry : entries[:count]) {
        bool validation_error = entry.category.backend && entry.category.validation
            && entry.severity == gpu::DebugMessageSeverity.ERROR;
        assert(!validation_error);
    }
}
