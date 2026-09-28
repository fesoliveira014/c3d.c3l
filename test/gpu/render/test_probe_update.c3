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

const Vec3 ROOM_CENTER @private = { 0, 1.5f, 0 };        // outer 4 x 3 x 4, walls 0.2 thick, inner 3.6 x 2.6 x 3.6
const Vec3 ROOM_OUTER @private = { 4, 3, 4 };
const float ROOM_WALL @private = 0.2f;
const Vec3 ROOM_VOLUME_HALF_EXTENTS @private = { 1.9f, 1.4f, 1.9f }; // outer probes 0.1 inside the walls; floor 0.1 inside
const uint[<3>] ROOM_COUNTS @private = { 6, 4, 6 };
const Vec3 FAR_AWAY @private = { 30, 0, 0 };             // the open-sky volume's place, far from the room
const Vec3 SKY_VOLUME_HALF_EXTENTS @private = { 3, 1.1f, 3 }; // the floor at y = 0 lies 0.1 inside
const Vec3 SKY_VOLUME_OFFSET @private = { 0, 1, 0 };
const uint[<3>] SKY_COUNTS @private = { 4, 3, 4 };
const Vec3 SKY_FLOOR_POINT @private = { 2.5f, 0, 1.5f }; // away from the pillar, whose occlusion the SH lacks
const Vec3 SUN_TOWARD_GROUND @private = { -0.4f, -1, -0.3f };
const float SUN_INTENSITY_ACCEPTANCE @private = 3;
const float DARK_SHARE @private = 0.01f;               // of the lit mean; probes inside the walls still see a few grazing rays
const float LIT_IRRADIANCE @private = 0.05f;
const uint OPEN_ROOM_UPDATES @private = 30;
const uint STABILITY_FIRST @private = 250;
const uint STABILITY_SECOND @private = 300;
const float STABILITY_TOLERANCE @private = 0.01f;       // relative change of the mean irradiance over 50 updates
const float HIGH_ENERGY @private = 4;
const char[*] PROBE_READBACK_SOURCE @private = $embed("probe_readback.comp.glsl");
const uint PROBE_READBACK_GROUP @private = 8; // mirrored as local_size_x and local_size_y in probe_readback.comp.glsl
const uint SKY_SPREAD_FRAMES @private = 8;
const float SKY_TEXEL_TOLERANCE @private = 0.05f;         // of the expected irradiance; set from the measured spread
const float FAST_HYSTERESIS @private = 0.5f;            // converges in tens of updates, so stability is what is measured

struct ProbeRoom @private {
    Scene scene;
    Node* camera;
    Node* roof;
    Node* volume;
    Node* sun;
    Node* lamp;
}

struct ProbeReadbackRoot @private {
    gpu::GpuAddress   output_address;
    gpu::TextureIndex atlas;
    uint              width;
    uint              height;
    uint              padding;
}
$assert ProbeReadbackRoot::size == 24;

fn Vec4f[]? read_atlas(Fixture* fixture, Target* atlas) @private {
    Renderer* renderer = &fixture.renderer;
    usz texels = (usz)atlas.width * atlas.height;
    usz bytes = texels * Vec4f::size;
    ComputeShaderId shader = add_compute_shader(fixture, (String)PROBE_READBACK_SOURCE[..])!;
    BufferId output = renderer.create_buffer({ .size = bytes, .debug_name = "probe_readback_output" })!;
    gpu::AllocationDesc readback_desc = {
        .size         = bytes,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "probe_readback",
    };
    gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &readback_desc)!;
    defer {
        (void)render::wait_frames(renderer);
        gpu::GpuAllocation allocation = readback.span.allocation();
        (void)gpu::free_allocation(&renderer.device, &allocation);
    }

    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    ProbeReadbackRoot root = {
        .output_address = renderer.buffer_address(output),
        .atlas          = atlas.view.index,
        .width          = atlas.width,
        .height         = atlas.height,
    };
    BufferId[1] writes = { output };
    uint groups_x = (atlas.width + PROBE_READBACK_GROUP - 1) / PROBE_READBACK_GROUP;
    uint groups_y = (atlas.height + PROBE_READBACK_GROUP - 1) / PROBE_READBACK_GROUP;
    renderer.dispatch({
        .shader = shader,
        .root   = ((char*)&root)[:ProbeReadbackRoot::size],
        .groups = { groups_x, groups_y, 1 },
        .writes = writes[..],
    })!;
    gpu::Barrier written = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &written)!;
    gpu::BufferCopyDesc copy = {
        .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(output).allocation)!,
        .dst = readback.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host_read)!;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, readback.span)!;
    Vec4f[] values = alloc::new_array(tmem, Vec4f, (sz)texels);
    mem::copy(values.ptr, readback.bytes.ptr, (sz)bytes);
    return values;
}

fn void assert_finite(Vec4f[] values) @private {
    foreach (value : values) {
        for (usz channel = 0; channel < 4; channel++) assert(math::is_finite(value[channel]));
    }
}

fn ProbeVolumeRes* mirror_of(Fixture* fixture, Scene* scene, Node* node) @private {
    foreach (&mirror : fixture.renderer.probe_volumes) {
        if (mirror.scene == scene.identity && c3d::same_id(mirror.entity, node.id)) return mirror;
    }
    return null;
}

// Mean irradiance channel over the interior texels of the probes that are not in a wall.
fn float interior_irradiance(Fixture* fixture, ProbeRoom* room) @private {
    ProbeVolumeRes* mirror = mirror_of(fixture, &room.scene, room.volume);
    Vec4f[] texels = read_atlas(fixture, &mirror.irradiance)!!;
    assert_finite(texels);
    uint edge = shader::PROBE_IRRADIANCE_CELL;
    float sum;
    uint samples;
    for (uint z = 1; z + 1 < ROOM_COUNTS.z; z++) {
        for (uint y = 1; y + 1 < ROOM_COUNTS.y; y++) {
            for (uint x = 1; x + 1 < ROOM_COUNTS.x; x++) {
                uint[<2>] cell = render::probe_cell(ROOM_COUNTS, mirror.slices_per_row, { x, y, z });
                for (uint texel_y = 1; texel_y + 1 < edge; texel_y++) {
                    for (uint texel_x = 1; texel_x + 1 < edge; texel_x++) {
                        usz texel = (usz)(cell.y * edge + texel_y) * mirror.irradiance.width + (usz)(cell.x * edge + texel_x);
                        for (usz channel = 0; channel < 3; channel++) {
                            sum += texels[texel][channel];
                            samples++;
                        }
                    }
                }
            }
        }
    }
    return sum / (float)samples;
}

fn Node*? add_slab(Scene* scene, MaterialId material, GeometryId box, Vec3 center, Vec3 size, String name) @private {
    Node* node = scene.add_mesh(box, material, name: name)!;
    node.local.position = center;
    node.local.scale = size;
    return node;
}

fn ProbeRoom? create_probe_room(Fixture* fixture, bool lamp = false) @private {
    ProbeRoom room;
    room.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&room.scene);

    GeometryId unit_box;
    GeometryId ground;
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        unit_box = fixture.assets.add_geometry(&box)!;
        Geometry plane = geometry::plane(tmem, 12, 12);
        ground = fixture.assets.add_geometry(&plane)!;
    };
    StandardParams grey = { .base_color = { 0.8f, 0.8f, 0.8f, 1 }, .roughness = 1 };
    MaterialId surface = fixture.assets.add_material(material::standard(grey))!;
    char[] pixels = alloc::new_array(tmem, char, (usz)SKY_WIDTH * SKY_HEIGHT * 4 * float::size);
    write_sky(pixels, SKY_RADIANCE);
    material::TextureDesc sky_desc = material::texture_2d_desc(
        width: SKY_WIDTH,
        height: SKY_HEIGHT,
        format: RGBA32_FLOAT,
        debug_name: "probe_room_sky",
    );
    TextureId sky = fixture.assets.add_texture(sky_desc, pixels)!;
    room.scene.environment = fixture.assets.add_environment(light::texture_environment(sky))!;

    float wall = ROOM_WALL;
    Vec3 outer = ROOM_OUTER;
    add_slab(&room.scene, surface, unit_box, { 0, wall / 2, 0 }, { outer.x, wall, outer.z }, "floor")!;
    room.roof = add_slab(&room.scene, surface, unit_box, { 0, outer.y - wall / 2, 0 }, { outer.x, wall, outer.z }, "roof")!;
    add_slab(&room.scene, surface, unit_box, { -(outer.x - wall) / 2, outer.y / 2, 0 }, { wall, outer.y, outer.z }, "west")!;
    add_slab(&room.scene, surface, unit_box, { (outer.x - wall) / 2, outer.y / 2, 0 }, { wall, outer.y, outer.z }, "east")!;
    add_slab(&room.scene, surface, unit_box, { 0, outer.y / 2, -(outer.z - wall) / 2 }, { outer.x, outer.y, wall }, "north")!;
    add_slab(&room.scene, surface, unit_box, { 0, outer.y / 2, (outer.z - wall) / 2 }, { outer.x, outer.y, wall }, "south")!;
    Node* open_ground = room.scene.add_mesh(ground, surface, name: "open_ground")!;
    open_ground.local.position = FAR_AWAY;

    room.sun = room.scene.add_light(light::directional({ 1, 1, 1 }, SUN_INTENSITY_ACCEPTANCE), name: "sun")!;
    room.sun.local.rotation = maths::look_rotation(SUN_TOWARD_GROUND.normalize(), { 0, 0, -1 });
    if (lamp) {
        room.sun.visible = false;
        room.lamp = room.scene.add_light(light::point({ 1, 0.9f, 0.8f }, 2, 3), name: "lamp")!;
        room.lamp.local.position = ROOM_CENTER + { 0.3f, 0.4f, 0.2f };
    }

    room.volume = room.scene.add_node(name: "volume")!;
    room.volume.local.position = ROOM_CENTER;
    room.scene.add(room.volume, light::probe_volume(ROOM_VOLUME_HALF_EXTENTS, ROOM_COUNTS, SCENE));
    room.camera = room.scene.add_camera(camera::perspective_deg(60, 0.05f), name: "camera")!;
    room.camera.local.position = ROOM_CENTER + { 0, 0.5f, 1.2f };
    room.scene.update_world();
    return room;
}

fn void? render_room_frames(Fixture* fixture, ProbeRoom* room, ViewId view, uint frames) @private {
    for (uint frame = 0; frame < frames; frame++) {
        fixture.renderer.begin_frame()!;
        defer catch render::abort_frame(&fixture.renderer);
        fixture.renderer.render_view(&room.scene, room.camera, view)!;
        fixture.renderer.finish_view(view)!;
        fixture.renderer.end_frame()!;
    }
}

fn void test_closed_box_has_no_leak() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    print_adapter(&fixture);
    ProbeRoom room = create_probe_room(&fixture)!!;
    defer scene::destroy_scene(&room.scene);
    ProbeView probe_view = create_probe_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_probe_view(&fixture, &probe_view);

    render_room_frames(&fixture, &room, probe_view.view, 1)!!;
    float closed = interior_irradiance(&fixture, &room);
    room.roof.visible = false;
    room.scene.update_world();
    render_room_frames(&fixture, &room, probe_view.view, OPEN_ROOM_UPDATES)!!;
    float open = interior_irradiance(&fixture, &room);
    io::eprintfn("closed room irradiance %f, open %f", closed, open);
    assert(open > LIT_IRRADIANCE);
    assert(closed < DARK_SHARE * open);
    check_validation(&fixture.renderer);
}

fn void test_scene_atlases_hold_no_nan() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ProbeRoom room = create_probe_room(&fixture)!!;
    defer scene::destroy_scene(&room.scene);
    ProbeView probe_view = create_probe_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_probe_view(&fixture, &probe_view);
    room.scene.get(room.volume, ProbeVolume).update.probes_per_frame = 16;

    render_room_frames(&fixture, &room, probe_view.view, 1)!!;
    ProbeVolumeRes* mirror = mirror_of(&fixture, &room.scene, room.volume);
    @pool() {
        assert_finite(read_atlas(&fixture, &mirror.irradiance)!!);
        assert_finite(read_atlas(&fixture, &mirror.visibility)!!);
    };
    render_room_frames(&fixture, &room, probe_view.view, 10)!!;
    assert(mirror.fill.scene_swept);
    @pool() {
        assert_finite(read_atlas(&fixture, &mirror.irradiance)!!);
        assert_finite(read_atlas(&fixture, &mirror.visibility)!!);
    };
    check_validation(&fixture.renderer);
}

fn void test_moved_volume_restarts_into_the_dark() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ProbeRoom room = create_probe_room(&fixture)!!;
    defer scene::destroy_scene(&room.scene);
    ProbeView probe_view = create_probe_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_probe_view(&fixture, &probe_view);

    room.volume.local.position = FAR_AWAY + ROOM_CENTER;
    room.scene.update_world();
    render_room_frames(&fixture, &room, probe_view.view, 3)!!;
    float outside = interior_irradiance(&fixture, &room);
    room.volume.local.position = ROOM_CENTER;
    room.scene.update_world();
    render_room_frames(&fixture, &room, probe_view.view, 1)!!;
    float inside = interior_irradiance(&fixture, &room);
    io::eprintfn("moved volume irradiance: outside %f, inside after the move %f", outside, inside);
    assert(outside > LIT_IRRADIANCE);
    assert(inside < DARK_SHARE * outside);
    check_validation(&fixture.renderer);
}

fn void test_bounce_with_high_energy_stays_finite() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ProbeRoom room = create_probe_room(&fixture, lamp: true)!!;
    defer scene::destroy_scene(&room.scene);
    ProbeVolume* volume = room.scene.get(room.volume, ProbeVolume);
    volume.energy = HIGH_ENERGY;
    volume.update.hysteresis = FAST_HYSTERESIS;
    ProbeView probe_view = create_probe_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_probe_view(&fixture, &probe_view);

    render_room_frames(&fixture, &room, probe_view.view, STABILITY_FIRST)!!;
    float first = interior_irradiance(&fixture, &room);
    render_room_frames(&fixture, &room, probe_view.view, STABILITY_SECOND - STABILITY_FIRST)!!;
    float second = interior_irradiance(&fixture, &room);
    io::eprintfn("lamp room mean irradiance after %d updates %f, after %d %f", STABILITY_FIRST, first, STABILITY_SECOND, second);
    assert(first > 0 && math::is_finite(second));
    assert(math::abs(second - first) <= STABILITY_TOLERANCE * first);
    check_validation(&fixture.renderer);
}

fn void test_open_sky_probe_matches_the_sh_after_one_sweep() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ProbeScene probe = create_probe_scene(&fixture, toon_floor: true)!!;
    defer scene::destroy_scene(&probe.scene);
    ProbeView probe_view = create_probe_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_probe_view(&fixture, &probe_view);
    probe.volume.local.position = SKY_VOLUME_OFFSET;
    probe.scene.add(probe.volume, light::probe_volume(SKY_VOLUME_HALF_EXTENTS, SKY_COUNTS, SCENE));
    probe.scene.update_world();

    // The upward texel of a probe above everything sees only the sky: E = PI x sky radiance.
    float expected = (float)math::PI * SKY_RADIANCE.y;
    uint[<3>] top_probe = { SKY_COUNTS.x - 1, SKY_COUNTS.y - 1, SKY_COUNTS.z - 1 };
    float spread;
    for (uint frame = 0; frame < SKY_SPREAD_FRAMES; frame++) {
        // A new counts value makes new atlases, so every frame reads a first-sweep estimate.
        probe.scene.get(probe.volume, ProbeVolume).counts.z = SKY_COUNTS.z + frame % 2;
        top_probe.z = SKY_COUNTS.z - 1 + frame % 2;
        (void)render_probe_pixel(&fixture, &probe, probe_view.view, SKY_FLOOR_POINT)!!;
        ProbeVolumeRes* mirror = mirror_of(&fixture, &probe.scene, probe.volume);
        Vec4f[] texels = read_atlas(&fixture, &mirror.irradiance)!!;
        uint[<3>] counts = { SKY_COUNTS.x, SKY_COUNTS.y, top_probe.z + 1 };
        uint[<2>] cell = render::probe_cell(counts, mirror.slices_per_row, top_probe);
        Vec2 up = render::probe_atlas_texel(cell, shader::PROBE_IRRADIANCE_CELL, { 0, 1, 0 });
        usz texel = (usz)(up.y - 0.5f) * mirror.irradiance.width + (usz)up.x;
        float value = texels[texel][1];
        spread = math::max(spread, math::abs(value - expected));
        io::eprintfn("open sky frame %d: upward texel %f, SH %f", frame, value, expected);
    }
    io::eprintfn("open sky largest difference after one sweep: %f", spread);
    assert(spread <= SKY_TEXEL_TOLERANCE * expected);
    check_validation(&fixture.renderer);
}

fn void test_two_scenes_update_in_one_frame() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ProbeRoom closed = create_probe_room(&fixture)!!;
    defer scene::destroy_scene(&closed.scene);
    ProbeRoom open = create_probe_room(&fixture)!!;
    defer scene::destroy_scene(&open.scene);
    open.roof.visible = false;
    open.scene.update_world();
    ProbeView first_view = create_probe_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_probe_view(&fixture, &first_view);
    ProbeView second_view = create_probe_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_probe_view(&fixture, &second_view);

    for (uint frame = 0; frame < OPEN_ROOM_UPDATES; frame++) {
        fixture.renderer.begin_frame()!!;
        fixture.renderer.render_view(&closed.scene, closed.camera, first_view.view)!!;
        fixture.renderer.finish_view(first_view.view)!!;
        fixture.renderer.render_view(&open.scene, open.camera, second_view.view)!!;
        fixture.renderer.finish_view(second_view.view)!!;
        fixture.renderer.end_frame()!!;
        assert(fixture.renderer.stats.probe_updates == 2);
    }
    float closed_irradiance = interior_irradiance(&fixture, &closed);
    float open_irradiance = interior_irradiance(&fixture, &open);
    io::eprintfn("two scenes: closed %f, open %f", closed_irradiance, open_irradiance);
    assert(open_irradiance > LIT_IRRADIANCE);
    assert(closed_irradiance < DARK_SHARE * open_irradiance);
    check_validation(&fixture.renderer);
}

fn void test_hidden_volume_is_not_updated() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ProbeRoom room = create_probe_room(&fixture)!!;
    defer scene::destroy_scene(&room.scene);
    ProbeView probe_view = create_probe_view(&fixture, ShadingPath.FORWARD)!!;
    defer destroy_probe_view(&fixture, &probe_view);

    room.volume.visible = false;
    room.scene.update_world();
    render_room_frames(&fixture, &room, probe_view.view, 1)!!;
    assert(fixture.renderer.stats.probe_updates == 0 && fixture.renderer.stats.probe_rays == 0);
    assert(!mirror_of(&fixture, &room.scene, room.volume));
    room.volume.visible = true;
    room.scene.update_world();
    render_room_frames(&fixture, &room, probe_view.view, 1)!!;
    assert(fixture.renderer.stats.probe_updates == 1);
    check_validation(&fixture.renderer);
}

