module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::shader::compile;
import gpu;
import std::math;

const char[*] WEIGHTED_STAGE_FRAGMENT @private = $embed("weighted_stage.frag.glsl");

struct WeightedStageParams @private {
    Vec4 color;
}
$assert WeightedStageParams::size == 16;

fn char[]? compile_weighted_stage(String[] defines = {}) @private {
    return compile::compile_glsl(
        allocator: tmem,
        source:    (String)WEIGHTED_STAGE_FRAGMENT[..],
        stage:     ShaderStage.FRAGMENT,
        defines:   defines,
    );
}

fn uint count_weighted_stage_keys(Renderer* renderer, ShaderId shader, uint color_count, uint fragment_flags) @private {
    uint found;
    renderer.pipelines.pipelines.@each(; PipelineKey key, gpu::PipelineHandle pipeline) {
        bool same_shader = c3d::same_id(key.shader, shader);
        if (same_shader && key.color_count == color_count && key.fragment.flags == fragment_flags) found++;
    };
    return found;
}

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

fn void test_custom_stages_join_the_weighted_pass_only_with_a_weighted_form() @test {
    const uint VIEW_SIZE = 64;
    const float QUAD_YAW = 0.6f;
    const uint WEIGHTED_COLOR_TARGETS = 2;
    const uint SORTED_COLOR_TARGETS = 1;

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

    uint weighted = shader::SHADER_FLAG_WEIGHTED_BLEND;
    uint traced = shader::SHADER_FLAG_RT_SHADOWS;
    if (!renderer.caps.ray_queries.enabled) traced |= shader::SHADER_FLAG_SCENE_TRACE_BVH;

    ShaderId with_forms;
    ShaderId shaded_only;
    ShaderId without_forms;
    @pool() {
        String[4] walked_defines = { "DEPTH_READ", "WEIGHTED_BLEND", "RT_SHADOWS", "SCENE_TRACE_BVH" };
        char[] plain = compile_weighted_stage({ "DEPTH_READ" })!!;
        char[] shaded = compile_weighted_stage({ "DEPTH_READ", "WEIGHTED_BLEND" })!!;
        asset::ShaderDesc complete = {
            .fragment          = plain,
            .weighted_fragment = {
                .shaded = shaded,
                .traced = {
                    .hardware = compile_weighted_stage({ "DEPTH_READ", "WEIGHTED_BLEND", "RT_SHADOWS" })!!,
                    .software = compile_weighted_stage(walked_defines[..])!!,
                },
            },
            .param_block_size  = WeightedStageParams::size,
            .scene_reads       = { .depth },
        };
        with_forms = assets.add_shader(&complete)!!;
        asset::ShaderDesc plain_and_shaded = {
            .fragment          = plain,
            .weighted_fragment = { .shaded = shaded },
            .param_block_size  = WeightedStageParams::size,
            .scene_reads       = { .depth },
        };
        shaded_only = assets.add_shader(&plain_and_shaded)!!;
        asset::ShaderDesc sorted_only = {
            .fragment         = compile_weighted_stage()!!,
            .param_block_size = WeightedStageParams::size,
        };
        without_forms = assets.add_shader(&sorted_only)!!;
    };

    GeometryId plane;
    @pool() {
        Geometry plane_geometry = geometry::plane(tmem, 1, 1);
        plane = assets.add_geometry(&plane_geometry)!!;
    };
    MaterialCommon opaque_common = material::MATERIAL_COMMON_DEFAULT;
    opaque_common.double_sided = true;
    MaterialCommon blend_common = opaque_common;
    blend_common.alpha_mode = AlphaMode.BLEND;
    blend_common.depth_write = false;
    MaterialId backdrop = assets.add_material(material::basic({ .color = { 0.1f, 0.2f, 0.3f, 1 } }, opaque_common))!!;
    ShaderId[3] shaders = { with_forms, shaded_only, without_forms };
    Vec4[3] colors = { { 0.9f, 0.2f, 0.1f, 0.5f }, { 0.2f, 0.8f, 0.3f, 0.5f }, { 0.1f, 0.3f, 0.9f, 0.5f } };
    MaterialId[3] materials;
    foreach (index, shader_id : shaders) {
        WeightedStageParams params = { .color = colors[index] };
        materials[index] = assets.add_material(material::custom(
            shader:      shader_id,
            param_block: material::@as_bytes(params),
            common:      blend_common,
        ))!!;
    }

    Quaternionf upright = maths::look_rotation({ 0, 1, 0 }, { 0, 0, 1 });
    Node* backdrop_node = scene.add_mesh(plane, backdrop)!!;
    backdrop_node.local.position = { 0, 0, -3 };
    backdrop_node.local.rotation = upright;
    backdrop_node.local.scale = { 4, 4, 4 };
    foreach (index, material_id : materials) {
        float yaw = index % 2 == 0 ? QUAD_YAW : -QUAD_YAW;
        Node* quad = scene.add_mesh(plane, material_id)!!;
        quad.local.position = { ((float)index - 1) * 0.5f, 0, 0 };
        quad.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, yaw) * upright;
    }
    Node* camera_node = scene.add_camera(camera::orthographic(2, 0.1f, 100))!!;
    camera_node.local.position = { 0, 0, 3 };
    scene.update_world();

    ViewId[3] views;
    ViewDesc view_desc;
    foreach (index, &view : views) {
        RenderTargetId target = render::create_render_target(
            renderer: &renderer,
            desc:     render::render_target_desc(VIEW_SIZE, VIEW_SIZE),
        )!!;
        view_desc = render::texture_view_desc(target);
        view_desc.transparency = index == 0 ? TransparencyMode.SORTED : TransparencyMode.WEIGHTED;
        view_desc.ray_tracing.shadows = index == 2;
        *view = render::create_view(&renderer, view_desc)!!;
    }

    uint[3] draws;
    uint[3] snapshots;
    for (uint frame = 0; frame < 2; frame++) {
        renderer.begin_frame()!!;
        foreach (index, view : views) {
            uint draws_before = renderer.stats.draws;
            uint snapshots_before = renderer.stats.scene_snapshots;
            renderer.render_view(&scene, camera_node, view)!!;
            renderer.finish_view(view)!!;
            draws[index] = renderer.stats.draws - draws_before;
            snapshots[index] = renderer.stats.scene_snapshots - snapshots_before;
        }
        renderer.end_frame()!!;
    }

    // Every view draws every stage; a weighted view with accumulated draws adds the composite.
    assert(draws[1] == draws[0] + 1 && draws[2] == draws[0] + 1);
    // The depth snapshot is taken ahead of the accumulation as ahead of the sorted draws.
    assert(snapshots[0] > 0 && snapshots[1] == snapshots[0] && snapshots[2] == snapshots[0]);
    assert(!renderer.views.get(views[0]).weighted_accum.texture.is_valid());
    assert(renderer.views.get(views[1]).weighted_accum.texture.is_valid());
    assert(renderer.views.get(views[2]).weighted_accum.texture.is_valid());

    // A shader's weighted and sorted pipelines coexist; each stage owns the pipelines its forms allow.
    assert(count_weighted_stage_keys(&renderer, with_forms, SORTED_COLOR_TARGETS, 0) == 1);
    assert(count_weighted_stage_keys(&renderer, with_forms, WEIGHTED_COLOR_TARGETS, weighted) == 1);
    assert(count_weighted_stage_keys(&renderer, with_forms, WEIGHTED_COLOR_TARGETS, weighted | traced) == 1);
    assert(count_weighted_stage_keys(&renderer, shaded_only, SORTED_COLOR_TARGETS, 0) == 1);
    assert(count_weighted_stage_keys(&renderer, shaded_only, WEIGHTED_COLOR_TARGETS, weighted) == 1);
    assert(count_weighted_stage_keys(&renderer, shaded_only, WEIGHTED_COLOR_TARGETS, weighted | traced) == 0);
    assert(count_weighted_stage_keys(&renderer, without_forms, SORTED_COLOR_TARGETS, 0) == 1);
    assert(count_weighted_stage_keys(&renderer, without_forms, WEIGHTED_COLOR_TARGETS, weighted) == 0);

    // A replacement without weighted forms retires the weighted pipelines; the draw falls back to sorted.
    asset::ShaderDesc sorted_only = {
        .fragment         = assets.shader(with_forms).desc.fragment,
        .param_block_size = WeightedStageParams::size,
        .scene_reads      = { .depth },
    };
    assets.replace_shader(with_forms, &sorted_only)!!;
    renderer.begin_frame()!!;
    renderer.render_view(&scene, camera_node, views[1])!!;
    renderer.finish_view(views[1])!!;
    renderer.render_view(&scene, camera_node, views[2])!!;
    renderer.finish_view(views[2])!!;
    renderer.end_frame()!!;
    assert(count_weighted_stage_keys(&renderer, with_forms, WEIGHTED_COLOR_TARGETS, weighted) == 0);
    assert(count_weighted_stage_keys(&renderer, with_forms, WEIGHTED_COLOR_TARGETS, weighted | traced) == 0);
    assert(count_weighted_stage_keys(&renderer, with_forms, SORTED_COLOR_TARGETS, 0) == 1);

    render::wait_frames(&renderer)!!;
    DebugEntry[render::DEBUG_LOG_ENTRIES] entries;
    usz count = renderer.log.recent(entries[..]);
    foreach (entry : entries[:count]) {
        if (!entry.category.backend || !entry.category.validation) continue;
        assert(entry.severity != gpu::DebugMessageSeverity.ERROR);
        assert(entry.severity != gpu::DebugMessageSeverity.WARNING);
    }
}
