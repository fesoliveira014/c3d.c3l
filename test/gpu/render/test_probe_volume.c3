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
import gpu;
import std::io;
import std::math;

const char[*] PROBE_TWINS_SOURCE @private = $embed("probe_twins.comp.glsl");
const uint PROBE_TARGET_WIDTH @private = 128;
const uint PROBE_TARGET_HEIGHT @private = 96;
const uint SKY_WIDTH @private = 64;
const uint SKY_HEIGHT @private = 32;
const Vec3 SKY_RADIANCE @private = { 0.5f, 0.5f, 0.5f };
const Vec3 EDITED_SKY_RADIANCE @private = { 0.8f, 0.3f, 0.3f };
const Vec3 GROUND_RADIANCE @private = { 0.05f, 0.025f, 0.0125f };
const Vec3 PROBE_CAMERA_POSITION @private = { 0, 6, 7 };
const Vec3 PROBE_CAMERA_TARGET @private = { 0, 0, 0 };
const Vec3 VOLUME_CENTER @private = { 0, 1, 0 };
const Vec3 VOLUME_HALF_EXTENTS @private = { 4, 1, 4 };
const uint[<3>] PLAIN_COUNTS @private = { 8, 4, 8 };
const uint[<3>] WRAPPED_COUNTS @private = { 32, 4, 32 }; // 8 slices per row, 4 rows
const Vec3 FLOOR_INSIDE @private = { 2, 0, 1 };
const Vec3 BOX_FACE @private = { 0, 1, 0.5f };
const Vec3 FLOOR_OUTSIDE @private = { 4.6f, 0, 1 };
const Vec3 INTERIOR_HALF_EXTENTS @private = { 1, 1, 1 };
const Vec3 INTERIOR_CENTER @private = { 2, 1, 1 };
const Vec3 EXTERIOR_ONLY_POINT @private = { -2, 0, 1 };
const float FLOOR_ALBEDO @private = 0.8f;
const float TURN_DEGREES @private = 30;
const int PROBE_CHANNEL_TOLERANCE @private = 2;
const uint FILL_DISPATCHES @private = 4; // fill and border for each of the two atlases
const uint ATLAS_DISPATCHES @private = 2;
const usz TWIN_DIRECTIONS @private = 64;
const float TWIN_TOLERANCE @private = 1e-5f;

struct ProbeScene @private {
    Scene         scene;
    Node*         camera;
    Node*         volume;
    TextureId     sky;
    EnvironmentId environment;
}

struct ProbeView @private {
    RenderTargetId target;
    ViewId         view;
}

struct ProbeTwinRoot @private {
    gpu::GpuAddress output_address;
    ulong           padding;
}
$assert ProbeTwinRoot::size == 16;

fn void write_sky(char[] pixels, Vec3 sky) @private {
    float[] texels = ((float*)pixels.ptr)[:pixels.len / float::size];
    for (uint y = 0; y < SKY_HEIGHT; y++) {
        Vec3 radiance = y < SKY_HEIGHT / 2 ? sky : GROUND_RADIANCE;
        for (uint x = 0; x < SKY_WIDTH; x++) {
            usz first = ((usz)y * SKY_WIDTH + x) * 4;
            texels[first] = radiance.x;
            texels[first + 1] = radiance.y;
            texels[first + 2] = radiance.z;
            texels[first + 3] = 1;
        }
    }
}

fn ProbeScene? create_probe_scene(Fixture* fixture, bool toon_floor = false) @private {
    ProbeScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);

    char[] pixels = alloc::new_array(tmem, char, (usz)SKY_WIDTH * SKY_HEIGHT * 4 * float::size);
    write_sky(pixels, SKY_RADIANCE);
    material::TextureDesc sky_desc = material::texture_2d_desc(
        width: SKY_WIDTH,
        height: SKY_HEIGHT,
        format: RGBA32_FLOAT,
        debug_name: "probe_sky",
    );
    result.sky = fixture.assets.add_texture(sky_desc, pixels)!;
    result.environment = fixture.assets.add_environment(light::texture_environment(result.sky))!;
    result.scene.environment = result.environment;

    GeometryId floor;
    GeometryId box;
    @pool() {
        Geometry plane = geometry::plane(tmem, 10, 10);
        floor = fixture.assets.add_geometry(&plane)!;
        Geometry pillar = geometry::box(tmem, 1, 2, 1);
        box = fixture.assets.add_geometry(&pillar)!;
    };
    StandardParams grey = { .base_color = { FLOOR_ALBEDO, FLOOR_ALBEDO, FLOOR_ALBEDO, 1 }, .roughness = 1 };
    MaterialId surface = fixture.assets.add_material(material::standard(grey))!;
    ToonParams toon = material::TOON_PARAMS_DEFAULT;
    toon.color = { FLOOR_ALBEDO, FLOOR_ALBEDO, FLOOR_ALBEDO, 1 };
    MaterialId toon_surface = fixture.assets.add_material(material::toon(toon))!;
    result.scene.add_mesh(floor, toon_floor ? toon_surface : surface, name: "floor")!;
    Node* pillar_node = result.scene.add_mesh(box, surface, name: "pillar")!;
    pillar_node.local.position = { 0, 1, 0 };

    result.volume = result.scene.add_node(name: "volume")!;
    result.volume.local.position = VOLUME_CENTER;
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    result.camera.local.position = PROBE_CAMERA_POSITION;
    result.camera.local.rotation = maths::look_rotation(
        (PROBE_CAMERA_TARGET - PROBE_CAMERA_POSITION).normalize(),
        { 0, 1, 0 },
    );
    result.scene.update_world();
    return result;
}

fn ProbeView? create_probe_view(Fixture* fixture, ShadingPath shading) @private {
    ProbeView result;
    result.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(PROBE_TARGET_WIDTH, PROBE_TARGET_HEIGHT),
    )!;
    ViewDesc desc = render::texture_view_desc(result.target);
    desc.shading = shading;
    result.view = render::create_view(&fixture.renderer, desc)!;
    return result;
}

fn void destroy_probe_view(Fixture* fixture, ProbeView* probe_view) @private {
    render::destroy_view(&fixture.renderer, probe_view.view)!!;
    render::destroy_render_target(&fixture.renderer, probe_view.target)!!;
}

fn Vec2 project_probe_uv(ProbeScene* probe, Vec3 point) @private {
    Camera* camera = probe.scene.get(probe.camera, Camera);
    CameraMatrices matrices = camera::derive_matrices(
        *camera,
        probe.camera.world,
        { PROBE_TARGET_WIDTH, PROBE_TARGET_HEIGHT },
    );
    Vec4 clip = matrices.view_proj * (Vec4){ point.x, point.y, point.z, 1 };
    return { clip.x / clip.w * 0.5f + 0.5f, 0.5f - clip.y / clip.w * 0.5f };
}

fn uint? render_probe_pixel(Fixture* fixture, ProbeScene* probe, ViewId view, Vec3 point) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&probe.scene, probe.camera, view)!;
    sample(fixture, render::read_view_color(view), project_probe_uv(probe, point))!;
    record_readback(fixture)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
    return read_pixel(fixture);
}

fn uint? render_dispatches(Fixture* fixture, ProbeScene* probe, ViewId[] views) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    foreach (view : views) {
        renderer.render_view(&probe.scene, probe.camera, view)!;
        renderer.finish_view(view)!;
    }
    renderer.end_frame()!;
    return renderer.stats.post_dispatches;
}

fn void assert_channels_close(uint first, uint second, int tolerance) @private {
    for (uint channel = 0; channel < 3; channel++) {
        int before = (int)((first >> (8 * channel)) & 0xff);
        int after = (int)((second >> (8 * channel)) & 0xff);
        assert(math::abs(before - after) <= tolerance);
    }
}

fn Vec3 twin_direction(uint index) @private {
    Vec3 lattice = { (float)(index % 4) - 1.5f, (float)((index / 4) % 4) - 1.5f, (float)(index / 16) - 1.5f };
    return lattice.normalize();
}

fn void test_probe_fill_dispatches_follow_the_identity() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    print_adapter(&fixture);
    ProbeScene probe = create_probe_scene(&fixture)!!;
    defer scene::destroy_scene(&probe.scene);
    ProbeView probe_view = create_probe_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_probe_view(&fixture, &probe_view);
    ViewId[1] one = { probe_view.view };

    (void)render_dispatches(&fixture, &probe, one[..])!!;
    uint baseline = render_dispatches(&fixture, &probe, one[..])!!;
    probe.scene.add(probe.volume, light::probe_volume(VOLUME_HALF_EXTENTS, PLAIN_COUNTS));
    assert(render_dispatches(&fixture, &probe, one[..])!! == baseline + FILL_DISPATCHES);
    assert(render_dispatches(&fixture, &probe, one[..])!! == baseline);

    probe.scene.environment_rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::deg_to_rad(TURN_DEGREES));
    assert(render_dispatches(&fixture, &probe, one[..])!! == baseline + ATLAS_DISPATCHES);
    probe.scene.get(probe.volume, ProbeVolume).max_distance += 1;
    assert(render_dispatches(&fixture, &probe, one[..])!! == baseline + ATLAS_DISPATCHES);

    ProbeScene second = create_probe_scene(&fixture)!!;
    defer scene::destroy_scene(&second.scene);
    second.scene.add(second.volume, light::probe_volume(VOLUME_HALF_EXTENTS, PLAIN_COUNTS));
    ProbeView other_view = create_probe_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_probe_view(&fixture, &other_view);
    ViewId[2] two = { probe_view.view, other_view.view };
    assert(render_dispatches(&fixture, &second, two[..])!! == 2 * baseline + FILL_DISPATCHES);
    check_validation(&fixture.renderer);
}

fn void check_volume_matches_the_sh(Fixture* fixture, uint[<3>] counts) @private {
    ProbeScene probe = create_probe_scene(fixture)!!;
    defer scene::destroy_scene(&probe.scene);
    probe.scene.add(probe.volume, light::probe_volume(VOLUME_HALF_EXTENTS, counts));

    ShadingPath[2] paths = { ShadingPath.FORWARD, ShadingPath.DEFERRED };
    Vec3[3] points = { FLOOR_INSIDE, BOX_FACE, FLOOR_OUTSIDE };
    foreach (shading : paths) {
        ProbeView probe_view = create_probe_view(fixture, shading)!!;
        defer destroy_probe_view(fixture, &probe_view);
        foreach (index, point : points) {
            probe.volume.visible = true;
            probe.scene.update_world();
            uint with = render_probe_pixel(fixture, &probe, probe_view.view, point)!!;
            probe.volume.visible = false;
            probe.scene.update_world();
            uint without = render_probe_pixel(fixture, &probe, probe_view.view, point)!!;
            io::eprintfn("%s %s point %d: volume %08x, sh %08x", shading, counts, index, with, without);
            assert_channels_close(with, without, point == FLOOR_OUTSIDE ? 0 : PROBE_CHANNEL_TOLERANCE);
        }
    }
}

fn void test_environment_filled_volume_matches_the_sh() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    check_volume_matches_the_sh(&fixture, PLAIN_COUNTS);
    check_volume_matches_the_sh(&fixture, WRAPPED_COUNTS);
    check_validation(&fixture.renderer);
}

fn void test_source_edit_refills_the_volume() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ProbeScene probe = create_probe_scene(&fixture)!!;
    defer scene::destroy_scene(&probe.scene);
    probe.scene.add(probe.volume, light::probe_volume(VOLUME_HALF_EXTENTS, PLAIN_COUNTS));
    ProbeView probe_view = create_probe_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_probe_view(&fixture, &probe_view);

    (void)render_probe_pixel(&fixture, &probe, probe_view.view, FLOOR_INSIDE)!!;
    write_sky(fixture.assets.texture(probe.sky).pixels, EDITED_SKY_RADIANCE);
    fixture.assets.mark_texture_dirty(probe.sky);
    uint with = render_probe_pixel(&fixture, &probe, probe_view.view, FLOOR_INSIDE)!!;
    probe.volume.visible = false;
    probe.scene.update_world();
    uint without = render_probe_pixel(&fixture, &probe, probe_view.view, FLOOR_INSIDE)!!;
    io::eprintfn("edited sky: volume %08x, sh %08x", with, without);
    assert_channels_close(with, without, PROBE_CHANNEL_TOLERANCE);
    check_validation(&fixture.renderer);
}

fn void test_nested_volumes_select_the_smallest_box() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ProbeScene probe = create_probe_scene(&fixture, toon_floor: true)!!;
    defer scene::destroy_scene(&probe.scene);
    ProbeView probe_view = create_probe_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_probe_view(&fixture, &probe_view);

    uint interior_sh = render_probe_pixel(&fixture, &probe, probe_view.view, INTERIOR_CENTER - { 0, 1, 0 })!!;
    uint exterior_sh = render_probe_pixel(&fixture, &probe, probe_view.view, EXTERIOR_ONLY_POINT)!!;

    probe.scene.add(probe.volume, light::probe_volume(VOLUME_HALF_EXTENTS, PLAIN_COUNTS));
    Node* interior = probe.scene.add_node(name: "interior")!!;
    interior.local.position = INTERIOR_CENTER;
    ProbeVolume dark = light::probe_volume(INTERIOR_HALF_EXTENTS, { 3, 3, 3 });
    dark.energy = 0;
    probe.scene.add(interior, dark);
    probe.scene.update_world();

    uint interior_pixel = render_probe_pixel(&fixture, &probe, probe_view.view, INTERIOR_CENTER - { 0, 1, 0 })!!;
    uint exterior_pixel = render_probe_pixel(&fixture, &probe, probe_view.view, EXTERIOR_ONLY_POINT)!!;
    io::eprintfn("nested: interior %08x (sh %08x)", interior_pixel, interior_sh);
    io::eprintfn("nested: exterior %08x (sh %08x)", exterior_pixel, exterior_sh);
    assert((interior_pixel & 0xffffff) == 0);
    assert_channels_close(exterior_pixel, exterior_sh, PROBE_CHANNEL_TOLERANCE);

    interior.visible = false;
    probe.scene.update_world();
    uint uncovered = render_probe_pixel(&fixture, &probe, probe_view.view, INTERIOR_CENTER - { 0, 1, 0 })!!;
    assert_channels_close(uncovered, interior_sh, PROBE_CHANNEL_TOLERANCE);
    check_validation(&fixture.renderer);
}

fn void test_probe_atlas_glsl_matches_the_c3_twins() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;

    uint[<3>][2] counts = { { 17, 4, 20 }, { 32, 3, 32 } };
    uint[2] edges = { shader::PROBE_IRRADIANCE_CELL, shader::PROBE_VISIBILITY_CELL };
    usz slots;
    foreach (volume : counts) slots += (usz)volume.x * volume.y * volume.z + edges.len;
    foreach (edge : edges) slots += TWIN_DIRECTIONS + (usz)edge * edge;
    usz bytes = slots * Vec2::size;

    ComputeShaderId twins = add_compute_shader(&fixture, (String)PROBE_TWINS_SOURCE[..])!!;
    BufferId output = renderer.create_buffer({ .size = bytes, .debug_name = "probe_twins_output" })!!;
    gpu::AllocationDesc readback_desc = {
        .size         = bytes,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "probe_twins_readback",
    };
    gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &readback_desc)!!;
    defer {
        render::wait_frames(renderer)!!;
        gpu::GpuAllocation allocation = readback.span.allocation();
        gpu::free_allocation(&renderer.device, &allocation)!!;
    }

    renderer.begin_frame()!!;
    ProbeTwinRoot root = { .output_address = renderer.buffer_address(output) };
    BufferId[1] writes = { output };
    renderer.dispatch({
        .shader = twins,
        .root   = ((char*)&root)[:ProbeTwinRoot::size],
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
    Vec2[] results = ((Vec2*)readback.bytes.ptr)[:slots];

    usz slot;
    foreach (volume : counts) {
        uint slices_per_row = render::probe_slices_per_row(volume);
        for (uint z = 0; z < volume.z; z++) {
            for (uint y = 0; y < volume.y; y++) {
                for (uint x = 0; x < volume.x; x++) {
                    assert(results[slot++] == (Vec2)render::probe_cell(volume, slices_per_row, { x, y, z }));
                }
            }
        }
        foreach (edge : edges) assert(results[slot++] == (Vec2)render::probe_atlas_extent(volume, edge));
    }
    foreach (edge : edges) {
        for (uint index = 0; index < TWIN_DIRECTIONS; index++) {
            Vec2 expected = render::probe_atlas_texel({ 3, 2 }, edge, twin_direction(index));
            Vec2 found = results[slot++];
            assert(math::abs(found.x - expected.x) <= TWIN_TOLERANCE);
            assert(math::abs(found.y - expected.y) <= TWIN_TOLERANCE);
        }
        for (uint y = 0; y < edge; y++) {
            for (uint x = 0; x < edge; x++) {
                assert(results[slot++] == (Vec2)render::probe_border_source(edge, { x, y }));
            }
        }
    }
    assert(slot == slots);
    check_validation(renderer);
}

fn void test_removing_the_component_releases_the_atlases() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ProbeScene probe = create_probe_scene(&fixture)!!;
    defer scene::destroy_scene(&probe.scene);
    probe.scene.add(probe.volume, light::probe_volume(VOLUME_HALF_EXTENTS, PLAIN_COUNTS));
    ProbeView probe_view = create_probe_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_probe_view(&fixture, &probe_view);
    ViewId[1] one = { probe_view.view };

    (void)render_dispatches(&fixture, &probe, one[..])!!;
    bool held;
    foreach (&mirror : fixture.renderer.probe_volumes) held |= mirror.scene == probe.scene.identity;
    assert(held);

    probe.scene.remove_component(probe.volume, ProbeVolume);
    (void)render_dispatches(&fixture, &probe, one[..])!!;
    foreach (&mirror : fixture.renderer.probe_volumes) {
        assert(mirror.scene != probe.scene.identity || mirror.entity.generation == 0);
    }
    check_validation(&fixture.renderer);
}
