module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

const char[*] DEVICE_INSTANCES_STAGE @private = $embed("device_instances.comp.glsl");
const char[*] INSTANCE_RECORD_PROBE_STAGE @private = $embed("instance_record_probe.comp.glsl");
const uint DEVICE_INSTANCE_CAPACITY @private = 16; // mirrored as the invocation count of device_instances.comp.glsl
const uint DEVICE_INSTANCE_LIVE @private = 3;
const float DEVICE_INSTANCE_SPACING @private = 0.7f;
const float DEVICE_INSTANCE_SCALE @private = 0.4f;
const float DEVICE_STALE_SCALE @private = 1.2f; // covers SIDE_UV and every pixel of the shadow row
const usz DEVICE_INSTANCE_COUNT_OFFSET @private = DEVICE_INSTANCE_CAPACITY * InstanceGpu::size;
const Aabb DEVICE_INSTANCE_BOUND @private = { .min = { -2, -1, -1 }, .max = { 2, 1, 1 } };
const float PACKING_TOLERANCE @private = 1e-5f;

struct DeviceInstancesRoot @private {
    ulong records;
    ulong count;
    uint live;
    uint capacity;
    float spacing;
    float scale;
    float stale_scale;
    uint _pad0;
}
$assert DeviceInstancesRoot::size == 40;

struct InstanceRecordProbeRoot @private {
    ulong output_address;
    ulong _pad0;
    Mat4f model;
    Vec4 color;
    float seed;
    uint _pad1;
    uint _pad2;
    uint _pad3;
}
$assert InstanceRecordProbeRoot::size == 112;

struct DeviceWall @private {
    DeformedScene target;
    BufferId buffer;
}

fn DeformedScene? create_host_wall(Fixture* fixture) @private {
    DeformedScene wall = create_wall_scene(fixture, fixture.plain)!;
    defer catch scene::destroy_scene(&wall.scene);
    Transform[DEVICE_INSTANCE_LIVE] live;
    foreach (index, &transform : live) {
        *transform = maths::TRANSFORM_IDENTITY;
        transform.position.x = ((float)index - 0.5f * (float)(DEVICE_INSTANCE_LIVE - 1)) * DEVICE_INSTANCE_SPACING;
        transform.scale = { DEVICE_INSTANCE_SCALE, DEVICE_INSTANCE_SCALE, DEVICE_INSTANCE_SCALE };
    }
    wall.scene.set_instances(wall.mesh, live[..])!;
    return wall;
}

fn DeviceWall? create_device_wall(Fixture* fixture) @private {
    DeviceWall wall = { .target = create_wall_scene(fixture, fixture.plain)! };
    defer catch scene::destroy_scene(&wall.target.scene);
    wall.target.scene.remove(wall.target.mesh);
    wall.target.mesh = wall.target.scene.add_instanced_mesh(
        geometry: fixture.box,
        material: fixture.plain,
        capacity: DEVICE_INSTANCE_CAPACITY,
        source:   InstanceSource.DEVICE,
    )!;
    wall.buffer = fixture.renderer.create_buffer({
        .size       = DEVICE_INSTANCE_COUNT_OFFSET + uint::size,
        .debug_name = "device_instances",
    })!;
    wall.target.scene.set_instance_device(
        wall.target.mesh,
        {
            .buffer       = wall.buffer,
            .count_offset = DEVICE_INSTANCE_COUNT_OFFSET,
            .capacity     = DEVICE_INSTANCE_CAPACITY,
        },
        DEVICE_INSTANCE_BOUND,
    );
    wall.target.scene.update_world();
    return wall;
}

fn void? write_device_instances(Fixture* fixture, ComputeShaderId stage, BufferId buffer) @private {
    ulong records = (ulong)fixture.renderer.buffer_address(buffer);
    DeviceInstancesRoot root = {
        .records     = records,
        .count       = records + DEVICE_INSTANCE_COUNT_OFFSET,
        .live        = DEVICE_INSTANCE_LIVE,
        .capacity    = DEVICE_INSTANCE_CAPACITY,
        .spacing     = DEVICE_INSTANCE_SPACING,
        .scale       = DEVICE_INSTANCE_SCALE,
        .stale_scale = DEVICE_STALE_SCALE,
    };
    BufferId[1] writes = { buffer };
    return fixture.renderer.dispatch({
        .shader = stage,
        .root   = ((char*)&root)[:DeviceInstancesRoot::size],
        .groups = { 1, 1, 1 },
        .writes = writes[..],
    });
}

fn uint? render_device_wall_and_sample(
    Fixture* fixture,
    DeviceWall* wall,
    ComputeShaderId stage,
    Vec2 uv,
) @private {
    Renderer* renderer = &fixture.renderer;
    wall.target.scene.update_world();
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    write_device_instances(fixture, stage, wall.buffer)!;
    renderer.render_view(&wall.target.scene, wall.target.camera, fixture.view)!;
    sample(fixture, render::read_view_color(fixture.view), uv)!;
    record_readback(fixture)!;
    renderer.finish_view(fixture.view)!;
    renderer.end_frame()!;
    return read_pixel(fixture);
}

fn void test_device_instances_render_and_shadow_like_the_same_host_batch() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ComputeShaderId stage = add_compute_shader(&fixture, (String)DEVICE_INSTANCES_STAGE[..])!!;
    DeformedScene host = create_host_wall(&fixture)!!;
    defer scene::destroy_scene(&host.scene);
    DeviceWall device = create_device_wall(&fixture)!!;
    defer scene::destroy_scene(&device.target.scene);

    bool[2] culling_modes = { true, false };
    foreach (culling : culling_modes) {
        set_view_culling(&fixture, culling)!!;
        uint[SHADOW_ROW_SAMPLES] host_row;
        sample_row(&fixture, &host, host_row[..])!!;
        bool shadow_edge;
        foreach (index, expected : host_row) {
            Vec2 uv = { SHADOW_ROW_U_START + (float)index / TARGET_SIZE, SHADOW_ROW_V };
            check_near_pixel(render_device_wall_and_sample(&fixture, &device, stage, uv)!!, expected);
            shadow_edge |= pixels_differ(expected, host_row[0]);
        }
        assert(shadow_edge);

        uint host_side = render_scene_and_sample(&fixture, &host, SIDE_UV)!!;
        check_near_pixel(render_device_wall_and_sample(&fixture, &device, stage, SIDE_UV)!!, host_side);
    }
    check_validation(&fixture.renderer);
}

fn void test_moving_device_instance_node_velocity_matches_the_host_batch() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ComputeShaderId stage = add_compute_shader(&fixture, (String)DEVICE_INSTANCES_STAGE[..])!!;
    DeformedScene host = create_host_wall(&fixture)!!;
    defer scene::destroy_scene(&host.scene);
    DeviceWall device = create_device_wall(&fixture)!!;
    defer scene::destroy_scene(&device.target.scene);

    uint host_velocity = move_line_node(&fixture, &host, false)!!;
    enable_taa(&fixture, fixture.view, debug: TaaDebug.VELOCITY)!!;
    device.target.mesh.local.position.x = 0;
    uint device_velocity;
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        device.target.mesh.local.position.x += LINE_STEP;
        device_velocity = render_device_wall_and_sample(&fixture, &device, stage, CENTER_UV)!!;
    }
    check_near_pixel(device_velocity, host_velocity);
    assert(device_velocity != render_device_wall_and_sample(&fixture, &device, stage, BACKGROUND_UV)!!);
    check_validation(&fixture.renderer);
}

fn void test_device_instances_with_a_destroyed_buffer_are_skipped_and_counted() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DeviceWall device = create_device_wall(&fixture)!!;
    defer scene::destroy_scene(&device.target.scene);

    fixture.renderer.destroy_buffer(device.buffer)!!;
    render_scene_and_sample(&fixture, &device.target)!!;
    assert(fixture.renderer.stats.dangling_refs == 1);
    check_validation(&fixture.renderer);
}

fn void test_device_instance_records_match_the_cpu_packing() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    ComputeShaderId stage = add_compute_shader(&fixture, (String)INSTANCE_RECORD_PROBE_STAGE[..])!!;
    BufferId output = renderer.create_buffer({
        .size       = InstanceGpu::size,
        .usage      = BufferUsage.READBACK,
        .debug_name = "instance_record_probe",
    })!!;

    // A turn and unequal scales make the normal matrix differ from the model's upper block.
    Transform transform = {
        .position = { 1, -2, 3 },
        .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.7f),
        .scale    = { 0.5f, 1.5f, 2 },
    };
    Mat4 model = transform.to_mat4();
    Vec4 color = { 0.25f, 0.5f, 0.75f, 1 };
    float seed = 0.375f;
    InstanceRecordProbeRoot root = {
        .output_address = (ulong)renderer.buffer_address(output),
        .model          = bitcast(model, Mat4f),
        .color          = color,
        .seed           = seed,
    };
    BufferId[1] writes = { output };
    InstanceGpu packed;
    for (uint frame = 0; frame <= render::FRAMES_IN_FLIGHT; frame++) {
        renderer.begin_frame()!!;
        if (frame == 0) {
            renderer.dispatch({
                .shader = stage,
                .root   = ((char*)&root)[:InstanceRecordProbeRoot::size],
                .groups = { 1, 1, 1 },
                .writes = writes[..],
            })!!;
        }
        if (frame == render::FRAMES_IN_FLIGHT) packed = *(InstanceGpu*)renderer.read_buffer(output)!!.ptr;
        renderer.end_frame()!!;
    }

    InstanceGpu expected;
    render::write_instance(&expected, model, color, seed);
    float[InstanceGpu::size / float::size] found = bitcast(packed, float[InstanceGpu::size / float::size]);
    float[InstanceGpu::size / float::size] wanted = bitcast(expected, float[InstanceGpu::size / float::size]);
    foreach (index, value : found) assert(math::abs(value - wanted[index]) <= PACKING_TOLERANCE);
    check_validation(renderer);
}
