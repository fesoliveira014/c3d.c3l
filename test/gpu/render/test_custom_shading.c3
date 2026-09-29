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
import c3d::shader;
import c3d::shader::compile;
import gpu;
import std::io;
import std::math;

const char[*] TWIN_INCLUDE_SOURCE @private = $embed("../../../examples/shaders/custom/standard_twin.glsl");
const char[*] TWIN_FRAGMENT_SOURCE @private = $embed("../../../examples/shaders/custom/standard_twin.frag.glsl");
const char[*] TWIN_GBUFFER_SOURCE @private = $embed("../../../examples/shaders/custom/standard_twin_gbuffer.frag.glsl");
const ShaderInclude[1] TWIN_INCLUDES @private = {
    { .name = "custom/standard_twin.glsl", .text = (String)TWIN_INCLUDE_SOURCE[..] },
};
const uint TWIN_TARGET_SIZE @private = 64;
const float TWIN_RELATIVE_TOLERANCE @private = 1e-3f; // one RGBA16_FLOAT step of the working image is 2^-10 relative
const float TWIN_ABSOLUTE_TOLERANCE @private = 1e-5f;
const float TWIN_SPHERE_RADIUS @private = 0.6f;
const Vec3 TWIN_SPHERE_POSITION @private = { 0, 0.6f, 0 };
const float TWIN_GROUND_SIZE @private = 10;
const Vec3 TWIN_CAMERA_POSITION @private = { 0, 0.6f, 3 }; // looks down -Z, so the sphere centre is the image centre
const Vec3 TWIN_SUN_DIRECTION @private = { 0.4f, -0.8f, 0.45f }; // lays the sphere's shadow in front of it, in view
const Vec3[2] TWIN_LAMP_POSITIONS @private = { { -1.2f, 1.2f, 0.8f }, { 1.2f, 1.2f, 0.8f } };
const float TWIN_LAMP_INTENSITY @private = 2;
const float TWIN_LAMP_RANGE @private = 4;
const StandardParams TWIN_SPHERE_PARAMS @private = {
    .base_color        = { 0.85f, 0.3f, 0.2f, 1 },
    .metallic          = 0.25f,
    .roughness         = 0.4f,
    .emissive          = { 0.05f, 0.02f, 0 },
    .emissive_strength = 1,
};

struct TwinParams @private {
    Vec4 base_color;
    Vec4 metallic_roughness_occlusion;
    Vec4 emissive;
}
$assert TwinParams::size == 48;

struct TwinScene @private {
    Scene      scene;
    Node*      camera;
    Node*      sphere;
    Node*      ground;
    MaterialId sphere_standard;
    MaterialId ground_standard;
    MaterialId sphere_twin;
    MaterialId ground_twin;
}

struct TwinReadings @private {
    Vec4[] standard;
    Vec4[] twin;
}

fn char[]? compile_twin(Allocator allocator, String source, String[] defines = {}) @private {
    return compile::compile_glsl(
        allocator: allocator,
        source:    source,
        stage:     ShaderStage.FRAGMENT,
        defines:   defines,
        includes:  TWIN_INCLUDES[..],
    );
}

fn asset::ShaderDesc? twin_shader_desc(Allocator allocator, bool traced) @private {
    asset::ShaderDesc desc = {
        .fragment         = compile_twin(allocator, (String)TWIN_FRAGMENT_SOURCE[..])!,
        .gbuffer          = compile_twin(allocator, (String)TWIN_GBUFFER_SOURCE[..])!,
        .param_block_size = TwinParams::size,
    };
    if (traced) {
        desc.traced_fragment = {
            .hardware = compile_twin(allocator, (String)TWIN_FRAGMENT_SOURCE[..], { "RT_SHADOWS" })!,
            .software = compile_twin(allocator, (String)TWIN_FRAGMENT_SOURCE[..], { "RT_SHADOWS", "SCENE_TRACE_BVH" })!,
        };
    }
    return desc;
}

fn ShaderId? add_twin_shader(Fixture* fixture, bool traced) @private {
    @pool() {
        asset::ShaderDesc desc = twin_shader_desc(tmem, traced)!;
        return fixture.assets.add_shader(&desc);
    };
}

fn MaterialId? twin_material(Fixture* fixture, ShaderId shader, StandardParams params) @private {
    Vec3 emissive = params.emissive * params.emissive_strength;
    TwinParams twin = {
        .base_color                   = params.base_color,
        .metallic_roughness_occlusion = { params.metallic, params.roughness, 1, 0 },
        .emissive                     = { emissive.x, emissive.y, emissive.z, 0 },
    };
    return fixture.assets.add_material(material::custom(shader, material::@as_bytes(twin)));
}

fn TwinScene? create_twin_scene(Fixture* fixture) @private {
    TwinScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);

    @pool() {
        char[] pixels = alloc::new_array(tmem, char, (usz)SKY_WIDTH * SKY_HEIGHT * 4 * float::size);
        write_sky(pixels, SKY_RADIANCE);
        material::TextureDesc sky_desc = material::texture_2d_desc(
            width: SKY_WIDTH,
            height: SKY_HEIGHT,
            format: RGBA32_FLOAT,
            debug_name: "twin_sky",
        );
        TextureId sky = fixture.assets.add_texture(sky_desc, pixels)!;
        result.scene.environment = fixture.assets.add_environment(light::texture_environment(sky))!;
    };

    ShaderId shader = add_twin_shader(fixture, false)!;
    result.sphere_standard = fixture.assets.add_material(material::standard(TWIN_SPHERE_PARAMS))!;
    result.ground_standard = fixture.assets.add_material(material::standard(SHADOW_GROUND_PARAMS))!;
    result.sphere_twin = twin_material(fixture, shader, TWIN_SPHERE_PARAMS)!;
    result.ground_twin = twin_material(fixture, shader, SHADOW_GROUND_PARAMS)!;

    GeometryId sphere = add_sphere(fixture, TWIN_SPHERE_RADIUS)!;
    result.sphere = result.scene.add_mesh(sphere, result.sphere_standard, name: "sphere")!;
    result.sphere.local.position = TWIN_SPHERE_POSITION;
    GeometryId ground = add_plane(fixture, TWIN_GROUND_SIZE)!;
    result.ground = result.scene.add_mesh(ground, result.ground_standard, name: "ground")!;
    Node* sun = result.scene.add_light(light::directional({ 1, 1, 1 }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation(TWIN_SUN_DIRECTION.normalize(), { 0, 1, 0 });
    foreach (position : TWIN_LAMP_POSITIONS) {
        Node* lamp = result.scene.add_light(
            light::point({ 1, 0.9f, 0.8f }, TWIN_LAMP_INTENSITY, TWIN_LAMP_RANGE),
            name: "lamp",
        )!;
        lamp.local.position = position;
    }
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    result.camera.local.position = TWIN_CAMERA_POSITION;
    result.scene.update_world();
    return result;
}

fn void? render_twin_frame(Fixture* fixture, TwinScene* twin, ViewId view) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&twin.scene, twin.camera, view)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
    assert(renderer.stats.shader_rejections == 0);
}

fn void twin_use_materials(TwinScene* twin, bool custom) @private {
    twin.scene.get(twin.sphere, Mesh).material = custom ? twin.sphere_twin : twin.sphere_standard;
    twin.scene.get(twin.ground, Mesh).material = custom ? twin.ground_twin : twin.ground_standard;
}

fn TwinReadings? render_twin_pair(
    Fixture* fixture,
    TwinScene* twin,
    ShadingPath shading,
    LightSelection lights,
) @private {
    RenderTargetId target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(TWIN_TARGET_SIZE, TWIN_TARGET_SIZE, PixelFormat.RGBA32_FLOAT),
    )!;
    defer render::destroy_render_target(&fixture.renderer, target)!!;
    ViewDesc desc = render::texture_view_desc(target);
    desc.shading = shading;
    desc.lights = lights;
    desc.post.anti_aliasing = AntiAliasing.NONE;
    desc.ambient_occlusion = render::AMBIENT_OCCLUSION_DEFAULT;
    ViewId view = render::create_view(&fixture.renderer, desc)!;
    defer render::destroy_view(&fixture.renderer, view)!!;
    fixture.renderer.prepare_scene(&twin.scene)!;

    TwinReadings readings;
    bool[2] custom_modes = { false, true };
    foreach (custom : custom_modes) {
        twin_use_materials(twin, custom);
        // A warm-up frame first: the first frame on new materials or a new view does first-use work.
        render_twin_frame(fixture, twin, view)!;
        render_twin_frame(fixture, twin, view)!;
        Vec4[] pixels = read_float_target(fixture, target)!;
        if (custom) {
            readings.twin = pixels;
        } else {
            readings.standard = pixels;
        }
    }
    twin_use_materials(twin, false);
    return readings;
}

fn void check_twin_matches(TwinReadings readings, ShadingPath shading, LightSelection lights) @private {
    Vec4 centre = readings.standard[(TWIN_TARGET_SIZE / 2) * TWIN_TARGET_SIZE + TWIN_TARGET_SIZE / 2];
    float largest_difference;
    foreach (index, standard_texel : readings.standard) {
        Vec4 twin_texel = readings.twin[index];
        for (usz channel = 0; channel < 4; channel++) {
            float standard_value = standard_texel[channel];
            float twin_value = twin_texel[channel];
            float difference = math::abs(standard_value - twin_value);
            float magnitude = math::max(math::abs(standard_value), math::abs(twin_value));
            largest_difference = math::max(largest_difference, difference);
            assert(
                difference <= TWIN_RELATIVE_TOLERANCE * magnitude + TWIN_ABSOLUTE_TOLERANCE,
                "texel %d channel %d: Standard %f, twin %f",
                index,
                channel,
                standard_value,
                twin_value
            );
        }
    }
    io::eprintfn(
        "%s, %s: sphere centre %.5f %.5f %.5f, largest difference %g",
        shading,
        lights,
        centre.x,
        centre.y,
        centre.z,
        largest_difference,
    );
    assert(centre.x + centre.y + centre.z > 0);
}

fn void check_twin_on_path(ShadingPath shading) @private {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    TwinScene twin = create_twin_scene(&fixture)!!;
    defer scene::destroy_scene(&twin.scene);

    LightSelection[2] selections = { LightSelection.FLAT, LightSelection.CLUSTERED };
    foreach (lights : selections) {
        TwinReadings readings = render_twin_pair(&fixture, &twin, shading, lights)!!;
        defer {
            free(readings.standard);
            free(readings.twin);
        }
        check_twin_matches(readings, shading, lights);
    }
    check_validation(&fixture.renderer);
}

fn void test_custom_twin_matches_standard_on_forward_views() @test {
    check_twin_on_path(ShadingPath.FORWARD);
}

fn void test_custom_twin_matches_standard_on_deferred_views() @test {
    check_twin_on_path(ShadingPath.DEFERRED);
}

fn int rendered_shade(Fixture* fixture, ShadowScene* shadow, Vec3 point) @private {
    int value = shade(render_and_sample(fixture, shadow, point)!!);
    assert(fixture.renderer.stats.shader_rejections == 0);
    return value;
}

fn void test_custom_traced_forms_receive_traced_shadows() @test {
    foreach (ray_queries : TRACE_KINDS) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        ShadowScene shadow = create_shadow_scene(&fixture)!!;
        defer scene::destroy_scene(&shadow.scene);
        set_ray_traced_shadows(&fixture, true)!!;
        int standard_lit = rendered_shade(&fixture, &shadow, LIT_POINT);

        ShaderId twin_shader = add_twin_shader(&fixture, true)!!;
        shadow.scene.get(shadow.ground, Mesh).material = twin_material(&fixture, twin_shader, SHADOW_GROUND_PARAMS)!!;
        int twin_shadowed = rendered_shade(&fixture, &shadow, SHADOWED_POINT);
        int twin_lit = rendered_shade(&fixture, &shadow, LIT_POINT);

        @pool() {
            asset::ShaderDesc plain = twin_shader_desc(tmem, false)!!;
            fixture.assets.replace_shader(twin_shader, &plain)!!;
        };
        fixture.renderer.upload(twin_shader)!!;
        int fallback = rendered_shade(&fixture, &shadow, SHADOWED_POINT);

        io::eprintfn(
            "%s, custom twin ground: Standard lit %d, traced shadowed %d, traced lit %d, plain form %d",
            trace_name(ray_queries),
            standard_lit,
            twin_shadowed,
            twin_lit,
            fallback,
        );
        assert(twin_shadowed == 0 && twin_lit > 0);
        assert(math::abs(twin_lit - standard_lit) <= 3 * SHADE_TOLERANCE);
        assert(math::abs(fallback - twin_lit) <= 3 * SHADE_TOLERANCE);
        check_validation(&fixture.renderer);
    }
}
