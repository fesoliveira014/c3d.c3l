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
import c3d::shader::compile;
import std::math;

const uint BLEND_TARGET_SIZE @private = 32;
const uint BLEND_STATS_FRAMES @private = render::FRAMES_IN_FLIGHT + 1; // cull counters publish when a frame slot is reused
const float BLEND_PIXEL_TOLERANCE @private = 0.002f;
const Vec4 BLEND_BACKGROUND @private = { 0.1f, 0.2f, 0.3f, 1 };
const Vec4 BLEND_SOURCE @private = { 0.8f, 0.4f, 0.2f, 0.25f };
const char[*] MATERIAL_BLEND_FRAGMENT @private = $embed("material_blend.frag.glsl");

struct MaterialBlendScene @private {
    Scene      scene;
    Node*      camera;
    GeometryId plane;
}

struct MaterialBlendView @private {
    RenderTargetId target;
    ViewId         view;
}

struct MaterialBlendParams @private {
    Vec4 color;
}
$assert MaterialBlendParams::size == 16;
$assert $reflect(MaterialBlendParams.color).offset == 0;

fn Node*? add_material_blend_plane(MaterialBlendScene* target, MaterialId material_id, Vec3 position) @private {
    Node* node = target.scene.add_mesh(target.plane, material_id)!;
    node.local.position = position;
    node.local.rotation = maths::look_rotation({ 0, 1, 0 }, { 0, 0, 1 });
    target.scene.get(node, Mesh).cast_shadow = false;
    return node;
}

fn MaterialBlendScene? create_material_blend_scene(Fixture* fixture) @private {
    MaterialBlendScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    @pool() {
        Geometry plane = geometry::plane(tmem, 4, 4);
        result.plane = fixture.assets.add_geometry(&plane)!;
    };
    result.camera = result.scene.add_camera(camera::orthographic(2, 0.1f, 100))!;
    result.camera.local.position = { 0, 0, 3 };

    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.double_sided = true;
    MaterialId background = fixture.assets.add_material(material::basic({ .color = BLEND_BACKGROUND }, common))!;
    add_material_blend_plane(&result, background, { 0, 0, -5 })!;
    result.scene.update_world();
    return result;
}

fn MaterialId? add_material_blend(
    Fixture* fixture,
    Vec4 color,
    BlendMode mode = BlendMode.PREMULTIPLIED_ALPHA,
) @private {
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    common.blend_mode = mode;
    common.double_sided = true;
    return fixture.assets.add_material(material::basic({ .color = color }, common));
}

fn MaterialBlendView? create_material_blend_view(Fixture* fixture) @private {
    MaterialBlendView result;
    result.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(BLEND_TARGET_SIZE, BLEND_TARGET_SIZE, PixelFormat.RGBA32_FLOAT),
    )!;
    defer catch render::destroy_render_target(&fixture.renderer, result.target)!!;
    ViewDesc desc = render::texture_view_desc(result.target);
    desc.post.anti_aliasing = AntiAliasing.NONE;
    desc.depth_prepass = false;
    result.view = render::create_view(&fixture.renderer, desc)!;
    return result;
}

fn void destroy_material_blend_view(Fixture* fixture, MaterialBlendView* blend_view) @private {
    render::destroy_view(&fixture.renderer, blend_view.view)!!;
    render::destroy_render_target(&fixture.renderer, blend_view.target)!!;
}

fn Vec4[]? render_material_blend_pixels(
    Fixture* fixture,
    MaterialBlendScene* target,
    MaterialBlendView* blend_view,
    uint frames = 1,
) @private {
    target.scene.update_world();
    for (uint frame = 0; frame < frames; frame++) {
        fixture.renderer.begin_frame()!;
        defer catch render::abort_frame(&fixture.renderer);
        fixture.renderer.render_view(&target.scene, target.camera, blend_view.view)!;
        fixture.renderer.finish_view(blend_view.view)!;
        fixture.renderer.end_frame()!;
    }
    return read_float_target(fixture, blend_view.target);
}

fn Vec4? render_material_blend_center(
    Fixture* fixture,
    MaterialBlendScene* target,
    MaterialBlendView* blend_view,
) @private {
    Vec4[] pixels = render_material_blend_pixels(fixture, target, blend_view)!;
    defer free(pixels);
    return pixels[(BLEND_TARGET_SIZE / 2) * BLEND_TARGET_SIZE + BLEND_TARGET_SIZE / 2];
}

fn void check_material_blend_pixel(Vec4 found, Vec4 expected) @private {
    for (uint channel = 0; channel < 4; channel++) {
        assert(math::abs(found[channel] - expected[channel]) <= BLEND_PIXEL_TOLERANCE);
    }
}

fn MaterialId? add_custom_material_blend(Fixture* fixture, Vec4 color) @private {
    @pool() {
        ShaderDesc desc = {
            .fragment = compile::compile_glsl(tmem, (String)MATERIAL_BLEND_FRAGMENT[..], ShaderStage.FRAGMENT)!,
            .param_block_size = MaterialBlendParams::size,
        };
        ShaderId shader = fixture.assets.add_shader(&desc)!;
        MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
        common.alpha_mode = AlphaMode.BLEND;
        common.blend_mode = BlendMode.ADDITIVE;
        common.double_sided = true;
        MaterialBlendParams params = { .color = color };
        return fixture.assets.add_material(material::custom(
            shader: shader,
            param_block: material::@as_bytes(params),
            common: common,
        ));
    };
}

fn void test_additive_rgb_preserves_destination_alpha() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    MaterialBlendScene target = create_material_blend_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    MaterialBlendView blend_view = create_material_blend_view(&fixture)!!;
    defer destroy_material_blend_view(&fixture, &blend_view);

    Vec4 background = render_material_blend_center(&fixture, &target, &blend_view)!!;
    check_material_blend_pixel(background, BLEND_BACKGROUND);
    MaterialId additive = add_material_blend(&fixture, BLEND_SOURCE, BlendMode.ADDITIVE)!!;
    add_material_blend_plane(&target, additive, {})!!;
    add_material_blend_plane(&target, additive, {})!!;
    check_material_blend_pixel(render_material_blend_center(&fixture, &target, &blend_view)!!,
        { 0.5f, 0.4f, 0.4f, background.w });

    fixture.assets.material(additive).data.basic.color.w = 0;
    fixture.assets.mark_material_dirty(additive);
    check_material_blend_pixel(render_material_blend_center(&fixture, &target, &blend_view)!!, background);
    check_validation(&fixture.renderer);
}

fn void test_switching_blend_modes_updates_graphics_state() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    MaterialBlendScene target = create_material_blend_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    MaterialBlendView blend_view = create_material_blend_view(&fixture)!!;
    defer destroy_material_blend_view(&fixture, &blend_view);

    Vec4 background = render_material_blend_center(&fixture, &target, &blend_view)!!;
    MaterialId red = add_material_blend(&fixture, { 0.8f, 0, 0, 0.25f }, BlendMode.ADDITIVE)!!;
    MaterialId green = add_material_blend(&fixture, { 0, 0.6f, 0, 0.5f })!!;
    MaterialId blue = add_material_blend(&fixture, { 0, 0, 0.4f, 0.5f }, BlendMode.ADDITIVE)!!;
    add_material_blend_plane(&target, red, { 0, 0, -2 })!!;
    add_material_blend_plane(&target, green, { 0, 0, -1 })!!;
    add_material_blend_plane(&target, blue, {})!!;
    check_material_blend_pixel(render_material_blend_center(&fixture, &target, &blend_view)!!,
        { 0.15f, 0.4f, 0.35f, 0.5f + background.w * 0.5f });
    check_validation(&fixture.renderer);
}

fn void test_additive_instances_share_the_blend_contract() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    MaterialBlendScene target = create_material_blend_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    MaterialBlendView blend_view = create_material_blend_view(&fixture)!!;
    defer destroy_material_blend_view(&fixture, &blend_view);

    Vec4 background = render_material_blend_center(&fixture, &target, &blend_view)!!;
    MaterialId additive = add_material_blend(&fixture, BLEND_SOURCE, BlendMode.ADDITIVE)!!;
    Node* node = target.scene.add_instanced_mesh(target.plane, additive, 2)!!;
    target.scene.resize_instances(node, 2)!!;
    InstancedMesh* batch = target.scene.get(node, InstancedMesh);
    foreach (&transform : batch.transforms[:2]) {
        transform.rotation = maths::look_rotation({ 0, 1, 0 }, { 0, 0, 1 });
    }
    target.scene.mark_instances_dirty(node);
    bool[2] culling_modes = { true, false };
    foreach (culling : culling_modes) {
        ViewDesc desc = fixture.renderer.views.get(blend_view.view).desc;
        desc.instance_culling = culling;
        render::configure_view(&fixture.renderer, blend_view.view, desc)!!;
        Vec4[] pixels = render_material_blend_pixels(
            fixture: &fixture,
            target: &target,
            blend_view: &blend_view,
            frames: BLEND_STATS_FRAMES,
        )!!;
        defer free(pixels);
        Vec4 center = pixels[(BLEND_TARGET_SIZE / 2) * BLEND_TARGET_SIZE + BLEND_TARGET_SIZE / 2];
        check_material_blend_pixel(center, { 0.5f, 0.4f, 0.4f, background.w });
        assert(fixture.renderer.stats.instances_visible == 2);
        assert(fixture.renderer.stats.sort_dispatches > 0);
    }
    check_validation(&fixture.renderer);
}

fn void test_additive_fog_attenuates_without_in_scatter() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    MaterialBlendScene target = create_material_blend_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    MaterialBlendView blend_view = create_material_blend_view(&fixture)!!;
    defer destroy_material_blend_view(&fixture, &blend_view);

    target.scene.ambient_color = { 0.3f, 0.6f, 0.9f };
    target.scene.ambient_intensity = 1;
    Node* fog = target.scene.add_node()!!;
    target.scene.add(fog, (HeightFog){ .density = 0.1f, .falloff = 0, .albedo = { 1, 1, 1 }, .max_distance = 100 });
    Vec4[] background = render_material_blend_pixels(&fixture, &target, &blend_view)!!;
    defer free(background);
    Vec3 source_color = { 0.8f, 0.4f, 0.2f };
    Vec3 expected = source_color * math::exp(-0.3f);
    uint left = (BLEND_TARGET_SIZE / 2) * BLEND_TARGET_SIZE + BLEND_TARGET_SIZE / 4;
    uint right = (BLEND_TARGET_SIZE / 2) * BLEND_TARGET_SIZE + 3 * BLEND_TARGET_SIZE / 4;

    MaterialId[2] visible = {
        add_material_blend(&fixture, { 0.8f, 0.4f, 0.2f, 1 }, BlendMode.ADDITIVE)!!,
        add_custom_material_blend(&fixture, { 0.8f, 0.4f, 0.2f, 1 })!!,
    };
    MaterialId[2] transparent = {
        add_material_blend(&fixture, { 0.8f, 0.4f, 0.2f, 0 }, BlendMode.ADDITIVE)!!,
        add_custom_material_blend(&fixture, { 0.8f, 0.4f, 0.2f, 0 })!!,
    };
    Node* visible_plane = add_material_blend_plane(&target, visible[0], { -0.5f, 0, 0 })!!;
    Node* transparent_plane = add_material_blend_plane(&target, transparent[0], { 0.5f, 0, 0 })!!;
    visible_plane.local.scale = transparent_plane.local.scale = { 0.125f, 0.125f, 0.125f };
    for (uint mode = 0; mode < visible.len; mode++) {
        target.scene.get(visible_plane, Mesh).material = visible[mode];
        target.scene.get(transparent_plane, Mesh).material = transparent[mode];
        Vec4[] pixels = render_material_blend_pixels(&fixture, &target, &blend_view)!!;
        defer free(pixels);
        check_material_blend_pixel(pixels[left], background[left] + (Vec4){ expected.x, expected.y, expected.z, 0 });
        check_material_blend_pixel(pixels[right], background[right]);
    }
    check_validation(&fixture.renderer);
}

fn void test_default_blend_composition_remains_source_over() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    MaterialBlendScene target = create_material_blend_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    MaterialBlendView blend_view = create_material_blend_view(&fixture)!!;
    defer destroy_material_blend_view(&fixture, &blend_view);

    Vec4 background = render_material_blend_center(&fixture, &target, &blend_view)!!;
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    common.double_sided = true;
    MaterialId alpha = fixture.assets.add_material(material::basic({ .color = BLEND_SOURCE }, common))!!;
    add_material_blend_plane(&target, alpha, {})!!;
    check_material_blend_pixel(render_material_blend_center(&fixture, &target, &blend_view)!!,
        { 0.275f, 0.25f, 0.275f, 0.25f + background.w * 0.75f });
    check_validation(&fixture.renderer);
}
