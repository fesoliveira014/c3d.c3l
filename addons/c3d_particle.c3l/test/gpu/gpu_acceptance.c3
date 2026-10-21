module particle_gpu_acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::particle;
import c3d::particle::gpu;
import c3d::render;
import c3d::scene;
import c3d::shader;
import c3d::shader::compile;
import std::math;

const char[*] RECORD_COPY_STAGE @private = $embed("record_copy.comp.glsl");
const uint COPY_GROUP @private = 64; // mirrored as local_size_x in record_copy.comp.glsl
const uint CAPACITY @private = 256;
const uint TRAIL_POINTS @private = 4;
const float TRAIL_INTERVAL @private = 0.05f;
const float TRAIL_LIFETIME_SECONDS @private = 0.2f;
const float TRAIL_WIDTH @private = 0.1f;
const float TRAIL_TILE_LENGTH @private = 0.5f;
const float TRAIL_PARTICLE_LIFETIME_MIN @private = 0.3f; // some expire inside the run, so compaction moves strips
const float TRAIL_PARTICLE_LIFETIME_MAX @private = 0.7f;
const uint TRAIL_BURST @private = 64;
const uint TRAIL_STEPS @private = 30;
const uint TRAIL_SHIFT_AT @private = 24; // points stored before it are still inside the trail lifetime
const float COLOR_TOLERANCE @private = 1e-4f;
const uint RIBBON_RECORDS @private = CAPACITY * (TRAIL_POINTS + 1) + 1; // each particle's strip, then a break
const uint TARGET_SIZE @private = 64;
const float STEP_SECONDS @private = 1.0f / 60;
const float LIFETIME_SECONDS @private = 0.52f; // the first burst expires in the step that admits the third
const float POSITION_TOLERANCE @private = 1e-3f; // metres; float order and the GPU's sine differ from the CPU
const float SIZE_TOLERANCE @private = 1e-5f;
const Vec3 WIND @private = { 1, 0, 0 };
const uint STEPS @private = 45;
const uint ABORTED_STEP @private = 5;
const uint INITIAL_BURST @private = 128;
const uint ABORTED_BURST @private = 64;
const uint STEPS_AFTER_ABORT @private = 20;
const uint GAP_STEPS @private = 10;
const uint SHIFT_STEPS @private = 28; // the first burst is still alive
const uint SHIFT_AT @private = 12;
const uint SHIFT_BURST @private = 100;
const uint SHIFT_SECOND_BURST_AT @private = 14;
const Vec3 SHIFT_OFFSET @private = { 100, 0, -60 };

enum FrameKind @private {
    NORMAL,
    ABORTED, // renders a view without finishing it, so end_frame faults
    FINAL, // reads the counters and records of the frame FRAMES_IN_FLIGHT earlier
}

struct Burst @private {
    uint step;
    uint count;
}

const Burst[3] BURSTS @private = { { 0, 300 }, { 20, 100 }, { 31, 128 } };

// Mirrors RecordCopyRoot in record_copy.comp.glsl.
struct CopyRoot @private {
    ulong records;
    ulong count;
    ulong destination;
    uint words;
    uint _pad0;
}
$assert CopyRoot::size == 32;

struct Fixture @private {
    AssetStore assets;
    Scene scene;
    Renderer renderer;
    GpuParticles particles;
    ComputeShaderId copy_stage;
    BufferId copied;
    BufferId copied_ribbons;
    bool trailed; // the pair carries a trail, so the ribbon records are copied too
    MaterialId material;
    Node* camera;
    ViewId view;
}

struct Pair @private {
    ParticleSystem* cpu;
    ParticleSystem* device;
}

fn void? create_fixture(Fixture* fixture) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer catch asset::destroy_asset_store(&fixture.assets);
    fixture.scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer catch scene::destroy_scene(&fixture.scene);
    particle::register_particles(&fixture.scene)!;
    fixture.renderer = render::create_renderer(mem, &fixture.assets, { .validation = true })!;
    defer catch render::destroy_renderer(&fixture.renderer);
    fixture.particles = gpu::create_gpu_particles(mem, &fixture.assets)!;
    defer catch gpu::destroy_gpu_particles(&fixture.particles, &fixture.renderer);
    char[] spirv = compile::compile_glsl(
        allocator: mem,
        source: (String)RECORD_COPY_STAGE[..],
        stage: ShaderStage.COMPUTE,
        defines: {},
    )!;
    defer free(spirv);
    ComputeShaderDesc copy_desc = { .compute = spirv };
    fixture.copy_stage = fixture.assets.add_compute_shader(&copy_desc)!;
    fixture.copied = fixture.renderer.create_buffer({
        .size = CAPACITY * BillboardRecord::size + uint::size,
        .usage = BufferUsage.READBACK,
        .debug_name = "particle_records",
    })!;
    fixture.copied_ribbons = fixture.renderer.create_buffer({
        .size = RIBBON_RECORDS * scene::RIBBON_RECORD_BYTES + uint::size,
        .usage = BufferUsage.READBACK,
        .debug_name = "particle_trail_records",
    })!;
    ShaderId shader = particle::add_particle_shader(&fixture.assets)!;
    fixture.material = particle::add_particle_material(&fixture.assets, shader, { .color = { 1, 1, 1, 1 } })!;
    fixture.camera = fixture.scene.add_camera(camera::orthographic(4, 0.1f, 100))!;
    fixture.camera.local.position = { 0, 0, 5 };
    RenderTargetId target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(TARGET_SIZE, TARGET_SIZE, PixelFormat.RGBA32_FLOAT),
    )!;
    fixture.view = render::create_view(&fixture.renderer, render::texture_view_desc(target))!;
}

fn void destroy_fixture(Fixture* fixture) @private {
    fixture.renderer.log.check_validation()!!;
    gpu::destroy_gpu_particles(&fixture.particles, &fixture.renderer);
    render::destroy_renderer(&fixture.renderer);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn ParticleSystemDesc reference_desc(MaterialId material) @private {
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = CAPACITY;
    desc.seed = 3;
    desc.material = material;
    desc.shape = EmitterShape.POINT;
    desc.saturation = ParticleSaturation.REFUSE;
    desc.lifetime = { .min = LIFETIME_SECONDS, .max = LIFETIME_SECONDS };
    desc.speed = { .min = 1, .max = 4 };
    desc.size = { .min = 0.05f, .max = 0.15f };
    desc.gravity_scale = 1;
    desc.drag = 0.5f;
    desc.turbulence = {
        .strength = 1.5f,
        .frequency = 0.8f,
        .octaves = 2,
        .period = 16,
        .scroll = { 0.3f, 0, 0 },
    };
    return desc;
}

fn void add_trail(ParticleSystemDesc* desc, MaterialId material) @private {
    float[8] widths = { 1, 0.85f, 0.7f, 0.55f, 0.4f, 0.25f, 0.1f, 0 };
    float[8] fade = { 1, 0.9f, 0.75f, 0.6f, 0.45f, 0.3f, 0.15f, 0 };
    desc.lifetime = { .min = TRAIL_PARTICLE_LIFETIME_MIN, .max = TRAIL_PARTICLE_LIFETIME_MAX };
    desc.trail = {
        .max_points = TRAIL_POINTS,
        .point_interval = TRAIL_INTERVAL,
        .lifetime = TRAIL_LIFETIME_SECONDS,
        .width = TRAIL_WIDTH,
        .uv = TrailUv.TILE,
        .tile_length = TRAIL_TILE_LENGTH,
        .material = material,
    };
    desc.trail.width_over_trail.values = widths;
    foreach (index, alpha : fade) desc.trail.color_over_trail.values[index] = { 1, 1, 1, alpha };
}

fn Pair? add_pair(Fixture* fixture, bool trailed = false) @private {
    ParticleSystemDesc desc = reference_desc(fixture.material);
    if (trailed) add_trail(&desc, fixture.material);
    fixture.trailed = trailed;
    return add_pair_of(fixture, desc);
}

fn Pair? add_pair_of(Fixture* fixture, ParticleSystemDesc desc) @private {
    Pair pair;
    pair.cpu = fixture.scene.get(fixture.scene.add_particle_system(desc)!, ParticleSystem);
    desc.execution = ParticleExecution.GPU;
    pair.device = fixture.scene.get(fixture.scene.add_particle_system(desc)!, ParticleSystem);
    fixture.scene.update_world();
    return pair;
}

fn void? copy_words(
    Fixture* fixture,
    CopyRoot root,
    BufferId destination,
) @private {
    root.destination = (ulong)fixture.renderer.buffer_address(destination);
    BufferId[1] writes = { destination };
    fixture.renderer.dispatch({
        .shader = fixture.copy_stage,
        .root = ((char*)&root)[:CopyRoot::size],
        .groups = { (root.words + COPY_GROUP - 1) / COPY_GROUP, 1, 1 },
        .writes = writes[..],
    })!;
}

fn void? copy_records(Fixture* fixture, ParticleSystem* system) @private {
    Renderer* renderer = &fixture.renderer;
    BillboardBatch* batch = fixture.scene.get(fixture.scene.node(system.draw_node), BillboardBatch);
    ulong records = (ulong)renderer.buffer_address(batch.device.buffer);
    copy_words(
        fixture: fixture,
        root: {
            .records = records + batch.device.records_offset,
            .count = records + batch.device.count_offset,
            .words = CAPACITY * BillboardRecord::size / uint::size,
        },
        destination: fixture.copied,
    )!;
}

fn void? copy_trail_records(Fixture* fixture, ParticleSystem* system) @private {
    Renderer* renderer = &fixture.renderer;
    RibbonBatch* batch = fixture.scene.get(fixture.scene.node(system.trail_node), RibbonBatch);
    ulong records = (ulong)renderer.buffer_address(batch.device.buffer);
    copy_words(
        fixture: fixture,
        root: {
            .records = records + batch.device.records_offset,
            .count = records + batch.device.count_offset,
            .words = RIBBON_RECORDS * scene::RIBBON_RECORD_BYTES / uint::size,
        },
        destination: fixture.copied_ribbons,
    )!;
}

fn void? record_frame(
    Fixture* fixture,
    Pair* pair,
    float dt,
    FrameKind kind,
    uint expected_alive = 0,
    ulong expected_dropped = 0,
    ulong expected_evicted = 0,
) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    gpu::update(
        particles: &fixture.particles,
        renderer: renderer,
        scene: &fixture.scene,
        dt: dt,
        wind: WIND,
    )!;
    copy_records(fixture, pair.device)!;
    if (fixture.trailed) copy_trail_records(fixture, pair.device)!;
    if (kind == FrameKind.ABORTED) {
        renderer.render_view(&fixture.scene, fixture.camera, fixture.view)!;
        assert(@catch(renderer.end_frame()) == c3d::INVALID_ARGUMENT);
        return;
    }
    if (kind == FrameKind.FINAL) {
        check_records(
            fixture: fixture,
            pair: pair,
            alive: expected_alive,
            dropped: expected_dropped,
            evicted: expected_evicted,
        );
        if (fixture.trailed) check_trails(fixture, pair);
    }
    renderer.end_frame()!;
}

fn void queue_bursts(Pair* pair, uint step, Burst[] bursts) @private {
    foreach (burst : bursts) {
        if (burst.step != step) continue;

        pair.cpu.emit_burst(burst.count);
        pair.device.emit_burst(burst.count);
    }
}

fn void check_counters(Pair* pair, uint alive, ulong dropped, ulong evicted = 0) @private {
    assert(pair.cpu.alive == alive && pair.cpu.dropped == dropped && pair.cpu.evicted == evicted);
    assert(pair.device.alive == alive && pair.device.dropped == dropped && pair.device.evicted == evicted);
}

fn void sort_by_spawn(ParticleSystem* system, uint[] order) @private {
    foreach (slot, &entry : order[:system.alive]) *entry = (uint)slot;
    for (uint filled = 1; filled < system.alive; filled++) {
        uint moving = order[filled];
        uint position = filled;
        while (position > 0 && system.spawn[order[position - 1]] > system.spawn[moving]) {
            order[position] = order[position - 1];
            position--;
        }
        order[position] = moving;
    }
}

fn void check_trails(Fixture* fixture, Pair* pair) @private {
    ParticleSystem* cpu = pair.cpu;
    char[] copied = fixture.renderer.read_buffer(fixture.copied_ribbons)!!;
    RibbonPointGpu* device_points = (RibbonPointGpu*)copied.ptr;
    uint device_count = *(uint*)(copied.ptr + RIBBON_RECORDS * scene::RIBBON_RECORD_BYTES);
    assert(device_count == cpu.alive * (TRAIL_POINTS + 1));
    assert(device_points[device_count].flags == scene::RIBBON_BREAK);

    RibbonBatch* batch = fixture.scene.get(fixture.scene.node(cpu.trail_node), RibbonBatch);
    uint[CAPACITY] starts;
    uint strips;
    foreach (index, &point : batch.points[:batch.count]) {
        if (point.flags == scene::RIBBON_BREAK) starts[strips++] = (uint)index;
    }
    assert(strips == cpu.alive);

    uint[CAPACITY] order;
    sort_by_spawn(cpu, order[..]);
    for (uint rank = 0; rank < cpu.alive; rank++) {
        uint start = starts[order[rank]];
        uint end = order[rank] + 1 < strips ? starts[order[rank] + 1] : batch.count;
        uint stored = end - start - 1;
        assert(stored > 0 && stored <= TRAIL_POINTS);
        for (uint offset = 0; offset <= TRAIL_POINTS; offset++) {
            RibbonPointGpu found = device_points[rank * (TRAIL_POINTS + 1) + offset];
            if (offset > stored) {
                assert(found.flags == scene::RIBBON_BREAK && found.position_width.w == 0);
                continue;
            }

            RibbonPoint expected = batch.points[start + offset];
            assert(found.flags == expected.flags);
            for (usz axis = 0; axis < 3; axis++) {
                assert(math::abs(found.position_width[axis] - expected.position[axis]) <= POSITION_TOLERANCE);
            }
            assert(math::abs(found.position_width.w - expected.width) <= SIZE_TOLERANCE);
            assert(math::abs(found.v - expected.v) <= POSITION_TOLERANCE);
            for (usz channel = 0; channel < 4; channel++) {
                assert(math::abs(found.color[channel] - expected.color[channel]) <= COLOR_TOLERANCE);
            }
        }
    }
}

fn void check_records(
    Fixture* fixture,
    Pair* pair,
    uint alive,
    ulong dropped,
    ulong evicted,
) @private {
    check_counters(pair, alive, dropped, evicted);
    char[] copied = fixture.renderer.read_buffer(fixture.copied)!!;
    BillboardRecord* device_records = (BillboardRecord*)copied.ptr;
    uint device_count = *(uint*)(copied.ptr + CAPACITY * BillboardRecord::size);
    ParticleSystem* cpu = pair.cpu;
    assert(device_count == cpu.alive);

    BillboardBatch* batch = fixture.scene.get(fixture.scene.node(cpu.draw_node), BillboardBatch);
    assert(batch.count == cpu.alive);
    uint[CAPACITY] order;
    sort_by_spawn(cpu, order[..]);
    for (uint rank = 0; rank < cpu.alive; rank++) {
        BillboardRecord expected = batch.records[order[rank]];
        BillboardRecord found = device_records[rank];
        for (usz axis = 0; axis < 3; axis++) {
            assert(math::abs(found.position_width[axis] - expected.position_width[axis]) <= POSITION_TOLERANCE);
        }
        assert(math::abs(found.position_width.w - expected.position_width.w) <= SIZE_TOLERANCE);
    }
}

fn void test_gpu_particles_follow_the_cpu_reference() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Pair pair = add_pair(&fixture)!!;
    uint steps = STEPS + render::FRAMES_IN_FLIGHT;
    for (uint step = 0; step < steps; step++) {
        queue_bursts(&pair, step, BURSTS[..]);
        particle::update(&fixture.scene, step < STEPS ? STEP_SECONDS : 0, WIND);
        record_frame(
            fixture: &fixture,
            pair: &pair,
            dt: step < STEPS ? STEP_SECONDS : 0,
            kind: step + 1 == steps ? FrameKind.FINAL : FrameKind.NORMAL,
            expected_alive: 128,
            expected_dropped: 144,
        )!!;
    }
}

fn void test_gpu_aborted_frame_repeats_its_step() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Pair pair = add_pair(&fixture)!!;
    uint moving = ABORTED_STEP + STEPS_AFTER_ABORT;
    uint steps = moving + render::FRAMES_IN_FLIGHT;
    for (uint step = 0; step < steps; step++) {
        float dt = step < moving ? STEP_SECONDS : 0;
        if (step == 0) {
            pair.cpu.emit_burst(INITIAL_BURST);
            pair.device.emit_burst(INITIAL_BURST);
        }
        if (step == ABORTED_STEP) {
            pair.cpu.emit_burst(ABORTED_BURST);
            pair.device.emit_burst(ABORTED_BURST);
        }
        FrameKind kind = step + 1 == steps ? FrameKind.FINAL : FrameKind.NORMAL;
        if (step == ABORTED_STEP) {
            kind = FrameKind.ABORTED;
        } else {
            particle::update(&fixture.scene, dt, WIND);
        }
        record_frame(
            fixture: &fixture,
            pair: &pair,
            dt: dt,
            kind: kind,
            expected_alive: INITIAL_BURST + ABORTED_BURST,
            expected_dropped: 0,
        )!!;
    }
}

fn void test_gpu_origin_shift_follows_the_cpu_reference() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Pair pair = add_pair(&fixture)!!;
    uint steps = SHIFT_STEPS + render::FRAMES_IN_FLIGHT;
    for (uint step = 0; step < steps; step++) {
        float dt = step < SHIFT_STEPS ? STEP_SECONDS : 0;
        if (step == 0 || step == SHIFT_SECOND_BURST_AT) {
            pair.cpu.emit_burst(SHIFT_BURST);
            pair.device.emit_burst(SHIFT_BURST);
        }
        if (step == SHIFT_AT) {
            fixture.scene.shift_origin(SHIFT_OFFSET);
            fixture.scene.shift_particles(SHIFT_OFFSET);
            fixture.scene.update_world();
        }
        particle::update(&fixture.scene, dt, WIND);
        record_frame(
            fixture: &fixture,
            pair: &pair,
            dt: dt,
            kind: step + 1 == steps ? FrameKind.FINAL : FrameKind.NORMAL,
            expected_alive: 2 * SHIFT_BURST,
            expected_dropped: 0,
        )!!;
    }
}

fn void idle_frames(Fixture* fixture, uint count) @private {
    for (uint frame = 0; frame < count; frame++) {
        fixture.renderer.begin_frame()!!;
        fixture.renderer.end_frame()!!;
    }
}

fn void test_gpu_step_commits_after_frames_without_an_update() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Pair pair = add_pair(&fixture)!!;
    uint moving = 1 + GAP_STEPS;
    uint steps = moving + render::FRAMES_IN_FLIGHT;
    for (uint step = 0; step < steps; step++) {
        float dt = step < moving ? STEP_SECONDS : 0;
        if (step == 0) {
            pair.cpu.emit_burst(INITIAL_BURST);
            pair.device.emit_burst(INITIAL_BURST);
        }
        if (step == 1) idle_frames(&fixture, render::FRAMES_IN_FLIGHT + 1);
        particle::update(&fixture.scene, dt, WIND);
        record_frame(
            fixture: &fixture,
            pair: &pair,
            dt: dt,
            kind: step + 1 == steps ? FrameKind.FINAL : FrameKind.NORMAL,
            expected_alive: INITIAL_BURST,
            expected_dropped: 0,
        )!!;
    }
}

fn void run_trail_steps(Fixture* fixture, Pair* pair, bool shifted) @private {
    uint steps = TRAIL_STEPS + render::FRAMES_IN_FLIGHT;
    for (uint step = 0; step < steps; step++) {
        float dt = step < TRAIL_STEPS ? STEP_SECONDS : 0;
        if (step == 0) {
            pair.cpu.emit_burst(TRAIL_BURST);
            pair.device.emit_burst(TRAIL_BURST);
        }
        if (shifted && step == TRAIL_SHIFT_AT) {
            fixture.scene.shift_origin(SHIFT_OFFSET);
            fixture.scene.shift_particles(SHIFT_OFFSET);
            assert(fixture.scene.node(pair.device.trail_node).local.position == (Vec3){});
            fixture.scene.update_world();
        }
        particle::update(&fixture.scene, dt, WIND);
        record_frame(
            fixture: fixture,
            pair: pair,
            dt: dt,
            kind: step + 1 == steps ? FrameKind.FINAL : FrameKind.NORMAL,
            expected_alive: pair.cpu.alive,
            expected_dropped: 0,
        )!!;
    }
    assert(pair.cpu.alive > 0 && pair.cpu.alive < TRAIL_BURST);
}

fn void test_gpu_trails_follow_the_cpu_reference() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Pair pair = add_pair(&fixture, trailed: true)!!;
    run_trail_steps(&fixture, &pair, false);
}

fn void test_gpu_trails_follow_an_origin_shift() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Pair pair = add_pair(&fixture, trailed: true)!!;
    run_trail_steps(&fixture, &pair, true);
}
