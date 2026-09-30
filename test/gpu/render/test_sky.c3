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

const char[*] SKY_PROBE_SOURCE @private = $embed("sky_probe.comp.glsl");
const char[*] FOG_READER_SOURCE @private = $embed("fog_reader.frag.glsl");
const uint SKY_TARGET_SIZE @private = 33; // odd: the centre pixel's ray is the camera axis, a level ray
const uint SKY_CENTRE @private = SKY_TARGET_SIZE / 2;
const uint SKY_UPPER_ROW @private = 6;
const uint SKY_LOWER_ROW @private = 27;
const uint SKY_PROBE_CASES @private = 8; // mirrored as SKY_PROBE_CASES in sky_probe.comp.glsl
const uint SKY_WARM_FRAMES @private = 2; // the first frame on a new view or material does first-use work
const float SKY_CAMERA_HEIGHT @private = 2;
const float BED_DISTANCE @private = 80;
const float READER_DISTANCE @private = 20;
const float PLANE_SIZE @private = 2000;
const float DEGREE @private = (float)math::PI / 180;
const float MIRROR_PITCH @private = 5 * DEGREE; // the camera looks down at the water, its mirror up through it
const Plane WATER_PLANE @private = { .normal = { 0, 1, 0 }, .d = 0 };
const Vec4 BED_COLOR @private = { 0.8f, 0.5f, 0.2f, 1 };
const Vec4 BLEND_COLOR @private = { 0.1f, 0.9f, 0.3f, 0.5f };
const Vec3 READER_COLOR @private = { 0.9f, 0.3f, 0.1f }; // mirrored as READER_COLOR in fog_reader.frag.glsl
const Vec3 GLASS_COLOR @private = { 0.05f, 0.1f, 0.15f }; // mirrored as GLASS_COLOR in fog_reader.frag.glsl
const float GLASS_HALF @private = 0.5f; // mirrored as GLASS_HALF in fog_reader.frag.glsl
const Vec3 FOG_AMBIENT @private = { 0.3f, 0.4f, 0.5f };
const Vec4 SKY_BACKGROUND @private = { 0.1f, 0.2f, 0.3f, 1 };
const HeightFog TEST_FOG @private = { .density = 0.01f, .falloff = 0.05f, .albedo = { 1, 1, 1 }, .max_distance = 100 };
const HeightFog DENSE_FOG @private = {
    .density      = 0.03f,
    .falloff      = 0.02f,
    .albedo       = { 0.8f, 0.8f, 0.8f },
    .max_distance = 100,
};
const float FOG_RELATIVE_TOLERANCE @private = 3e-3f; // RGBA16F rounds to 2^-11; the fog adds a few steps
const float FOG_ABSOLUTE_TOLERANCE @private = 2e-4f;
const float TABLE_TOLERANCE @private = 0.0035f; // the interview's bound on the 64-step CPU integral
const float TABLE_CHANNEL_FLOOR @private = 1e-3f; // below it RGBA16F holds too few bits for a relative bound
const uint FROXEL_UPPER_ROW @private = 5;           // froxel centres of the 3 x 3 grid over 33 px: pixels 5, 16, 27
const float VOLUME_END @private = 50;               // metres the test volume covers
const float FOG_ANISOTROPY @private = 0.3f;
const float VOLUME_SUN_INTENSITY @private = 3;
const float VOLUME_SUN_DEGREES @private = 20;       // ahead of the camera, strongly forward-scattered
const float CLIP_DISTANCE @private = 10;
const float ROOF_HEIGHT @private = 10;
const float ROOF_LENGTH @private = 60;              // shadows the first 60 m of the level ray under a sun overhead
const float SHORT_SHADOW_DISTANCE @private = 30;
const float SHADOWED_SHARE_MIN @private = 0.1f;     // computed 0.19 for 60 of 80 m shadowed
const float SHADOWED_SHARE_MAX @private = 0.3f;
const float SHORT_SHARE_MIN @private = 0.4f;        // computed 0.54 when the atlas ends at 30 m

struct FogScene @private {
    Scene      scene;
    Node*      camera;
    Node*      sun;
    GeometryId plane;
}

struct FogRay @private {
    Vec3  origin;
    Vec3  direction;
    float distance; // to a facing plane; unused for the background
}

struct FogView @private {
    RenderTargetId target;
    ViewId         view;
}

struct SkyProbeRoot @private {
    gpu::GpuAddress        output_address;
    gpu::GpuAddress        sky_fog;
    Vec4[SKY_PROBE_CASES]  cases;
}
$assert SkyProbeRoot::size == 16 + 16 * SKY_PROBE_CASES;

fn FogScene? create_fog_scene(Fixture* fixture) @private {
    FogScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    result.scene.ambient_color = FOG_AMBIENT;
    result.scene.ambient_intensity = 1;
    result.scene.background.color = SKY_BACKGROUND;
    @pool() {
        Geometry plane = geometry::plane(tmem, PLANE_SIZE, PLANE_SIZE);
        result.plane = fixture.assets.add_geometry(&plane)!;
    };
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    result.camera.local.position = { 0, SKY_CAMERA_HEIGHT, 0 };
    result.scene.update_world();
    return result;
}

fn Node*? add_facing_plane(FogScene* target, MaterialId material, float distance) @private {
    Node* node = target.scene.add_mesh(target.plane, material)!;
    node.local.position = { 0, SKY_CAMERA_HEIGHT, -distance };
    node.local.rotation = maths::look_rotation({ 0, 1, 0 }, { 0, 0, 1 });
    target.scene.get(node, Mesh).cast_shadow = false;
    target.scene.update_world();
    return node;
}

fn MaterialId? add_unlit(Fixture* fixture, Vec4 color, AlphaMode alpha = AlphaMode.OPAQUE) @private {
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.double_sided = true;
    common.alpha_mode = alpha;
    return fixture.assets.add_material(material::basic({ .color = color }, common));
}

fn Node*? add_fog(FogScene* target, HeightFog fog) @private {
    Node* node = target.scene.add_node(name: "fog")!;
    target.scene.add(node, fog);
    target.scene.update_world();
    return node;
}

fn Node*? add_sun(FogScene* target, Vec3 to_sun, float intensity) @private {
    Node* node = target.scene.add_light(light::directional({ 1, 1, 1 }, intensity, false), name: "sun")!;
    target.scene.add(node, light::ATMOSPHERE_EARTH);
    node.local.rotation = maths::look_rotation(-to_sun, { 0, 1, 0 });
    target.scene.update_world();
    target.sun = node;
    return node;
}

// Points the light toward -z at an elevation, the sun behind the camera's view.
fn void aim_node(Node* sun, float elevation) @private {
    Vec3 to_sun = { 0, math::sin(elevation), math::cos(elevation) };
    sun.local.rotation = maths::look_rotation(-to_sun, { 0, 1, 0 });
}

fn FogView? create_fog_view(
    Fixture* fixture,
    ShadingPath shading,
    Plane clip_plane = {},
    bool volumetric_fog = false,
) @private {
    FogView result;
    result.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(SKY_TARGET_SIZE, SKY_TARGET_SIZE, PixelFormat.RGBA32_FLOAT),
    )!;
    ViewDesc desc = render::texture_view_desc(result.target);
    desc.shading = shading;
    desc.post.anti_aliasing = AntiAliasing.NONE;
    desc.clip_plane = clip_plane;
    desc.volumetric_fog = volumetric_fog;
    result.view = render::create_view(&fixture.renderer, desc)!;
    return result;
}

fn void destroy_fog_view(Fixture* fixture, FogView* fog_view) @private {
    render::destroy_view(&fixture.renderer, fog_view.view)!!;
    render::destroy_render_target(&fixture.renderer, fog_view.target)!!;
}

fn void? render_fog_frames(
    Fixture* fixture,
    FogScene* target,
    FogView* fog_view,
    uint frames = SKY_WARM_FRAMES,
) @private {
    Renderer* renderer = &fixture.renderer;
    target.scene.update_world();
    for (uint frame = 0; frame < frames; frame++) {
        renderer.begin_frame()!;
        defer catch render::abort_frame(renderer);
        renderer.render_view(&target.scene, target.camera, fog_view.view)!;
        renderer.finish_view(fog_view.view)!;
        renderer.end_frame()!;
    }
}

fn Vec4[]? render_fog_pixels(Fixture* fixture, FogScene* target, FogView* fog_view) @private {
    render_fog_frames(fixture, target, fog_view)!;
    return read_float_target(fixture, fog_view.target);
}

fn Vec4 pixel_at(Vec4[] pixels, uint x, uint y) @private {
    return pixels[y * SKY_TARGET_SIZE + x];
}

// The CPU twin of the fog pass's reconstruction: the camera ray through the centre column's pixel of a row.
fn FogRay pixel_ray(FogScene* target, uint row, float plane_distance = 0) @private {
    Camera* lens = target.scene.get(target.camera, Camera);
    CameraMatrices matrices = camera::derive_matrices(*lens, target.camera.world, { SKY_TARGET_SIZE, SKY_TARGET_SIZE });
    Vec2 uv = { ((float)SKY_CENTRE + 0.5f) / SKY_TARGET_SIZE, ((float)row + 0.5f) / SKY_TARGET_SIZE };
    Vec3 far_point = render::reconstruct_world_position(matrices.inv_view_proj, uv, 0.5f);
    Vec3 direction = (far_point - matrices.position).normalize();
    return { .origin = matrices.position, .direction = direction, .distance = plane_distance / -direction.z };
}

// The part of a ray past a distance along it: what a clipped view fogs.
fn FogRay ray_beyond(FogRay ray, float near) @private {
    return { .origin = ray.origin + ray.direction * near, .direction = ray.direction, .distance = ray.distance - near };
}

// Radiance at the end of the ray seen through height fog lit by the ambient.
fn Vec3 fogged(HeightFog* fog, FogRay ray, Vec3 radiance) @private {
    float transmittance = light::height_fog_transmittance(
        fog:         fog,
        base_height: 0,
        origin:      ray.origin,
        direction:   ray.direction,
        distance:    ray.distance,
    );
    return radiance * transmittance + fog.albedo * FOG_AMBIENT * (1 - transmittance);
}

fn Vec3 fogged_to_infinity(HeightFog* fog, FogRay ray, Vec3 radiance) @private {
    float transmittance = light::height_fog_limit_transmittance(
        fog:         fog,
        base_height: 0,
        origin:      ray.origin,
        direction:   ray.direction,
    );
    return radiance * transmittance + fog.albedo * FOG_AMBIENT * (1 - transmittance);
}

fn void check_rgb_close(Vec4 found, Vec3 expected, String what) @private {
    for (uint channel = 0; channel < 3; channel++) {
        float difference = math::abs(found[channel] - expected[channel]);
        float bound = FOG_RELATIVE_TOLERANCE * math::abs(expected[channel]) + FOG_ABSOLUTE_TOLERANCE;
        assert(difference <= bound, "%s channel %d: found %f, expected %f", what, channel, found[channel],
            expected[channel]);
    }
}

fn ShaderId? add_fog_reader(Fixture* fixture, String[] defines) @private {
    asset::ShaderDesc desc = {
        .fragment = compile::compile_glsl(
            allocator: fixture.allocator,
            source:    (String)FOG_READER_SOURCE[..],
            stage:     ShaderStage.FRAGMENT,
            defines:   defines,
        )!,
        .scene_reads = { .color = true, .depth = true },
    };
    defer alloc::free(fixture.allocator, desc.fragment.ptr);
    return fixture.assets.add_shader(&desc);
}

fn MaterialId? add_reader_material(Fixture* fixture, ShaderId shader) @private {
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.double_sided = true;
    return fixture.assets.add_material(material::custom(shader, common: common));
}

// Physical transmission drawn blended: in the scene-read list, without depth.
fn MaterialId? add_blended_pane(Fixture* fixture) @private {
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.double_sided = true;
    common.alpha_mode = AlphaMode.BLEND;
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.standard.metallic = 0;
    params.standard.roughness = 0.2f;
    params.transmission = 1;
    return fixture.assets.add_material(material::physical(params, common));
}

fn HeightFog volume_fog() @private {
    HeightFog fog = TEST_FOG;
    fog.max_distance = VOLUME_END;
    fog.anisotropy = FOG_ANISOTROPY;
    return fog;
}

fn Node*? add_plain_sun(FogScene* target, Vec3 to_sun, bool shadow) @private {
    Light sun = light::directional({ 1, 1, 1 }, VOLUME_SUN_INTENSITY, shadow);
    Node* node = target.scene.add_light(sun, name: "sun")!;
    Vec3 up = math::abs(to_sun.y) > 0.99f ? (Vec3){ 0, 0, -1 } : (Vec3){ 0, 1, 0 };
    node.local.rotation = maths::look_rotation(-to_sun, up);
    target.scene.update_world();
    target.sun = node;
    return node;
}

// In-scatter per unit extinction of the volume: the ambient plus the sun through the phase.
fn Vec3 volume_color(
    HeightFog* fog,
    Vec3 direction,
    Vec3 to_sun,
    float sun_intensity,
) @private {
    float squared = fog.anisotropy * fog.anisotropy;
    float denominator = 1 + squared - 2 * fog.anisotropy * direction.dot(to_sun);
    float phase = (1 - squared) / (4 * (float)math::PI * denominator * math::sqrt(denominator));
    return fog.albedo * (FOG_AMBIENT + (Vec3){ 1, 1, 1 } * phase * sun_intensity);
}

// A surface's radiance through the volume, with the analytic fog past the volume's end.
fn Vec3 volume_fogged(HeightFog* fog, FogRay ray, Vec3 radiance, Vec3 color) @private {
    float inside = math::min(ray.distance, fog.max_distance);
    float transmittance = light::height_fog_transmittance(
        fog:         fog,
        base_height: 0,
        origin:      ray.origin,
        direction:   ray.direction,
        distance:    inside,
    );
    Vec3 behind = ray.distance > fog.max_distance ? fogged(fog, ray_beyond(ray, fog.max_distance), radiance) : radiance;
    return behind * transmittance + color * (1 - transmittance);
}

fn Vec3 volume_fogged_background(HeightFog* fog, FogRay ray, Vec3 radiance, Vec3 color) @private {
    float transmittance = light::height_fog_transmittance(
        fog:         fog,
        base_height: 0,
        origin:      ray.origin,
        direction:   ray.direction,
        distance:    fog.max_distance,
    );
    Vec3 behind = fogged_to_infinity(fog, ray_beyond(ray, fog.max_distance), radiance);
    return behind * transmittance + color * (1 - transmittance);
}

// The sun's in-scatter that survives the shadow: 0 fully shadowed, 1 unshadowed.
fn float kept_share(Vec4 shadowed, Vec4 unlit, Vec4 lit) @private {
    Vec3 kept = shadowed.xyz - unlit.xyz;
    Vec3 full = lit.xyz - unlit.xyz;
    return (kept.x + kept.y + kept.z) / (full.x + full.y + full.z);
}

fn void test_transmittance_table_matches_the_cpu_integral() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    Vec3 to_sun = { math::cos(20 * DEGREE), math::sin(20 * DEGREE), 0 };
    add_sun(&target, to_sun, 3)!!;
    renderer.prepare_scene(&target.scene)!!;
    AtmosphereSelection selection = render::select_atmosphere(&target.scene);
    AtmosphereRes* mirror = render::find_atmosphere(renderer, target.scene.identity, selection.entity);
    assert(mirror && mirror.written);

    Vec4[SKY_PROBE_CASES] cases = {
        { 0, 1, 0, 0 },
        { 0, math::sin(30 * DEGREE), 0, 0 },
        { 0, math::sin(5 * DEGREE), 0, 0 },
        { 1_000, -0.01f, 0, 0 },
        { 10_000, 0.1f, 0, 0 },
        { 300, math::sin(60 * DEGREE), 0, 0 },
        { 0, math::sin(1 * DEGREE), 0, 0 },
        { 0, to_sun.y, 0, 0 },
    };
    usz bytes = SKY_PROBE_CASES * Vec4::size;
    ComputeShaderId probe = add_compute_shader(&fixture, (String)SKY_PROBE_SOURCE[..])!!;
    BufferId output = renderer.create_buffer({ .size = bytes, .debug_name = "sky_probe_output" })!!;
    gpu::AllocationDesc readback_desc = {
        .size         = bytes,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "sky_probe_readback",
    };
    gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &readback_desc)!!;
    defer {
        render::wait_frames(renderer)!!;
        gpu::GpuAllocation allocation = readback.span.allocation();
        gpu::free_allocation(&renderer.device, &allocation)!!;
    }

    renderer.begin_frame()!!;
    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan block = slot.upload.take(&renderer.device, SkyFogGpu::size, render::STREAM_ALIGNMENT)!!;
    FogSelection no_fog;
    render::write_sky_fog(
        root:            (SkyFogGpu*)block.bytes.ptr,
        atmosphere:      selection.atmosphere,
        to_sun:          to_sun,
        sun_illuminance: { 3, 3, 3 },
        altitude:        0,
        fog:             &no_fog,
        tables:          {
            .transmittance = mirror.transmittance_view.index,
            .sampler       = renderer.linear_clamp_sampler,
        },
    );
    SkyProbeRoot root = { .output_address = renderer.buffer_address(output), .sky_fog = block.address, .cases = cases };
    BufferId[1] writes = { output };
    renderer.dispatch({
        .shader = probe,
        .root   = ((char*)&root)[:SkyProbeRoot::size],
        .groups = { 1, 1, 1 },
        .writes = writes[..],
    })!!;
    gpu::Barrier written = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &written)!!;
    gpu::BufferCopyDesc copy = {
        .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(output).allocation)!!,
        .dst = readback.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host_read)!!;
    renderer.end_frame()!!;
    render::wait_frames(renderer)!!;
    gpu::invalidate_mapped_span(&renderer.device, readback.span)!!;
    Vec4[] table = ((Vec4*)readback.bytes.ptr)[:SKY_PROBE_CASES];

    foreach (index, test_case : cases) {
        Vec3 cpu = light::atmosphere_transmittance(selection.atmosphere, test_case.x, test_case.y);
        for (uint channel = 0; channel < 3; channel++) {
            if (cpu[channel] < TABLE_CHANNEL_FLOOR) continue;
            float error = math::abs(table[index][channel] - cpu[channel]) / cpu[channel];
            io::eprintfn("case %d channel %d: table %f, cpu %f, error %f", index, channel, table[index][channel],
                cpu[channel], error);
            assert(error <= TABLE_TOLERANCE, "case %d channel %d", index, channel);
        }
    }

    LightCounts counts;
    @pool() {
        LightExtraction extraction = render::extract_lights(
            allocator:   tmem,
            scene:       &target.scene,
            frustum:     null,
            view_layers: uint::max,
            capacity:    1,
            counts:      &counts,
            atmosphere:  &selection,
            altitude:    0,
        );
        Vec4 packed = extraction.lights[0].color_intensity;
        for (uint channel = 0; channel < 3; channel++) {
            float through_table = table[SKY_PROBE_CASES - 1][channel] * 3;
            float error = math::abs(packed[channel] * packed.w - through_table) / through_table;
            assert(error <= TABLE_TOLERANCE, "extracted sun channel %d: %f", channel, error);
        }
    };
    check_validation(renderer);
}

fn void test_doubling_the_sun_doubles_the_sky() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    Node* sun = add_sun(&target, { 0, math::sin(30 * DEGREE), -math::cos(30 * DEGREE) }, 2)!!;
    target.camera.local.rotation = maths::look_rotation({ 1, 0.3f, 0 }, { 0, 1, 0 });
    FogView fog_view = create_fog_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_fog_view(&fixture, &fog_view);

    Vec4[] single = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(single);
    target.scene.get(sun, Light).intensity = 4;
    Vec4[] doubled = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(doubled);
    Vec4 before = pixel_at(single, SKY_CENTRE, SKY_UPPER_ROW);
    Vec4 after = pixel_at(doubled, SKY_CENTRE, SKY_UPPER_ROW);
    assert(before.x > 0 && before.z > before.x, "a blue sky: %f %f %f", before.x, before.y, before.z);
    check_rgb_close(after, before.xyz * 2, "doubled sky");
    check_validation(&fixture.renderer);
}

fn void check_opaque_fog(ShadingPath shading) @private {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    add_facing_plane(&target, add_unlit(&fixture, BED_COLOR)!!, BED_DISTANCE)!!;
    HeightFog fog = TEST_FOG;
    add_fog(&target, fog)!!;
    FogView fog_view = create_fog_view(&fixture, shading)!!;
    defer destroy_fog_view(&fixture, &fog_view);

    Vec4[] pixels = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(pixels);
    uint[2] rows = { SKY_CENTRE, SKY_UPPER_ROW };
    foreach (row : rows) {
        Vec3 expected = fogged(&fog, pixel_ray(&target, row, BED_DISTANCE), BED_COLOR.xyz);
        check_rgb_close(pixel_at(pixels, SKY_CENTRE, row), expected, row == SKY_CENTRE ? "level ray" : "rising ray");
    }
    check_validation(&fixture.renderer);
}

fn void test_opaque_pixels_match_the_fog_reference() @test {
    check_opaque_fog(ShadingPath.FORWARD);
    check_opaque_fog(ShadingPath.DEFERRED);
}

fn void test_background_takes_height_fog_without_aerial_perspective() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    HeightFog fog = TEST_FOG;
    Node* fog_node = add_fog(&target, fog)!!;
    FogView fog_view = create_fog_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_fog_view(&fixture, &fog_view);

    Vec4[] colored = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(colored);
    FogRay above = pixel_ray(&target, SKY_UPPER_ROW);
    Vec3 colored_expected = fogged_to_infinity(&fog, above, SKY_BACKGROUND.xyz);
    check_rgb_close(pixel_at(colored, SKY_CENTRE, SKY_UPPER_ROW), colored_expected, "colour background above");
    Vec3 fog_color = fog.albedo * FOG_AMBIENT;
    check_rgb_close(pixel_at(colored, SKY_CENTRE, SKY_CENTRE), fog_color, "colour background on the horizon");
    check_rgb_close(pixel_at(colored, SKY_CENTRE, SKY_LOWER_ROW), fog_color, "colour background below");

    add_sun(&target, { 0, math::sin(40 * DEGREE), math::cos(40 * DEGREE) }, 3)!!;
    Vec4[] fogged_sky = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(fogged_sky);
    HeightFog* medium = target.scene.get(fog_node, HeightFog);
    medium.albedo = { 0.5f, 0.5f, 0.5f };
    Vec4[] half_albedo = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(half_albedo);
    medium.density = 0;
    Vec4[] clear_sky = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(clear_sky);
    float limit = light::height_fog_limit_transmittance(
        fog:         &fog,
        base_height: 0,
        origin:      above.origin,
        direction:   above.direction,
    );
    Vec3 sky = pixel_at(clear_sky, SKY_CENTRE, SKY_UPPER_ROW).xyz;
    check_rgb_close(pixel_at(fogged_sky, SKY_CENTRE, SKY_UPPER_ROW), sky, "sky under white fog");
    check_rgb_close(pixel_at(half_albedo, SKY_CENTRE, SKY_UPPER_ROW), sky * (limit + 0.5f * (1 - limit)),
        "sky under half-albedo fog");
    check_validation(&fixture.renderer);
}

fn void check_reader_fog(ShadingPath shading) @private {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    add_facing_plane(&target, add_unlit(&fixture, BED_COLOR)!!, BED_DISTANCE)!!;
    ShaderId reader = add_fog_reader(&fixture, {})!!;
    add_facing_plane(&target, add_reader_material(&fixture, reader)!!, READER_DISTANCE)!!;
    HeightFog fog = TEST_FOG;
    add_fog(&target, fog)!!;
    FogView fog_view = create_fog_view(&fixture, shading)!!;
    defer destroy_fog_view(&fixture, &fog_view);

    Vec4[] pixels = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(pixels);
    Vec3 expected = fogged(&fog, pixel_ray(&target, SKY_UPPER_ROW, READER_DISTANCE), READER_COLOR);
    check_rgb_close(pixel_at(pixels, SKY_CENTRE, SKY_UPPER_ROW), expected, "reader");
    check_validation(&fixture.renderer);
}

fn void test_reader_is_fogged_at_its_own_depth() @test {
    check_reader_fog(ShadingPath.FORWARD);
    check_reader_fog(ShadingPath.DEFERRED);
}

fn void test_blended_draw_is_fogged_once() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    add_facing_plane(&target, add_unlit(&fixture, BED_COLOR)!!, BED_DISTANCE)!!;
    add_facing_plane(&target, add_unlit(&fixture, BLEND_COLOR, AlphaMode.BLEND)!!, READER_DISTANCE)!!;
    HeightFog fog = TEST_FOG;
    add_fog(&target, fog)!!;
    FogView fog_view = create_fog_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_fog_view(&fixture, &fog_view);

    Vec4[] pixels = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(pixels);
    Vec3 bed = fogged(&fog, pixel_ray(&target, SKY_UPPER_ROW, BED_DISTANCE), BED_COLOR.xyz);
    Vec3 glass = fogged(&fog, pixel_ray(&target, SKY_UPPER_ROW, READER_DISTANCE), BLEND_COLOR.xyz);
    float coverage = BLEND_COLOR.w;
    check_rgb_close(pixel_at(pixels, SKY_CENTRE, SKY_UPPER_ROW), glass * coverage + bed * (1 - coverage), "blended");
    check_validation(&fixture.renderer);
}

fn void test_fog_off_records_no_fog_pass() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    add_facing_plane(&target, add_unlit(&fixture, BED_COLOR)!!, BED_DISTANCE)!!;
    add_facing_plane(&target, add_unlit(&fixture, BLEND_COLOR, AlphaMode.BLEND)!!, READER_DISTANCE)!!;
    FogView fog_view = create_fog_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_fog_view(&fixture, &fog_view);

    render_fog_frames(&fixture, &target, &fog_view)!!;
    uint unfogged = renderer.stats.post_dispatches;
    assert(!renderer.sky_pipelines.fog.is_valid());
    Node* fog = add_fog(&target, TEST_FOG)!!;
    render_fog_frames(&fixture, &target, &fog_view)!!;
    assert(renderer.stats.post_dispatches == unfogged + 1 && renderer.sky_pipelines.fog.is_valid());
    target.scene.remove(fog);
    render_fog_frames(&fixture, &target, &fog_view)!!;
    assert(renderer.stats.post_dispatches == unfogged);
    check_validation(renderer);
}

fn void test_refracted_sample_is_fogged_to_its_own_depth() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    Node* bed = add_facing_plane(&target, add_unlit(&fixture, BED_COLOR)!!, BED_DISTANCE)!!;
    String[1] clear_defines = { "GLASS_CLEAR" };
    String[1] tinted_defines = { "GLASS_TINTED" };
    MaterialId clear = add_reader_material(&fixture, add_fog_reader(&fixture, clear_defines[..])!!)!!;
    MaterialId tinted = add_reader_material(&fixture, add_fog_reader(&fixture, tinted_defines[..])!!)!!;
    MaterialId blended_pane = add_blended_pane(&fixture)!!;
    Node* glass = add_facing_plane(&target, clear, READER_DISTANCE)!!;
    FogView fog_view = create_fog_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_fog_view(&fixture, &fog_view);
    FogRay to_bed = pixel_ray(&target, SKY_UPPER_ROW, BED_DISTANCE);
    FogRay to_glass = pixel_ray(&target, SKY_UPPER_ROW, READER_DISTANCE);

    Vec4[] plain = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(plain);
    check_rgb_close(pixel_at(plain, SKY_CENTRE, SKY_UPPER_ROW), BED_COLOR.xyz, "clear glass without fog");

    HeightFog fog = DENSE_FOG;
    Node* fog_node = add_fog(&target, fog)!!;
    Vec4[] full = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(full);
    Vec3 bed_fogged = fogged(&fog, to_bed, BED_COLOR.xyz);
    check_rgb_close(pixel_at(full, SKY_CENTRE, SKY_UPPER_ROW), bed_fogged, "clear glass in dense fog");

    target.scene.get(glass, Mesh).material = tinted;
    Vec4[] half = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(half);
    float glass_transmittance = light::height_fog_transmittance(
        fog:         &fog,
        base_height: 0,
        origin:      to_glass.origin,
        direction:   to_glass.direction,
        distance:    to_glass.distance,
    );
    Vec3 glass_inscatter = fog.albedo * FOG_AMBIENT * (1 - glass_transmittance);
    Vec3 expected = GLASS_HALF * bed_fogged + GLASS_COLOR * glass_transmittance + (1 - GLASS_HALF) * glass_inscatter;
    check_rgb_close(pixel_at(half, SKY_CENTRE, SKY_UPPER_ROW), expected, "half-transmitting glass");

    HeightFog* medium = target.scene.get(fog_node, HeightFog);
    target.scene.get(glass, Mesh).material = blended_pane;
    medium.density = 0;
    Vec4[] pane_clear = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(pane_clear);
    medium.density = fog.density;
    Vec4[] pane_fogged = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(pane_fogged);
    Vec3 pane = pixel_at(pane_clear, SKY_CENTRE, SKY_UPPER_ROW).xyz;
    assert(pane.x > 0.5f * BED_COLOR.x, "the pane transmits the bed: %f", pane.x);
    check_rgb_close(pixel_at(pane_fogged, SKY_CENTRE, SKY_UPPER_ROW), fogged(&fog, to_bed, pane), "blended pane");

    target.scene.get(glass, Mesh).material = clear;
    target.scene.remove(bed);
    Vec4[] sky = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(sky);
    Vec3 background = fogged_to_infinity(&fog, to_glass, SKY_BACKGROUND.xyz);
    check_rgb_close(pixel_at(sky, SKY_CENTRE, SKY_UPPER_ROW), background, "clear glass before the background");
    check_validation(&fixture.renderer);
}

fn void test_sky_regeneration_refills_environment_probes_in_place() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    add_facing_plane(&target, add_unlit(&fixture, BED_COLOR)!!, BED_DISTANCE)!!;
    Node* sun = add_sun(&target, { 0, math::sin(30 * DEGREE), math::cos(30 * DEGREE) }, 3)!!;
    Node* volume = target.scene.add_node(name: "volume")!!;
    target.scene.add(volume, light::probe_volume({ 4, 4, 4 }, { 2, 2, 2 }));
    FogView fog_view = create_fog_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_fog_view(&fixture, &fog_view);
    renderer.prepare_scene(&target.scene)!!;

    render_fog_frames(&fixture, &target, &fog_view, 1)!!;
    render_fog_frames(&fixture, &target, &fog_view, 1)!!;
    uint baseline = renderer.stats.post_dispatches;
    AtmosphereSelection selection = render::select_atmosphere(&target.scene);
    AtmosphereRes before = *render::find_atmosphere(renderer, target.scene.identity, selection.entity);
    assert(renderer.stats.sky_regenerations == 0);

    aim_node(sun, 31 * DEGREE);
    render_fog_frames(&fixture, &target, &fog_view, 1)!!;
    AtmosphereRes after = *render::find_atmosphere(renderer, target.scene.identity, selection.entity);
    assert(renderer.stats.sky_regenerations == 1);
    assert(renderer.stats.post_dispatches == baseline + ATLAS_DISPATCHES);
    assert(after.lighting.lighting_revision != before.lighting.lighting_revision);
    assert(after.lighting.source_cube == before.lighting.source_cube);
    assert(after.lighting.specular_cube == before.lighting.specular_cube);
    assert(after.lighting.irradiance_address == before.lighting.irradiance_address);

    aim_node(sun, 31.3f * DEGREE);
    render_fog_frames(&fixture, &target, &fog_view, 1)!!;
    assert(renderer.stats.sky_regenerations == 0 && renderer.stats.post_dispatches == baseline);
    check_validation(renderer);
}

fn void test_mirror_view_fogs_behind_its_plane() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    Node* bed = add_facing_plane(&target, add_unlit(&fixture, BED_COLOR)!!, BED_DISTANCE)!!;
    HeightFog fog = TEST_FOG;
    add_fog(&target, fog)!!;
    Vec3 down_the_view = { 0, -math::sin(MIRROR_PITCH), -math::cos(MIRROR_PITCH) };
    target.camera.local.rotation = maths::look_rotation(down_the_view, { 0, 1, 0 });
    Node* mirror = target.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "mirror")!!;
    Mat4 mirrored = maths::reflection_matrix(WATER_PLANE).mul(target.camera.local.to_mat4());
    mirror.local = maths::transform_from_affine(mirrored)!!;
    target.camera = mirror;
    target.scene.update_world();
    FogView fog_view = create_fog_view(&fixture, ShadingPath.FORWARD, WATER_PLANE)!!;
    defer destroy_fog_view(&fixture, &fog_view);

    FogRay to_bed = pixel_ray(&target, SKY_CENTRE, BED_DISTANCE);
    float entry = -to_bed.origin.y / to_bed.direction.y;
    assert(entry > 0 && entry < to_bed.distance, "the centre ray crosses the plane before the bed: %f", entry);
    Vec4[] pixels = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(pixels);
    Vec3 expected = fogged(&fog, ray_beyond(to_bed, entry), BED_COLOR.xyz);
    check_rgb_close(pixel_at(pixels, SKY_CENTRE, SKY_CENTRE), expected, "object behind the plane");

    target.scene.remove(bed);
    Vec4[] open = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(open);
    Vec3 background = fogged_to_infinity(&fog, ray_beyond(to_bed, entry), SKY_BACKGROUND.xyz);
    check_rgb_close(pixel_at(open, SKY_CENTRE, SKY_CENTRE), background, "background behind the plane");
    check_validation(&fixture.renderer);
}

fn void test_fog_volume_without_a_sun_equals_the_analytic_fog() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    Node* bed = add_facing_plane(&target, add_unlit(&fixture, BED_COLOR)!!, 30)!!;
    HeightFog fog = volume_fog();
    add_fog(&target, fog)!!;
    FogView fog_view = create_fog_view(&fixture, ShadingPath.FORWARD, volumetric_fog: true)!!;
    defer destroy_fog_view(&fixture, &fog_view);
    uint[2] rows = { SKY_CENTRE, FROXEL_UPPER_ROW };

    float[2] distances = { 30, BED_DISTANCE };
    foreach (distance : distances) {
        bed.local.position.z = -distance;
        Vec4[] pixels = render_fog_pixels(&fixture, &target, &fog_view)!!;
        defer free(pixels);
        foreach (row : rows) {
            Vec3 expected = fogged(&fog, pixel_ray(&target, row, distance), BED_COLOR.xyz);
            check_rgb_close(pixel_at(pixels, SKY_CENTRE, row), expected, distance < VOLUME_END ? "inside" : "beyond");
        }
    }

    FogView clipped = create_fog_view(
        fixture:        &fixture,
        shading:        ShadingPath.FORWARD,
        clip_plane:     { .normal = { 0, 0, -1 }, .d = -CLIP_DISTANCE },
        volumetric_fog: true,
    )!!;
    defer destroy_fog_view(&fixture, &clipped);
    bed.local.position.z = -30;
    Vec4[] clipped_pixels = render_fog_pixels(&fixture, &target, &clipped)!!;
    defer free(clipped_pixels);
    foreach (row : rows) {
        FogRay ray = pixel_ray(&target, row, 30);
        Vec3 expected = fogged(&fog, ray_beyond(ray, CLIP_DISTANCE / -ray.direction.z), BED_COLOR.xyz);
        check_rgb_close(pixel_at(clipped_pixels, SKY_CENTRE, row), expected, "clipped");
    }

    target.scene.remove(bed);
    Vec4[] background = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(background);
    Vec3 expected = fogged_to_infinity(&fog, pixel_ray(&target, FROXEL_UPPER_ROW), SKY_BACKGROUND.xyz);
    check_rgb_close(pixel_at(background, SKY_CENTRE, FROXEL_UPPER_ROW), expected, "background");
    check_validation(&fixture.renderer);
}

fn void test_fog_volume_scatters_the_sun_and_continues_past_its_end() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    Node* bed = add_facing_plane(&target, add_unlit(&fixture, BED_COLOR)!!, VOLUME_END)!!;
    HeightFog fog = volume_fog();
    add_fog(&target, fog)!!;
    float elevation = VOLUME_SUN_DEGREES * DEGREE;
    Vec3 to_sun = { 0, math::sin(elevation), -math::cos(elevation) };
    add_plain_sun(&target, to_sun, false)!!;
    FogView fog_view = create_fog_view(&fixture, ShadingPath.FORWARD, volumetric_fog: true)!!;
    defer destroy_fog_view(&fixture, &fog_view);
    uint[2] rows = { SKY_CENTRE, FROXEL_UPPER_ROW };

    float[2] distances = { VOLUME_END - 1, VOLUME_END + 1 };
    foreach (distance : distances) {
        bed.local.position.z = -distance;
        Vec4[] pixels = render_fog_pixels(&fixture, &target, &fog_view)!!;
        defer free(pixels);
        foreach (row : rows) {
            FogRay ray = pixel_ray(&target, row, distance);
            Vec3 color = volume_color(&fog, ray.direction, to_sun, VOLUME_SUN_INTENSITY);
            Vec3 expected = volume_fogged(&fog, ray, BED_COLOR.xyz, color);
            check_rgb_close(pixel_at(pixels, SKY_CENTRE, row), expected, distance < VOLUME_END ? "inside" : "outside");
        }
    }

    target.scene.remove(bed);
    Vec4[] background = render_fog_pixels(&fixture, &target, &fog_view)!!;
    defer free(background);
    FogRay above = pixel_ray(&target, FROXEL_UPPER_ROW);
    Vec3 color = volume_color(&fog, above.direction, to_sun, VOLUME_SUN_INTENSITY);
    Vec3 expected = volume_fogged_background(&fog, above, SKY_BACKGROUND.xyz, color);
    check_rgb_close(pixel_at(background, SKY_CENTRE, FROXEL_UPPER_ROW), expected, "background");
    check_validation(&fixture.renderer);
}

// Centre pixel of a view that sees the bed at 80 m under a roof shading the first 60 m of the ray.
fn Vec4? roof_pixel(Fixture* fixture, FogScene* target, FogView* fog_view) @private {
    Vec4[] pixels = render_fog_pixels(fixture, target, fog_view)!;
    defer free(pixels);
    return pixel_at(pixels, SKY_CENTRE, SKY_CENTRE);
}

fn void check_volume_shadow(bool traced, bool ray_queries) @private {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    add_facing_plane(&target, add_unlit(&fixture, BED_COLOR)!!, BED_DISTANCE)!!;
    GeometryId roof_plane;
    @pool() {
        Geometry plane = geometry::plane(tmem, ROOF_LENGTH, ROOF_LENGTH);
        roof_plane = fixture.assets.add_geometry(&plane)!!;
    };
    Node* roof = target.scene.add_mesh(roof_plane, add_unlit(&fixture, BED_COLOR)!!)!!;
    roof.local.position = { 0, ROOF_HEIGHT, -ROOF_LENGTH / 2 };
    add_fog(&target, TEST_FOG)!!;
    Node* sun = add_plain_sun(&target, { 0, 1, 0 }, true)!!;
    Light* light = target.scene.get(sun, Light);
    light.shadow.cascades = 1; // the fixture's atlas holds one layer
    light.shadow.ray_traced = traced;
    FogView fog_view = create_fog_view(&fixture, ShadingPath.FORWARD, volumetric_fog: true)!!;
    defer destroy_fog_view(&fixture, &fog_view);
    ViewDesc desc = renderer.views.get(fog_view.view).desc;
    desc.ray_tracing.shadows = traced;
    render::configure_view(renderer, fog_view.view, desc)!!;

    Vec4 shadowed = roof_pixel(&fixture, &target, &fog_view)!!;
    target.scene.get(roof, Mesh).cast_shadow = false;
    Vec4 lit = roof_pixel(&fixture, &target, &fog_view)!!;
    light.intensity = 0;
    Vec4 unlit = roof_pixel(&fixture, &target, &fog_view)!!;
    float share = kept_share(shadowed, unlit, lit);
    assert(share > SHADOWED_SHARE_MIN && share < SHADOWED_SHARE_MAX, "traced %s: kept %f", traced, share);

    if (!traced) {
        light.intensity = VOLUME_SUN_INTENSITY;
        target.scene.get(roof, Mesh).cast_shadow = true;
        light.shadow.max_distance = SHORT_SHADOW_DISTANCE;
        Vec4 short_atlas = roof_pixel(&fixture, &target, &fog_view)!!;
        float short_share = kept_share(short_atlas, unlit, lit);
        assert(short_share > SHORT_SHARE_MIN, "short atlas: kept %f", short_share);
    }
    check_validation(renderer);
}

fn void test_fog_volume_shadows_the_sun_by_atlas_and_by_rays() @test {
    check_volume_shadow(false, false);
    foreach (ray_queries : TRACE_KINDS) check_volume_shadow(true, ray_queries);
}

fn void test_volumetric_fog_follows_the_view_switch() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    FogScene target = create_fog_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    add_facing_plane(&target, add_unlit(&fixture, BED_COLOR)!!, BED_DISTANCE)!!;
    FogView plain = create_fog_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_fog_view(&fixture, &plain);
    FogView volume = create_fog_view(&fixture, ShadingPath.FORWARD, volumetric_fog: true)!!;
    defer destroy_fog_view(&fixture, &volume);
    ViewRecord* record = renderer.views.get(volume.view);
    assert(record.fog_volume.texture.is_valid() && record.fog_volume.width == 3);
    assert(record.fog_volume.depth == shader::FOG_VOLUME_SLICES);

    render_fog_frames(&fixture, &target, &plain)!!;
    uint unfogged = renderer.stats.post_dispatches;
    render_fog_frames(&fixture, &target, &volume)!!;
    assert(renderer.stats.post_dispatches == unfogged && !renderer.sky_pipelines.fog_integration.is_valid());

    add_fog(&target, TEST_FOG)!!;
    render_fog_frames(&fixture, &target, &plain)!!;
    uint fogged_plain = renderer.stats.post_dispatches;
    render_fog_frames(&fixture, &target, &volume)!!;
    assert(renderer.stats.post_dispatches == fogged_plain + 2);

    ViewDesc desc = record.desc;
    desc.volumetric_fog = false;
    render::configure_view(renderer, volume.view, desc)!!;
    assert(!record.fog_volume.texture.is_valid());
    render_fog_frames(&fixture, &target, &volume)!!;
    assert(renderer.stats.post_dispatches == fogged_plain);
    check_validation(renderer);
}
