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
import std::io;
import std::math;

const uint PATH_TARGET_SIZE @private = 32;
const float EXACT_TOLERANCE @private = 1e-3f;
const float FURNACE_ALBEDO @private = 0.5f;
const float STANDARD_FURNACE_MINIMUM @private = 0.7f; // loose until measured; single scattering loses some energy
const float STANDARD_FURNACE_MAXIMUM @private = 1.1f;
const float RASTER_AGREEMENT @private = 0.02f;
const float NORMAL_MAP_EFFECT_MINIMUM @private = 0.1f;
const Vec3 EMITTER_RADIANCE @private = { 2, 1, 0.5f };
const Vec4 BASIC_COLOR @private = { 0.25f, 0.5f, 0.75f, 1 };
const ushort HALF_QUARTER @private = 0x3400; // 0.25 as an IEEE half

struct PathScene @private {
    Scene scene;
    Node* camera;
    Node* subject;
}

fn PathScene? create_path_scene(
    Fixture* fixture,
    Vec3 position,
    Vec3 target,
    Vec3 up,
) @private {
    PathScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    result.scene.ambient_intensity = 0;
    result.scene.background.color = { 0, 0, 0, 1 };
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    result.camera.local.position = position;
    result.camera.local.rotation = maths::look_rotation((target - position).normalize(), up);
    return result;
}

fn ViewId? create_path_view(
    Fixture* fixture,
    RenderTargetId target,
    OutputMode color,
    PathTraceDesc settings,
) @private {
    ViewDesc desc = render::texture_view_desc(target, color);
    desc.shading = ShadingPath.PATH_TRACED;
    desc.post.anti_aliasing = AntiAliasing.NONE;
    desc.path_trace = settings;
    return render::create_view(&fixture.renderer, desc);
}

fn ViewId? create_raster_view(Fixture* fixture, RenderTargetId target, OutputMode color) @private {
    ViewDesc desc = render::texture_view_desc(target, color);
    desc.post.anti_aliasing = AntiAliasing.NONE;
    return render::create_view(&fixture.renderer, desc);
}

fn void? render_frames(
    Fixture* fixture,
    PathScene* path_scene,
    ViewId view,
    uint frames,
) @private {
    Renderer* renderer = &fixture.renderer;
    for (uint frame = 0; frame < frames; frame++) {
        renderer.begin_frame()!;
        defer catch render::abort_frame(renderer);
        renderer.render_view(&path_scene.scene, path_scene.camera, view)!;
        renderer.finish_view(view)!;
        renderer.end_frame()!;
    }
}

fn Vec4[]? read_float_target(
    Fixture* fixture,
    RenderTargetId target,
    uint width,
    uint height,
) @private {
    Vec4[] pixels = mem::new_array(Vec4, (usz)width * height);
    defer catch free(pixels);
    fixture.renderer.read_render_target(target, ((char*)pixels.ptr)[:pixels.len * Vec4::size])!;
    return pixels;
}

fn bool near(float value, float expected, float tolerance) @private {
    return math::abs(value - expected) <= tolerance;
}

fn bool near_rgb(Vec4 value, Vec3 expected, float tolerance) @private {
    return near(value.x, expected.x, tolerance) && near(value.y, expected.y, tolerance)
        && near(value.z, expected.z, tolerance);
}

fn RenderTargetId? float_target(Fixture* fixture, uint width = PATH_TARGET_SIZE) @private {
    return render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(width, PATH_TARGET_SIZE, PixelFormat.RGBA32_FLOAT),
    );
}

fn GeometryId? add_plane(Fixture* fixture, float size, bool tangents = false) @private {
    @pool() {
        Geometry plane = geometry::plane(tmem, size, size);
        if (tangents) plane.compute_tangents(tmem);
        return fixture.assets.add_geometry(&plane);
    };
}

fn GeometryId? add_sphere(Fixture* fixture, float radius) @private {
    @pool() {
        Geometry sphere = geometry::sphere(tmem, radius);
        return fixture.assets.add_geometry(&sphere);
    };
}

fn void test_path_traced_furnace_returns_the_albedo() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_tracing_pipelines: true)!!;
    defer destroy_fixture(&fixture);
    print_adapter(&fixture);
    assert(fixture.renderer.caps.ray_tracing_pipelines.enabled && fixture.renderer.caps.ray_queries.enabled);

    PathScene furnace = create_path_scene(&fixture, { 0, 0, 0 }, { 0, 0, -1 }, { 0, 1, 0 })!!;
    defer scene::destroy_scene(&furnace.scene);
    furnace.scene.ambient_color = { 1, 1, 1 };
    furnace.scene.ambient_intensity = 1;
    furnace.scene.background.color = { 1, 1, 1, 1 };
    GeometryId sphere = add_sphere(&fixture, 1)!!;
    ToonParams grey = material::TOON_PARAMS_DEFAULT;
    grey.color = { FURNACE_ALBEDO, FURNACE_ALBEDO, FURNACE_ALBEDO, 1 };
    MaterialId toon = fixture.assets.add_material(material::toon(grey))!!;
    Node* ball = furnace.scene.add_mesh(sphere, toon, name: "ball")!!;
    ball.local.position = { 0, 0, -3 };
    furnace.scene.update_world();

    RenderTargetId target = float_target(&fixture)!!;
    ViewId view = create_path_view(&fixture, target, OutputMode.LINEAR_HDR, {
        .max_bounces       = 2,
        .samples_per_frame = 1,
    })!!;
    fixture.renderer.prepare_scene(&furnace.scene)!!;
    render_frames(&fixture, &furnace, view, 1)!!;
    Vec4[] pixels = read_float_target(&fixture, target, PATH_TARGET_SIZE, PATH_TARGET_SIZE)!!;
    defer free(pixels);
    Vec4 centre = pixels[(PATH_TARGET_SIZE / 2) * PATH_TARGET_SIZE + PATH_TARGET_SIZE / 2];
    io::eprintfn("Path-traced Lambert furnace centre: %.5f %.5f %.5f", centre.x, centre.y, centre.z);
    assert(near_rgb(centre, { FURNACE_ALBEDO, FURNACE_ALBEDO, FURNACE_ALBEDO }, EXACT_TOLERANCE));
    assert(near_rgb(pixels[0], { 1, 1, 1 }, EXACT_TOLERANCE));

    StandardParams white_params = { .base_color = { 1, 1, 1, 1 }, .roughness = 0.5f };
    MaterialId white = fixture.assets.add_material(material::standard(white_params))!!;
    furnace.scene.get(ball, Mesh).material = white;
    ViewDesc desc = fixture.renderer.views.get(view).desc;
    desc.path_trace.samples_per_frame = 16;
    render::configure_view(&fixture.renderer, view, desc)!!;
    render_frames(&fixture, &furnace, view, 4)!!;
    free(pixels);
    pixels = read_float_target(&fixture, target, PATH_TARGET_SIZE, PATH_TARGET_SIZE)!!;
    centre = pixels[(PATH_TARGET_SIZE / 2) * PATH_TARGET_SIZE + PATH_TARGET_SIZE / 2];
    io::eprintfn("Path-traced Standard furnace centre: %.5f %.5f %.5f", centre.x, centre.y, centre.z);
    assert(centre.x >= STANDARD_FURNACE_MINIMUM && centre.x <= STANDARD_FURNACE_MAXIMUM);
    check_validation(&fixture.renderer);
}

fn void test_path_traced_emitters_and_basic_surfaces_show_their_radiance() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_tracing_pipelines: true)!!;
    defer destroy_fixture(&fixture);

    PathScene quads = create_path_scene(&fixture, { 0, 2, 0 }, { 0, 0, 0 }, { 0, 0, -1 })!!;
    defer scene::destroy_scene(&quads.scene);
    GeometryId plane = add_plane(&fixture, 1)!!;
    MaterialId glow = fixture.assets.add_material(material::standard({
        .base_color        = { 0, 0, 0, 1 },
        .roughness         = 1,
        .emissive          = EMITTER_RADIANCE,
        .emissive_strength = 1,
    }))!!;
    MaterialId basic = fixture.assets.add_material(material::basic({ .color = BASIC_COLOR }))!!;
    quads.scene.add_mesh(plane, glow, name: "emitter")!!.local.position = { -0.6f, 0, 0 };
    quads.scene.add_mesh(plane, basic, name: "basic")!!.local.position = { 0.6f, 0, 0 };
    quads.scene.update_world();

    uint width = 2 * PATH_TARGET_SIZE;
    RenderTargetId target = float_target(&fixture, width)!!;
    ViewId view = create_path_view(&fixture, target, OutputMode.LINEAR_HDR, render::PATH_TRACE_DEFAULT)!!;
    fixture.renderer.prepare_scene(&quads.scene)!!;
    render_frames(&fixture, &quads, view, 1)!!;
    Vec4[] pixels = read_float_target(&fixture, target, width, PATH_TARGET_SIZE)!!;
    defer free(pixels);

    Camera* lens = quads.scene.get(quads.camera, Camera);
    CameraMatrices matrices = camera::derive_matrices(*lens, quads.camera.world, { (float)width, PATH_TARGET_SIZE });
    Vec3[2] centres = { { -0.6f, 0, 0 }, { 0.6f, 0, 0 } };
    Vec3[2] expected = { EMITTER_RADIANCE, BASIC_COLOR.xyz };
    foreach (index, point : centres) {
        Vec4 clip = matrices.view_proj * (Vec4){ point.x, point.y, point.z, 1 };
        uint x = (uint)((clip.x / clip.w * 0.5f + 0.5f) * width);
        uint y = (uint)((0.5f - clip.y / clip.w * 0.5f) * PATH_TARGET_SIZE);
        Vec4 value = pixels[y * width + x];
        io::eprintfn("Quad %d at texel %d %d: %.4f %.4f %.4f", index, x, y, value.x, value.y, value.z);
        assert(near_rgb(value, expected[index], EXACT_TOLERANCE));
    }
    assert(near_rgb(pixels[0], { 0, 0, 0 }, EXACT_TOLERANCE));
    check_validation(&fixture.renderer);
}

fn Vec4? render_lit_plane_centre(
    Fixture* fixture,
    bool tangents,
    float normal_scale,
    bool path_traced,
) @private {
    PathScene lit = create_path_scene(fixture, { 0, 2, 0 }, { 0, 0, 0 }, { 0, 0, -1 })!;
    defer scene::destroy_scene(&lit.scene);
    GeometryId plane = add_plane(fixture, 4, tangents)!;
    Vec3 tilted = (Vec3){ 0.4f, 0, 1 }.normalize();
    char[4] texel = {
        (char)math::round((tilted.x * 0.5f + 0.5f) * 255),
        (char)math::round((tilted.y * 0.5f + 0.5f) * 255),
        (char)math::round((tilted.z * 0.5f + 0.5f) * 255),
        255,
    };
    TextureId normal_map = fixture.assets.add_texture(
        material::texture_2d_desc(1, 1, PixelFormat.RGBA8_UNORM, "tilted_normal"),
        texel[..],
    )!;
    MaterialId surface = fixture.assets.add_material(material::standard({
        .base_color   = { 0.8f, 0.8f, 0.8f, 1 },
        .roughness    = 0.5f,
        .normal_scale = normal_scale,
        .normal_map   = material::texture_slot(normal_map),
    }))!;
    lit.scene.add_mesh(plane, surface, name: "plane")!;
    Node* sun = lit.scene.add_light(light::directional({ 1, 1, 1 }, 3, shadow: false), name: "sun")!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.5f, -1, 0 }.normalize(), { 0, 0, -1 });
    lit.scene.update_world();

    RenderTargetId target = float_target(fixture)!;
    defer (void)render::destroy_render_target(&fixture.renderer, target);
    ViewId view = path_traced
        ? create_path_view(fixture, target, OutputMode.LINEAR_HDR, { .max_bounces = 1, .samples_per_frame = 4 })!
        : create_raster_view(fixture, target, OutputMode.LINEAR_HDR)!;
    defer (void)render::destroy_view(&fixture.renderer, view);
    fixture.renderer.prepare_scene(&lit.scene)!;
    render_frames(fixture, &lit, view, 1)!;
    Vec4[] pixels = read_float_target(fixture, target, PATH_TARGET_SIZE, PATH_TARGET_SIZE)!;
    defer free(pixels);
    return pixels[(PATH_TARGET_SIZE / 2) * PATH_TARGET_SIZE + PATH_TARGET_SIZE / 2];
}

fn void test_path_traced_direct_light_matches_raster_through_a_normal_map() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_tracing_pipelines: true)!!;
    defer destroy_fixture(&fixture);

    bool[2] tangent_cases = { false, true };
    foreach (tangents : tangent_cases) {
        Vec4 traced = render_lit_plane_centre(&fixture, tangents, 1, true)!!;
        Vec4 raster = render_lit_plane_centre(&fixture, tangents, 1, false)!!;
        io::eprintfn(
            "Normal-mapped plane (tangent stream %s): traced %.4f raster %.4f",
            tangents,
            traced.x,
            raster.x,
        );
        assert(near(traced.x, raster.x, RASTER_AGREEMENT * raster.x));
        assert(near(traced.y, raster.y, RASTER_AGREEMENT * raster.y));
        assert(near(traced.z, raster.z, RASTER_AGREEMENT * raster.z));
    }
    Vec4 mapped = render_lit_plane_centre(&fixture, false, 1, true)!!;
    Vec4 flat = render_lit_plane_centre(&fixture, false, 0, true)!!;
    assert(math::abs(mapped.x - flat.x) > NORMAL_MAP_EFFECT_MINIMUM * flat.x);
    check_validation(&fixture.renderer);
}

fn PathScene? create_lit_room(Fixture* fixture) @private {
    PathScene room = create_path_scene(fixture, { 0, 1, 1 }, { 0, 0.3f, -2 }, { 0, 1, 0 })!;
    defer catch scene::destroy_scene(&room.scene);
    room.scene.ambient_color = { 1, 1, 1 };
    room.scene.ambient_intensity = 0.2f;
    GeometryId floor = add_plane(fixture, 10)!;
    GeometryId sphere = add_sphere(fixture, 0.5f)!;
    ToonParams floor_colour = material::TOON_PARAMS_DEFAULT;
    floor_colour.color = { 0.8f, 0.8f, 0.8f, 1 };
    MaterialId floor_material = fixture.assets.add_material(material::toon(floor_colour))!;
    MaterialId sphere_material = fixture.assets.add_material(material::standard({
        .base_color = { 0.9f, 0.5f, 0.2f, 1 },
        .roughness  = 0.3f,
    }))!;
    room.scene.add_mesh(floor, floor_material, name: "floor")!;
    room.subject = room.scene.add_mesh(sphere, sphere_material, name: "sphere")!;
    room.subject.local.position = { 0, 0.5f, -2 };
    Light lamp = light::point({ 1, 1, 1 }, 5, 10);
    lamp.shadow.enabled = true;
    room.scene.add_light(lamp, name: "lamp")!.local.position = { 1, 2, -1 };
    room.scene.update_world();
    return room;
}

fn void test_sample_batches_match_single_samples() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_tracing_pipelines: true)!!;
    defer destroy_fixture(&fixture);
    PathScene room = create_lit_room(&fixture)!!;
    defer scene::destroy_scene(&room.scene);

    RenderTargetId batched_target = float_target(&fixture)!!;
    RenderTargetId single_target = float_target(&fixture)!!;
    ViewId batched = create_path_view(&fixture, batched_target, OutputMode.LINEAR_HDR, {
        .max_bounces       = 6,
        .samples_per_frame = 4,
    })!!;
    ViewId single = create_path_view(&fixture, single_target, OutputMode.LINEAR_HDR, {
        .max_bounces       = 6,
        .samples_per_frame = 1,
    })!!;
    fixture.renderer.prepare_scene(&room.scene)!!;
    render_frames(&fixture, &room, batched, 1)!!;
    render_frames(&fixture, &room, single, 4)!!;

    Vec4[] batched_pixels = read_float_target(&fixture, batched_target, PATH_TARGET_SIZE, PATH_TARGET_SIZE)!!;
    defer free(batched_pixels);
    Vec4[] single_pixels = read_float_target(&fixture, single_target, PATH_TARGET_SIZE, PATH_TARGET_SIZE)!!;
    defer free(single_pixels);
    foreach (index, value : batched_pixels) {
        Vec4 other = single_pixels[index];
        float largest = math::max(math::max(math::abs(value.x), math::abs(value.y)), math::abs(value.z));
        float tolerance = EXACT_TOLERANCE * math::max(1.0f, largest);
        assert(near_rgb(other, value.xyz, tolerance));
    }
    check_validation(&fixture.renderer);
}

fn void? expect_accumulation(
    Fixture* fixture,
    PathScene* room,
    ViewId view,
    uint samples,
    uint traced,
) @private {
    render_frames(fixture, room, view, 1)!;
    assert(fixture.renderer.view_stats(view)!.accumulated_samples == samples);
    assert(fixture.renderer.stats.path_trace_samples == traced);
}

fn void test_accumulation_counts_resets_and_caps() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_tracing_pipelines: true)!!;
    defer destroy_fixture(&fixture);
    PathScene room = create_lit_room(&fixture)!!;
    defer scene::destroy_scene(&room.scene);

    RenderTargetId target = float_target(&fixture)!!;
    ViewId view = create_path_view(&fixture, target, OutputMode.LINEAR_HDR, {
        .max_bounces       = 2,
        .samples_per_frame = 2,
        .max_samples       = 5,
    })!!;
    fixture.renderer.prepare_scene(&room.scene)!!;
    expect_accumulation(&fixture, &room, view, 2, 2)!!;
    expect_accumulation(&fixture, &room, view, 4, 2)!!;
    expect_accumulation(&fixture, &room, view, 5, 1)!!;
    expect_accumulation(&fixture, &room, view, 5, 0)!!;

    room.camera.local.position.x += 0.1f;
    room.scene.update_world();
    expect_accumulation(&fixture, &room, view, 2, 2)!!;
    render::reset_view_history(&fixture.renderer, view)!!;
    expect_accumulation(&fixture, &room, view, 2, 2)!!;
    Node* sphere = room.subject;
    sphere.local.position.x += 0.1f;
    room.scene.update_world();
    expect_accumulation(&fixture, &room, view, 2, 2)!!;

    fixture.renderer.begin_frame()!!;
    fixture.renderer.end_frame()!!;
    assert(fixture.renderer.view_stats(view)!!.accumulated_samples == 2);

    ViewDesc desc = fixture.renderer.views.get(view).desc;
    desc.path_trace.max_samples = 0;
    render::configure_view(&fixture.renderer, view, desc)!!;
    expect_accumulation(&fixture, &room, view, 2, 2)!!;
    MaterialId sphere_material = room.scene.get(sphere, Mesh).material;
    fixture.assets.material(sphere_material).data.standard.roughness = 0.6f;
    fixture.assets.mark_material_dirty(sphere_material);
    expect_accumulation(&fixture, &room, view, 4, 2)!!;
    check_validation(&fixture.renderer);
}

fn void test_read_render_target_returns_stored_bytes() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_tracing_pipelines: true)!!;
    defer destroy_fixture(&fixture);
    PathScene flat = create_path_scene(&fixture, { 0, 2, 0 }, { 0, 0, 0 }, { 0, 0, -1 })!!;
    defer scene::destroy_scene(&flat.scene);
    GeometryId plane = add_plane(&fixture, 20)!!;
    MaterialId basic = fixture.assets.add_material(material::basic({ .color = BASIC_COLOR }))!!;
    flat.scene.add_mesh(plane, basic, name: "floor")!!;
    flat.scene.update_world();
    fixture.renderer.prepare_scene(&flat.scene)!!;

    RenderTargetId traced_target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(PATH_TARGET_SIZE, PATH_TARGET_SIZE, PixelFormat.RGBA8_SRGB),
    )!!;
    RenderTargetId raster_target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(PATH_TARGET_SIZE, PATH_TARGET_SIZE, PixelFormat.RGBA8_SRGB),
    )!!;
    ViewId traced = create_path_view(&fixture, traced_target, OutputMode.DISPLAY_LDR, render::PATH_TRACE_DEFAULT)!!;
    ViewId raster = create_raster_view(&fixture, raster_target, OutputMode.DISPLAY_LDR)!!;
    render_frames(&fixture, &flat, traced, 1)!!;
    render_frames(&fixture, &flat, raster, 1)!!;
    char[] traced_bytes = mem::new_array(char, PATH_TARGET_SIZE * PATH_TARGET_SIZE * 4);
    defer free(traced_bytes);
    char[] raster_bytes = mem::new_array(char, PATH_TARGET_SIZE * PATH_TARGET_SIZE * 4);
    defer free(raster_bytes);
    fixture.renderer.read_render_target(traced_target, traced_bytes)!!;
    fixture.renderer.read_render_target(raster_target, raster_bytes)!!;
    foreach (index, value : traced_bytes) assert(math::abs((int)value - (int)raster_bytes[index]) <= CHANNEL_TOLERANCE);

    RenderTargetId half_target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(PATH_TARGET_SIZE, PATH_TARGET_SIZE),
    )!!;
    ViewId half_view = create_path_view(&fixture, half_target, OutputMode.LINEAR_HDR, render::PATH_TRACE_DEFAULT)!!;
    render_frames(&fixture, &flat, half_view, 1)!!;
    ushort[] halves = mem::new_array(ushort, PATH_TARGET_SIZE * PATH_TARGET_SIZE * 4);
    defer free(halves);
    fixture.renderer.read_render_target(half_target, ((char*)halves.ptr)[:halves.len * ushort::size])!!;
    assert(halves[((PATH_TARGET_SIZE / 2) * PATH_TARGET_SIZE + PATH_TARGET_SIZE / 2) * 4] == HALF_QUARTER);

    char[3] short_buffer;
    fault excuse = @catch(fixture.renderer.read_render_target(half_target, short_buffer[..]));
    assert(excuse == c3d::INVALID_ARGUMENT);
    render::destroy_view(&fixture.renderer, half_view)!!;
    render::destroy_render_target(&fixture.renderer, half_target)!!;
    char[] half_bytes = ((char*)halves.ptr)[:halves.len * ushort::size];
    excuse = @catch(fixture.renderer.read_render_target(half_target, half_bytes));
    assert(excuse == c3d::INVALID_ID);
    check_validation(&fixture.renderer);
}
