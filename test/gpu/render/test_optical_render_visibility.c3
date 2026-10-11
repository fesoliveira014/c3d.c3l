module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::render::post;
import c3d::scene;
import c3d::test::transparency_fixtures;
import gpu;
import std::math;

const uint OPTICAL_RENDER_EXTENT @private = 65;
const uint OPTICAL_RENDER_PIXELS @private = OPTICAL_RENDER_EXTENT * OPTICAL_RENDER_EXTENT;
const uint OPTICAL_RENDER_CENTER @private = (OPTICAL_RENDER_EXTENT / 2) * (OPTICAL_RENDER_EXTENT + 1);
const Vec3 OPTICAL_RENDER_RECEIVER @private = { 0.125f, 0.25f, -4 };
const Vec3 OPTICAL_RENDER_EYE @private = { 4, 0.25f, 0 };
const uint OPTICAL_RENDER_SHADOW_EXTENT @private = 128;

// Ratio tests observe the receiver directly; the camera ray misses the light-facing glass.
struct OpticalRenderFixture @private {
    AssetStore assets;
    Scene scene;
    Renderer renderer;
    Node* camera;
    Node* sun;
    Node* receiver;
    Node* caster;
    GeometryId glass_geometry;
    MaterialId glass_material;
    RenderTargetId target;
    ViewId view;
    bool hardware;
    bool ray_shadow;
}

enum OpticalRenderRoute @private {
    ATLAS,
    SOFTWARE,
    HARDWARE,
}

fn GeometryId? optical_render_quad(
    AssetStore* assets,
    float half_width,
    float z,
    Vec4 tint = { 1, 1, 1, 1 },
) @private {
    Vec3[4] positions = {
        { -half_width, -half_width, z }, { half_width, -half_width, z },
        { half_width, half_width, z }, { -half_width, half_width, z },
    };
    Vec3[4] normals = { { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 } };
    Vec2[4] uv = { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 0 } };
    Vec4[4] colors = { tint, tint, tint, tint };
    Geometry geometry = {
        .positions = positions[..],
        .normals = normals[..],
        .uv0 = uv[..],
        .colors = colors[..],
        .indices = transparency_fixtures::QUAD_INDICES[..],
    };
    geometry.finalize();
    return assets.add_geometry(&geometry);
}

fn PhysicalParams optical_render_glass_params() @private {
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.standard.base_color = { 0.25f, 0.5f, 0.75f, 0.5f };
    params.standard.metallic = 0;
    params.standard.roughness = 0;
    params.transmission = 1;
    params.ior = 1;
    params.specular = 0;
    return params;
}

fn OpticalSurface optical_render_reference(PhysicalParams params, Vec4 sampled = { 1, 1, 1, 1 }) @private {
    OpticalSurface surface = optical_default_surface();
    surface.base_coverage = params.standard.base_color * sampled;
    surface.factors = { params.transmission, params.standard.metallic, params.ior, params.specular };
    surface.specular_cosine = { params.specular_color.x, params.specular_color.y, params.specular_color.z, 1 };
    surface.attenuation_distance = {
        params.attenuation_color.x, params.attenuation_color.y, params.attenuation_color.z, params.attenuation_distance,
    };
    surface.normal_thickness = { 0, 0, 1, params.thickness };
    surface.model_scale = { 1, 1, 1, 0 };
    surface.flags = OPTICAL_ALPHA_BLEND;
    return surface;
}

fn transparency_fixtures::Color optical_render_expected(OpticalSurface surface) @private {
    transparency_fixtures::Color expected = optical_expected_surface(surface);
    foreach (&channel : expected) *channel = math::clamp(*channel, 0.0, 1.0);
    return expected;
}

fn void? create_optical_render_fixture(
    Allocator allocator,
    OpticalRenderFixture* fixture,
    OpticalRenderRoute route,
    uint trace_capacity = 0,
    uint group_capacity = 4,
    ShadingPath shading = ShadingPath.FORWARD,
) @private {
    fixture.assets = asset::create_asset_store(allocator, asset::default_asset_store_desc());
    defer catch asset::destroy_asset_store(&fixture.assets);
    fixture.scene = scene::create_scene(allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&fixture.scene);
    fixture.scene.ambient_intensity = 0;
    fixture.hardware = route == OpticalRenderRoute.HARDWARE;
    fixture.ray_shadow = route != OpticalRenderRoute.ATLAS;
    fixture.renderer = render::create_renderer(
        allocator: allocator,
        assets: &fixture.assets,
        desc: {
            .validation = true,
            .application_name = "optical_render_acceptance",
            .shadow_resolution = OPTICAL_RENDER_SHADOW_EXTENT,
            .max_shadow_layers = 1,
            .transmission_shadow_layers = group_capacity,
            .max_trace_instances = trace_capacity,
            .ray_queries = fixture.hardware,
        },
    )!;
    defer catch render::destroy_renderer(&fixture.renderer);
    assert(!fixture.hardware || fixture.renderer.caps.ray_queries.enabled);
    StandardParams receiver = material::STANDARD_PARAMS_DEFAULT;
    receiver.base_color = { 1, 1, 1, 1 };
    receiver.metallic = 0;
    receiver.roughness = 1;
    GeometryId receiver_geometry = optical_render_quad(&fixture.assets, 8, -4)!;
    MaterialId receiver_material = fixture.assets.add_material(material::standard(receiver))!;
    fixture.receiver = fixture.scene.add_mesh(receiver_geometry, receiver_material)!;
    fixture.scene.get(fixture.receiver, Mesh).cast_shadow = false;
    fixture.glass_geometry = optical_render_quad(&fixture.assets, 0.75f, -2)!;
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    fixture.glass_material = fixture.assets.add_material(material::physical(optical_render_glass_params(), common))!;
    fixture.caster = fixture.scene.add_mesh(fixture.glass_geometry, fixture.glass_material)!;
    Light light = light::directional({ 1, 1, 1 }, 3);
    light.shadow.cascades = 1;
    light.shadow.max_distance = 16;
    light.shadow.bias = 0;
    light.shadow.directional_normal_bias_texels = 0;
    light.shadow.ray_traced = fixture.ray_shadow;
    light.shadow.colored_transmission = false;
    fixture.sun = fixture.scene.add_light(light)!;
    fixture.camera = fixture.scene.add_camera(camera::orthographic(height: 0.125f, near: 0.1f, far: 16))!;
    fixture.camera.local.position = OPTICAL_RENDER_EYE;
    fixture.camera.local.rotation = maths::look_rotation(OPTICAL_RENDER_RECEIVER - OPTICAL_RENDER_EYE, { 0, 1, 0 });
    fixture.scene.update_world();
    fixture.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(OPTICAL_RENDER_EXTENT, OPTICAL_RENDER_EXTENT, PixelFormat.RGBA32_FLOAT),
    )!;
    ViewDesc view = render::texture_view_desc(fixture.target);
    view.shading = shading;
    view.post.anti_aliasing = AntiAliasing.NONE;
    view.post.grade.tonemap = Tonemap.NONE;
    view.depth_prepass = false;
    view.ray_tracing.shadows = fixture.ray_shadow;
    fixture.view = render::create_view(&fixture.renderer, view)!;
}

fn void destroy_optical_render_fixture(OpticalRenderFixture* fixture) @private {
    render::destroy_renderer(&fixture.renderer);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn void? optical_render_frame(OpticalRenderFixture* fixture) @private {
    fixture.scene.update_world();
    fixture.renderer.begin_frame()!;
    defer catch render::abort_frame(&fixture.renderer);
    fixture.renderer.render_view(&fixture.scene, fixture.camera, fixture.view)!;
    fixture.renderer.finish_view(fixture.view)!;
    fixture.renderer.end_frame()!;
}

fn Vec4[]? optical_render_pixels(OpticalRenderFixture* fixture) @private {
    optical_render_frame(fixture)!;
    Vec4[] pixels = mem::new_array(Vec4, OPTICAL_RENDER_PIXELS);
    defer catch free(pixels);
    fixture.renderer.read_render_target(fixture.target, ((char*)pixels.ptr)[:pixels.len * Vec4::size])!;
    return pixels;
}

fn Vec3 optical_render_visibility(Vec4[] actual, Vec4[] open) @private {
    Vec3 ratio;
    for (uint channel = 0; channel < 3; channel++) {
        assert(open[OPTICAL_RENDER_CENTER][channel] > 0.01f, "The receiver must carry direct light.");
        ratio[channel] = actual[OPTICAL_RENDER_CENTER][channel] / open[OPTICAL_RENDER_CENTER][channel];
    }
    return ratio;
}

fn void check_optical_render_visibility(Vec3 actual, transparency_fixtures::Color expected, String context) @private {
    for (uint channel = 0; channel < 3; channel++) {
        double error = math::abs((double)actual[channel] - expected[channel]);
        double bound = OPTICAL_ABSOLUTE_TOLERANCE + OPTICAL_RELATIVE_TOLERANCE * math::abs(expected[channel]);
        assert(math::is_finite(actual[channel]) && error <= bound,
            "%s channel=%s actual=%s expected=%s", context, channel, actual[channel], expected[channel]);
    }
}

fn void test_optical_render_visibility_tinted_surface_reaches_forward_and_deferred_on_all_three_routes() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    foreach (route : OpticalRenderRoute::values) {
        foreach (shading : (ShadingPath[2]){ FORWARD, DEFERRED }) {
            OpticalRenderFixture fixture;
            create_optical_render_fixture(
                allocator: &tracker,
                fixture: &fixture,
                route: route,
                shading: shading,
            )!!;
            defer destroy_optical_render_fixture(&fixture);
            Vec4[] baseline = optical_render_pixels(&fixture)!!;
            defer free(baseline);
            assert(!fixture.renderer.optical_shadow_atlas.opaque.texture.is_valid());
            assert(!fixture.renderer.optical_scene_trace.allocation.is_valid());
            fixture.scene.get(fixture.sun, Light).shadow.colored_transmission = true;
            fixture.renderer.prepare_scene(&fixture.scene)!!;
            Vec4[] colored = optical_render_pixels(&fixture)!!;
            defer free(colored);
            Vec3 actual = optical_render_visibility(colored, baseline);
            check_optical_render_visibility(
                actual,
                optical_render_expected(optical_render_reference(optical_render_glass_params())),
                "tinted surface",
            );
            assert(fixture.ray_shadow ? fixture.renderer.optical_scene_trace.allocation.is_valid()
                : fixture.renderer.optical_shadow_atlas.opaque.texture.is_valid());
        }
    }
}

fn void test_optical_render_visibility_trace_over_cap_is_dark_and_preserves_generic_rows() @test {
    foreach (route : (OpticalRenderRoute[2]){ SOFTWARE, HARDWARE }) {
        OpticalRenderFixture fixture;
        create_optical_render_fixture(
            allocator: mem,
            fixture: &fixture,
            route: route,
            trace_capacity: 1,
        )!!;
        defer destroy_optical_render_fixture(&fixture);
        fixture.scene.add_mesh(fixture.glass_geometry, fixture.glass_material)!!;
        Vec4[] baseline = optical_render_pixels(&fixture)!!;
        defer free(baseline);
        assert(fixture.renderer.scene_trace.baseline_count == 1);
        TraceInstance original = fixture.renderer.scene_trace.baseline[0];
        fixture.scene.get(fixture.sun, Light).shadow.colored_transmission = true;
        Vec4[] colored = optical_render_pixels(&fixture)!!;
        defer free(colored);
        Vec3 actual = optical_render_visibility(colored, baseline);
        assert(actual == (Vec3){}, "Optical over-cap must fail dark.");
        assert(fixture.renderer.optical_trace_overflow && fixture.renderer.stats.optical_trace_overflows > 0);
        assert(fixture.renderer.scene_trace.baseline_count == 1);
        assert(mem::equals(&original, &fixture.renderer.scene_trace.baseline[0], TraceInstance::size));
    }
}

fn void test_optical_render_visibility_final_surface_clamp_preserves_hdr_factors_and_tied_products() @test {
    foreach (route : OpticalRenderRoute::values) {
        OpticalRenderFixture fixture;
        create_optical_render_fixture(mem, &fixture, route)!!;
        defer destroy_optical_render_fixture(&fixture);
        Vec4[] baseline = optical_render_pixels(&fixture)!!;
        defer free(baseline);
        fixture.scene.get(fixture.sun, Light).shadow.colored_transmission = true;
        float[4] gains = { 2, 2, 1.5f, 1 };
        float[4] transmissions = { 1, 0.5f, 0.5f, 0.25f };
        float[4] coverages = { 1, 1, 1, 2 };
        for (uint row = 0; row < gains.len; row++) {
            Vec4[1] texel = { { gains[row], gains[row], gains[row], coverages[row] } };
            material::TextureDesc desc = {
                .width = 1, .height = 1, .layers = 1, .mip_levels = 1,
                .format = PixelFormat.RGBA32_FLOAT, .debug_name = "optical_hdr_gain",
            };
            TextureId map = fixture.assets.add_texture(desc, ((char*)&texel)[:Vec4::size])!!;
            PhysicalParams params = optical_render_glass_params();
            params.standard.base_color = { 1, 1, 1, 1 };
            params.standard.base_color_map = material::texture_slot(map);
            params.transmission = transmissions[row];
            MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
            common.alpha_mode = AlphaMode.BLEND;
            MaterialId material = fixture.assets.add_material(material::physical(params, common))!!;
            fixture.scene.get(fixture.caster, Mesh).material = material;
            Vec4[] colored = optical_render_pixels(&fixture)!!;
            defer free(colored);
            OpticalSurface surface = optical_render_reference(params, texel[0]);
            check_optical_render_visibility(
                optical_render_visibility(colored, baseline),
                optical_render_expected(surface),
                "HDR map/coverage",
            );
        }
        PhysicalParams params = optical_render_glass_params();
        params.standard.base_color = { 1, 1, 1, 1 };
        MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
        common.alpha_mode = AlphaMode.BLEND;
        MaterialId material = fixture.assets.add_material(material::physical(params, common))!!;
        GeometryId tinted = optical_render_quad(
            assets: &fixture.assets,
            half_width: 0.75f,
            z: -2,
            tint: { 2, 2, 2, 1 },
        )!!;
        fixture.scene.get(fixture.caster, Mesh).material = material;
        fixture.scene.get(fixture.caster, Mesh).geometry = tinted;
        Vec4[] vertex = optical_render_pixels(&fixture)!!;
        defer free(vertex);
        check_optical_render_visibility(optical_render_visibility(vertex, baseline), { 1, 1, 1 }, "vertex gain");
        fixture.caster.visible = false;
        Transform[1] transforms = { maths::TRANSFORM_IDENTITY };
        Vec4[1] colors = { { 2, 2, 2, 1 } };
        Node* batch = fixture.scene.add_instanced_mesh(
            geometry: fixture.glass_geometry,
            material: material,
            capacity: 1,
            transforms: transforms[..],
            colors: colors[..],
        )!!;
        Vec4[] instance = optical_render_pixels(&fixture)!!;
        defer free(instance);
        check_optical_render_visibility(optical_render_visibility(instance, baseline), { 1, 1, 1 }, "instance gain");
        batch.visible = false;
        fixture.caster.visible = true;
        fixture.scene.add_mesh(tinted, material)!!;
        Vec4[] tied = optical_render_pixels(&fixture)!!;
        defer free(tied);
        check_optical_render_visibility(optical_render_visibility(tied, baseline), { 1, 1, 1 }, "clamped ties");
    }
}
