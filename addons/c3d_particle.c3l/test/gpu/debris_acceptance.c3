module particle_gpu_acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::particle;
import c3d::particle::gpu;
import c3d::render;
import c3d::scene;
import c3d::shader;
import std::math;

const uint DEBRIS_CAPACITY @private = 64;
const uint DEBRIS_BURST @private = 40;
const float DEBRIS_LIFETIME @private = 10;
const float DEBRIS_HEIGHT @private = 2;
const float DEBRIS_VIEW_HEIGHT @private = 8; // world units across the target, so eight pixels to the unit
const uint DEBRIS_TARGET @private = 64;
const float DEBRIS_CAMERA_HEIGHT @private = 10;
const float SHADOW_REACH @private = 2; // a sun at 45 degrees lays the shadow of a cube at the height this far along x
const float SHADOW_DISTANCE @private = 30;
const float SHADOW_DARKNESS @private = 0.5f; // the shadow keeps less than this share of the lit floor
const float SHADOW_EQUALITY @private = 0.01f;
const uint DEBRIS_INSTANCE_WORDS @private = CAPACITY * (uint)scene::INSTANCE_RECORD_BYTES / uint::size;
const float MATRIX_TOLERANCE @private = 1e-3f; // a record's matrix holds the position and the size-scaled turn

struct DebrisScene @private {
    Node* emitter;
    Node* floor_node;
    Node* camera;
    RenderTargetId target;
    ViewId view;
}

fn GeometryId? add_unit_box(Fixture* fixture) @private {
    Geometry box = geometry::box(
        allocator: tmem,
        width: 1,
        height: 1,
        depth: 1,
    );
    return fixture.assets.add_geometry(&box);
}

fn MaterialId? add_matte(Fixture* fixture) @private {
    StandardParams matte = material::STANDARD_PARAMS_DEFAULT;
    matte.metallic = 0;
    matte.roughness = 0.9f;
    return fixture.assets.add_material(material::standard(matte));
}

fn DebrisScene? create_debris_scene(Fixture* fixture) @private {
    DebrisScene debris;
    MaterialId matte = add_matte(fixture)!;
    @pool() {
        Geometry plane = geometry::plane(tmem, 20, 20);
        GeometryId floor_geometry = fixture.assets.add_geometry(&plane)!;
        debris.floor_node = fixture.scene.add_mesh(floor_geometry, matte)!;
    };
    fixture.scene.get(debris.floor_node, Mesh).trace = false;

    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = DEBRIS_CAPACITY;
    desc.render_mode = ParticleRenderMode.MESH;
    desc.geometry = add_unit_box(fixture)!;
    desc.material = matte;
    desc.lifetime = { .min = DEBRIS_LIFETIME, .max = DEBRIS_LIFETIME };
    desc.speed = { .min = 0, .max = 0 };
    desc.size = { .min = 1, .max = 1 };
    desc.mesh_cast_shadow = true;
    desc.mesh_trace = true;
    desc.execution = ParticleExecution.GPU;
    debris.emitter = fixture.scene.add_particle_system(desc)!;
    debris.emitter.local.position = { 0, DEBRIS_HEIGHT, 0 };

    Light sunlight = light::directional({ 1, 1, 1 }, 3);
    sunlight.shadow.cascades = 1;
    sunlight.shadow.max_distance = SHADOW_DISTANCE;
    Node* sun = fixture.scene.add_light(sunlight)!;
    Vec3 travel = { 1, -1, 0 };
    sun.local.rotation = maths::rotation_between({ 0, 0, -1 }, travel.normalize());

    debris.camera = fixture.scene.add_camera(camera::orthographic(DEBRIS_VIEW_HEIGHT, 0.1f, 100))!;
    debris.camera.local.position = { 0, DEBRIS_CAMERA_HEIGHT, 0 };
    debris.camera.local.rotation = maths::rotation_between({ 0, 0, -1 }, { 0, -1, 0 });
    debris.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(DEBRIS_TARGET, DEBRIS_TARGET, PixelFormat.RGBA32_FLOAT),
    )!;
    ViewDesc view_desc = render::texture_view_desc(debris.target);
    view_desc.post.anti_aliasing = AntiAliasing.NONE;
    debris.view = render::create_view(&fixture.renderer, view_desc)!;
    fixture.scene.update_world();
    return debris;
}

fn void? debris_frame(Fixture* fixture, DebrisScene* debris, float dt) @private {
    Renderer* renderer = &fixture.renderer;
    particle::update(&fixture.scene, dt);
    fixture.scene.update_world();
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    gpu::update(
        particles: &fixture.particles,
        renderer: renderer,
        scene: &fixture.scene,
        dt: dt,
    )!;
    renderer.prepare_scene_trace(&fixture.scene, TraceKind.SOFTWARE)!;
    renderer.render_view(&fixture.scene, debris.camera, debris.view)!;
    renderer.finish_view(debris.view)!;
    renderer.end_frame()!;
}

fn Vec4 floor_pixel(Fixture* fixture, DebrisScene* debris, float world_x) @private {
    render::wait_frames(&fixture.renderer)!!;
    Vec4[DEBRIS_TARGET * DEBRIS_TARGET] pixels;
    fixture.renderer.read_render_target(debris.target, ((char*)&pixels)[:Vec4::size * pixels.len])!!;
    uint column = (uint)(DEBRIS_TARGET / 2 + world_x * DEBRIS_TARGET / DEBRIS_VIEW_HEIGHT);
    return pixels[DEBRIS_TARGET / 2 * DEBRIS_TARGET + column];
}

fn void test_gpu_debris_counts_draw_shadow_and_trace_instances() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    DebrisScene debris = create_debris_scene(&fixture)!!;
    fixture.scene.get(debris.emitter, ParticleSystem).emit_burst(DEBRIS_BURST);

    debris_frame(&fixture, &debris, STEP_SECONDS)!!;
    Vec4 lit = floor_pixel(&fixture, &debris, -SHADOW_REACH);
    Vec4 shadowed = floor_pixel(&fixture, &debris, SHADOW_REACH);
    assert(shadowed.r < SHADOW_DARKNESS * lit.r);

    for (uint frame = 0; frame < render::FRAMES_IN_FLIGHT; frame++) debris_frame(&fixture, &debris, STEP_SECONDS)!!;
    assert(fixture.renderer.stats.trace_instances == DEBRIS_BURST);

    ParticleSystem* system = fixture.scene.get(debris.emitter, ParticleSystem);
    InstancedMesh* batch = fixture.scene.get(fixture.scene.node(system.draw_node), InstancedMesh);
    Aabb box = fixture.assets.geometry(system.desc.geometry).data.bounds;
    foreach (transform : batch.transforms[:batch.count]) {
        Aabb placed = maths::aabb_transform(box, transform.to_mat4());
        for (usz axis = 0; axis < 3; axis++) {
            assert(placed.min[axis] >= batch.local_bounds.min[axis]);
            assert(placed.max[axis] <= batch.local_bounds.max[axis]);
        }
    }

    batch.cast_shadow = false;
    debris_frame(&fixture, &debris, STEP_SECONDS)!!;
    lit = floor_pixel(&fixture, &debris, -SHADOW_REACH);
    shadowed = floor_pixel(&fixture, &debris, SHADOW_REACH);
    assert(math::abs(shadowed.r - lit.r) <= SHADOW_EQUALITY * lit.r);
}

fn Pair? add_debris_pair(Fixture* fixture) @private {
    ParticleSystemDesc desc = reference_desc(add_matte(fixture)!);
    desc.render_mode = ParticleRenderMode.MESH;
    desc.geometry = add_unit_box(fixture)!;
    desc.rotation = { .min = -(float)math::PI, .max = (float)math::PI };
    desc.spin = { .min = -2, .max = 2 };
    desc.color_min = { 0.2f, 0.4f, 0.6f, 0.5f };
    desc.mesh_trace = true;
    Pair pair;
    pair.cpu = fixture.scene.get(fixture.scene.add_particle_system(desc)!, ParticleSystem);
    desc.execution = ParticleExecution.GPU;
    pair.device = fixture.scene.get(fixture.scene.add_particle_system(desc)!, ParticleSystem);
    fixture.scene.update_world();
    return pair;
}

fn void? copy_instances(Fixture* fixture, ParticleSystem* system, BufferId destination) @private {
    Renderer* renderer = &fixture.renderer;
    InstancedMesh* batch = fixture.scene.get(fixture.scene.node(system.draw_node), InstancedMesh);
    ulong records = (ulong)renderer.buffer_address(batch.device.buffer);
    copy_words(
        fixture: fixture,
        root: {
            .records = records + batch.device.records_offset,
            .count = records + batch.device.count_offset,
            .words = DEBRIS_INSTANCE_WORDS,
        },
        destination: destination,
    )!;
}

fn void check_debris(Fixture* fixture, Pair* pair, BufferId copied) @private {
    check_counters(pair, 128, 144);
    char[] bytes = fixture.renderer.read_buffer(copied)!!;
    InstanceGpu* records = (InstanceGpu*)bytes.ptr;
    assert(*(uint*)(bytes.ptr + CAPACITY * scene::INSTANCE_RECORD_BYTES) == pair.cpu.alive);

    InstancedMesh* host = fixture.scene.get(fixture.scene.node(pair.cpu.draw_node), InstancedMesh);
    InstancedMesh* mirror = fixture.scene.get(fixture.scene.node(pair.device.draw_node), InstancedMesh);
    assert(host.count == pair.cpu.alive && mirror.count == pair.cpu.alive);
    uint[CAPACITY] order;
    sort_by_spawn(pair.cpu, order[..]);
    for (uint rank = 0; rank < pair.cpu.alive; rank++) {
        Transform expected = host.transforms[order[rank]];
        Vec4 color = host.colors[order[rank]];
        Mat4 wanted = expected.to_mat4();
        float* found_values = (float*)&records[rank].model;
        float* wanted_values = (float*)&wanted;
        for (usz value = 0; value < Mat4::size / float::size; value++) {
            assert(math::abs(found_values[value] - wanted_values[value]) <= MATRIX_TOLERANCE);
        }
        for (usz channel = 0; channel < 4; channel++) {
            assert(math::abs(records[rank].color[channel] - color[channel]) <= COLOR_TOLERANCE);
            assert(math::abs(mirror.colors[rank][channel] - color[channel]) <= COLOR_TOLERANCE);
        }

        Transform found = mirror.transforms[rank];
        for (usz axis = 0; axis < 3; axis++) {
            assert(math::abs(found.position[axis] - expected.position[axis]) <= POSITION_TOLERANCE);
            assert(math::abs(found.scale[axis] - expected.scale[axis]) <= SIZE_TOLERANCE);
        }
        for (usz component = 0; component < 4; component++) {
            assert(math::abs(found.rotation.v[component] - expected.rotation.v[component]) <= POSITION_TOLERANCE);
        }
    }
}

fn void test_gpu_debris_follow_the_cpu_reference() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Pair pair = add_debris_pair(&fixture)!!;
    BufferId copied = fixture.renderer.create_buffer({
        .size = DEBRIS_INSTANCE_WORDS * uint::size + uint::size,
        .usage = BufferUsage.READBACK,
        .debug_name = "debris_records",
    })!!;
    uint steps = STEPS + render::FRAMES_IN_FLIGHT;
    for (uint step = 0; step < steps; step++) {
        float dt = step < STEPS ? STEP_SECONDS : 0;
        queue_bursts(&pair, step, BURSTS[..]);
        particle::update(&fixture.scene, dt, WIND);
        Renderer* renderer = &fixture.renderer;
        renderer.begin_frame()!!;
        gpu::update(
            particles: &fixture.particles,
            renderer: renderer,
            scene: &fixture.scene,
            dt: dt,
            wind: WIND,
        )!!;
        copy_instances(&fixture, pair.device, copied)!!;
        if (step + 1 == steps) check_debris(&fixture, &pair, copied);
        renderer.end_frame()!!;
    }
}
