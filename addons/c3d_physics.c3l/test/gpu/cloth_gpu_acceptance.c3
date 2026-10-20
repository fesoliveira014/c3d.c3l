module c3d::render::cloth_gpu_acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::material;
import c3d::maths;
import c3d::physics;
import c3d::physics::cloth;
import c3d::render @public;
import c3d::render::cloth_gpu;
import c3d::scene;
import gpu;
import std::io;
import std::math;

const uint SMALL_CELLS @private = 32; // a 33x33-vertex flag, one workgroup per step
const uint LARGE_CELLS @private = 40; // a 41x41-vertex flag, above DEVICE_SINGLE_PASS_PARTICLES
const float FLAG_WIDTH @private = 1.8f;
const float FLAG_DEPTH @private = 1.2f;
const float POLE_HEIGHT @private = 3;
const Vec3 GRAVITY @private = { 0, -9.81f, 0 };
const float DAMPING @private = 3; // per second; settles the swing within the run
const uint SETTLE_FRAMES @private = 270;
const float PIN_TOLERANCE @private = 1e-5f;
const float SETTLED_STEP @private = 5e-4f; // metres between two frames of the run's end
const float HANG_FRACTION @private = 0.9f; // share of the flag's depth the free edge must fall
const Vec3 BALL_CENTER @private = { 0.9f, 2.2f, -0.15f };
const float BALL_RADIUS @private = 0.3f;
const float CONTACT_TOLERANCE @private = 1e-3f;
const uint TWIN_STEPS @private = 60;
const float TWIN_TOLERANCE @private = 2e-3f; // metres; the device against the CPU solver after TWIN_STEPS
const float MIN_TRAVEL @private = 0.5f; // metres; the twins must swing for the comparison to mean anything
const float TWIN_GROUND @private = POLE_HEIGHT - 0.5f; // the swinging sheet reaches the plane
const uint IMAGE_SIZE @private = 64;

struct Fixture @private {
    AssetStore     assets;
    Scene          scene;
    PhysicsWorld   physics;
    Renderer       renderer;
    GpuCloths      cloths;
    Node*          camera;
    RenderTargetId target;
    ViewId         view;
}

fn void? create_fixture(Fixture* fixture, GpuClothsDesc budget = cloth_gpu::GPU_CLOTHS_DEFAULT) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer catch asset::destroy_asset_store(&fixture.assets);
    fixture.scene = scene::create_scene(mem, { .max_nodes = 16 });
    defer catch scene::destroy_scene(&fixture.scene);
    physics::register_physics(&fixture.scene)!;
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.gravity = GRAVITY;
    desc.tuning.interpolate = false;
    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      desc,
    )!;
    defer catch physics::destroy_physics_world(&fixture.physics);
    fixture.renderer = render::create_renderer(mem, &fixture.assets, { .validation = true })!;
    defer catch render::destroy_renderer(&fixture.renderer);
    fixture.cloths = cloth_gpu::create_gpu_cloths(mem, &fixture.assets, budget)!;
    defer catch cloth_gpu::destroy_gpu_cloths(&fixture.cloths, &fixture.renderer);

    fixture.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(IMAGE_SIZE, IMAGE_SIZE, PixelFormat.RGBA16_FLOAT),
    )!;
    ViewDesc view_desc = render::texture_view_desc(fixture.target);
    view_desc.post.anti_aliasing = AntiAliasing.TAA;
    view_desc.post.motion_blur = true;
    fixture.view = render::create_view(&fixture.renderer, view_desc)!;
    fixture.camera = fixture.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    fixture.camera.local.position = { FLAG_WIDTH * 0.5f, POLE_HEIGHT - 0.6f, 3 };
}

fn void destroy_fixture(Fixture* fixture) @private {
    check_validation(fixture);
    cloth_gpu::destroy_gpu_cloths(&fixture.cloths, &fixture.renderer);
    render::destroy_renderer(&fixture.renderer);
    physics::destroy_physics_world(&fixture.physics);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn void check_validation(Fixture* fixture) @private {
    DebugEntry[render::DEBUG_LOG_ENTRIES] entries;
    usz count = fixture.renderer.log.recent(entries[..]);
    foreach (entry : entries[:count]) {
        bool backend_validation = entry.category.backend && entry.category.validation;
        bool failing = entry.severity == gpu::DebugMessageSeverity.ERROR
          || entry.severity == gpu::DebugMessageSeverity.WARNING;
        assert(!(backend_validation && failing));
    }
}

// A flag in the horizontal plane, pinned along its first row, which gravity swings down to hang from the pins.
fn GeometryId? add_flag_geometry(Fixture* fixture, uint cells) @private {
    uint side = cells + 1;
    Geometry sheet = {
        .positions = alloc::new_array(tmem, Vec3, (sz)(side * side)),
        .indices   = alloc::new_array(tmem, uint, (sz)(6 * cells * cells)),
    };
    for (uint row = 0; row < side; row++) {
        for (uint column = 0; column < side; column++) {
            sheet.positions[row * side + column] = {
                (float)column / cells * FLAG_WIDTH,
                0,
                (float)row / cells * FLAG_DEPTH,
            };
        }
    }
    usz next;
    for (uint row = 0; row < cells; row++) {
        for (uint column = 0; column < cells; column++) {
            uint top_left = row * side + column;
            uint bottom_left = top_left + side;
            uint[6] corners = { top_left, top_left + 1, bottom_left, top_left + 1, bottom_left + 1, bottom_left };
            sheet.indices[next:6] = corners[..];
            next += 6;
        }
    }
    sheet.finalize();
    return fixture.assets.add_geometry(&sheet);
}

fn Node*? add_flag(
    Fixture* fixture,
    GeometryId geometry,
    uint cells,
    ClothExecution execution,
    Entity[] colliders = {},
) @private {
    MaterialCommon two_sided = material::MATERIAL_COMMON_DEFAULT;
    two_sided.double_sided = true;
    MaterialId material = fixture.assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }, two_sided))!;
    Node* flag = fixture.scene.add_mesh(geometry, material, name: "flag")!;
    flag.local.position = { 0, POLE_HEIGHT, 0 };
    fixture.scene.update_world();

    uint[] pins = alloc::new_array(tmem, uint, (sz)(cells + 1));
    foreach (index, &pin : pins) *pin = (uint)index;
    ClothDesc desc = cloth::default_cloth_desc();
    desc.pins = pins;
    desc.colliders = colliders;
    desc.bend_stiffness = 0;
    desc.damping = DAMPING;
    desc.ground_height = TWIN_GROUND;
    desc.execution = execution;
    fixture.scene.add_cloth(&fixture.assets, flag, desc, &fixture.physics)!;
    return flag;
}

fn Node*? add_ball(Fixture* fixture) @private {
    Node* ball = fixture.scene.add_node(name: "ball")!;
    ball.local.position = BALL_CENTER;
    fixture.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(SPHERE);
    collider.radius = BALL_RADIUS;
    fixture.physics.add_body(ball, physics::default_body_desc(STATIC), (&collider)[:1])!;
    fixture.physics.update(0);
    return ball;
}

// What read_positions returned in a frame, before that frame's update.
struct Observation @private {
    Entity cloth;
    Vec4[] positions; // receives the view when it is ready
    fault  failure;
}

// One fixed step, or none, then the device update.
fn void? run_frame(Fixture* fixture, bool stepping, Observation* observation = null) @private {
    Renderer* renderer = &fixture.renderer;
    fixture.physics.update(stepping ? physics::DEFAULT_FIXED_DT : 0);
    fixture.physics.update_cloths();
    fixture.scene.update_world();
    renderer.begin_frame({ .time = 1, .delta = physics::DEFAULT_FIXED_DT })!;
    defer catch render::abort_frame(renderer);
    if (observation) {
        Vec4[]? view = cloth_gpu::read_positions(&fixture.cloths, renderer, observation.cloth);
        if (catch excuse = view) {
            observation.failure = excuse;
        } else {
            observation.failure = {};
            observation.positions[..] = view[..];
        }
    }
    cloth_gpu::update(&fixture.cloths, renderer, &fixture.assets, &fixture.scene)!;
    renderer.render_view(&fixture.scene, fixture.camera, fixture.view)!;
    renderer.finish_view(fixture.view)!;
    renderer.end_frame()!;
}

fn void test_flag_settles_under_gravity_with_pins_held_and_a_sphere_kept_out() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Node* ball = add_ball(&fixture)!!;
    GeometryId geometry = add_flag_geometry(&fixture, SMALL_CELLS)!!;
    Entity[1] colliders = { ball.id };
    Node* flag = add_flag(&fixture, geometry, SMALL_CELLS, ClothExecution.GPU, colliders[..])!!;
    ClothState* state = fixture.scene.get(flag, Cloth).state;
    uint side = SMALL_CELLS + 1;
    Vec3[] initial = alloc::new_array(mem, Vec3, state.positions.len);
    defer alloc::free(mem, initial.ptr);
    initial[..] = state.positions[..];

    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) run_frame(&fixture, true)!!;
    assert(fixture.renderer.stats.upload_bytes == 0 && fixture.renderer.stats.vertex_history_bytes == 0);
    assert(fixture.renderer.stats.dispatches == 1);

    @pool() {
        Vec4[] earlier = alloc::new_array(tmem, Vec4, state.positions.len);
        Vec4[] later = alloc::new_array(tmem, Vec4, state.positions.len);
        Observation early = { .cloth = flag.id, .positions = earlier };
        Observation late = { .cloth = flag.id, .positions = later };
        run_frame(&fixture, true, &early)!!;
        run_frame(&fixture, true, &late)!!;
        assert(!early.failure && !late.failure);
        float lowest = float::max;
        foreach (index, position : later) {
            Vec3 point = { position.x, position.y, position.z };
            assert(math::is_finite(point.x) && math::is_finite(point.y) && math::is_finite(point.z));
            if (index < side) {
                assert((point - initial[index]).length() <= PIN_TOLERANCE);
                continue;
            }
            Vec3 before = { earlier[index].x, earlier[index].y, earlier[index].z };
            assert((point - before).length() <= SETTLED_STEP);
            assert((point - BALL_CENTER).length() >= BALL_RADIUS + state.desc.thickness - CONTACT_TOLERANCE);
            lowest = math::min(lowest, point.y);
        }
        assert(lowest <= POLE_HEIGHT - HANG_FRACTION * FLAG_DEPTH);
    };
}

struct TwinResult @private {
    float worst;    // metres between a particle and its twin
    float travel;   // metres the farthest particle moved from its rest pose
    uint  touching; // particles resting on the ground plane
}

fn TwinResult twin_run(Fixture* fixture, uint cells, ClothStepShape shape) @private {
    GeometryId geometry = add_flag_geometry(fixture, cells)!!;
    Node* host = add_flag(fixture, geometry, cells, ClothExecution.CPU)!!;
    Node* device = add_flag(fixture, geometry, cells, ClothExecution.GPU)!!;
    ClothState* host_state = fixture.scene.get(host, Cloth).state;
    assert(cloth_gpu::step_shape((uint)host_state.positions.len) == shape);
    Vec3[] initial = alloc::new_array(tmem, Vec3, host_state.positions.len);
    initial[..] = host_state.positions[..];

    for (uint step = 0; step < TWIN_STEPS; step++) run_frame(fixture, true)!!;
    for (uint frame = 0; frame < render::FRAMES_IN_FLIGHT; frame++) run_frame(fixture, false)!!;

    TwinResult result;
    Vec4[] device_positions = alloc::new_array(tmem, Vec4, host_state.positions.len);
    Observation observation = { .cloth = device.id, .positions = device_positions };
    run_frame(fixture, false, &observation)!!;
    assert(!observation.failure);
    float ground = TWIN_GROUND + host_state.desc.thickness;
    foreach (index, host_position : host_state.positions) {
        Vec3 device_position = { device_positions[index].x, device_positions[index].y, device_positions[index].z };
        result.worst = math::max(result.worst, (device_position - host_position).length());
        result.travel = math::max(result.travel, (host_position - initial[index]).length());
        if (host_position.y - ground < CONTACT_TOLERANCE) result.touching++;
    }
    return result;
}

fn void test_small_flag_matches_its_cpu_twin_in_one_dispatch_per_step() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);

    @pool() {
        TwinResult result = twin_run(&fixture, SMALL_CELLS, ClothStepShape.SINGLE);
        io::printfn("v1 single worst %.3e m, travel %.3f m, touching %d", result.worst, result.travel, result.touching);
        assert(result.travel > MIN_TRAVEL && result.touching > 0);
        assert(result.worst <= TWIN_TOLERANCE);
    };
}

fn void test_large_flag_matches_its_cpu_twin_in_fused_passes() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);

    @pool() {
        TwinResult result = twin_run(&fixture, LARGE_CELLS, ClothStepShape.FUSED);
        io::printfn("v1 fused worst %.3e m, travel %.3f m, touching %d", result.worst, result.travel, result.touching);
        assert(result.travel > MIN_TRAVEL && result.touching > 0);
        assert(result.worst <= TWIN_TOLERANCE);
    };
}

fn void test_dispatches_per_step_follow_the_step_shape() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    GeometryId small = add_flag_geometry(&fixture, SMALL_CELLS)!!;
    GeometryId large = add_flag_geometry(&fixture, LARGE_CELLS)!!;
    Node* small_flag = add_flag(&fixture, small, SMALL_CELLS, ClothExecution.GPU)!!;

    run_frame(&fixture, true)!!;
    assert(fixture.renderer.stats.dispatches == 1);

    fixture.scene.remove_cloth(small_flag);
    Node* large_flag = add_flag(&fixture, large, LARGE_CELLS, ClothExecution.GPU)!!;
    ClothState* state = fixture.scene.get(large_flag, Cloth).state;
    run_frame(&fixture, true)!!;
    uint passes = state.desc.substeps * state.desc.iterations * state.edge_colors;
    assert(fixture.renderer.stats.dispatches == passes + 1);
}

fn void test_positions_are_not_ready_until_frames_in_flight_pass() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    GeometryId geometry = add_flag_geometry(&fixture, SMALL_CELLS)!!;
    Node* flag = add_flag(&fixture, geometry, SMALL_CELLS, ClothExecution.GPU)!!;
    ClothState* state = fixture.scene.get(flag, Cloth).state;

    @pool() {
        Observation observation = { .cloth = flag.id, .positions = alloc::new_array(tmem, Vec4, state.positions.len) };
        run_frame(&fixture, true, &observation)!!;
        assert(observation.failure == c3d::INVALID_ID);
        for (uint frame = 1; frame < render::FRAMES_IN_FLIGHT; frame++) {
            run_frame(&fixture, true, &observation)!!;
            assert(observation.failure == render::NOT_READY);
        }
        run_frame(&fixture, true, &observation)!!;
        assert(!observation.failure);
        assert(observation.positions[0].w == 0 && observation.positions[observation.positions.len - 1].w != 0);
    };
}

fn void test_cloths_beyond_the_budget_fault_and_leave_room_when_one_departs() @test {
    Fixture fixture;
    GpuClothsDesc budget = cloth_gpu::GPU_CLOTHS_DEFAULT;
    budget.max_particles = 1_200; // one 33x33 flag
    create_fixture(&fixture, budget)!!;
    defer destroy_fixture(&fixture);
    GeometryId geometry = add_flag_geometry(&fixture, SMALL_CELLS)!!;
    Node* first = add_flag(&fixture, geometry, SMALL_CELLS, ClothExecution.GPU)!!;
    Node* second = add_flag(&fixture, geometry, SMALL_CELLS, ClothExecution.GPU)!!;

    assert(@catch(run_frame(&fixture, true)) == c3d::CAPACITY_EXCEEDED);
    fixture.scene.remove_cloth(first);
    run_frame(&fixture, true)!!;
    for (uint frame = 0; frame < render::FRAMES_IN_FLIGHT; frame++) run_frame(&fixture, true)!!;

    @pool() {
        Observation retired = { .cloth = first.id, .positions = alloc::new_array(tmem, Vec4, 33 * 33) };
        Observation packed = { .cloth = second.id, .positions = alloc::new_array(tmem, Vec4, 33 * 33) };
        run_frame(&fixture, true, &retired)!!;
        run_frame(&fixture, true, &packed)!!;
        assert(retired.failure == c3d::INVALID_ID);
        assert(!packed.failure);
    };
}
