module c3d::render::cloth_gpu_acceptance;

import c3d;
import c3d::anim;
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
import std::math::quaternion;

const uint SMALL_CELLS @private = 32; // a 33x33-vertex flag, one workgroup per step
const uint LARGE_CELLS @private = 40; // a 41x41-vertex flag, above DEVICE_SINGLE_PASS_PARTICLES
const float FLAG_WIDTH @private = 1.8f;
const float FLAG_DEPTH @private = 1.2f;
const float POLE_HEIGHT @private = 3;
const Vec3 FLAG_ORIGIN @private = { 0, POLE_HEIGHT, 0 };
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
const float MIN_BATCH_TRAVEL @private = 0.1f; // metres; followers of a small owner motion move less than a swinging flag
const float TWIN_GROUND @private = POLE_HEIGHT - 0.5f; // the swinging sheet reaches the plane
const uint IMAGE_SIZE @private = 64;
const uint MOTION_PERIOD @private = 60; // steps of one owner sway
const float OWNER_MOTION @private = 0.1f; // metres of sway and radians of yaw
const float TIP_ROLL_SHARE @private = 0.2f; // of OWNER_MOTION, in radians, for the tip of a skinned rig
const float FOLLOWER_DAMPING @private = 24; // per second; the flag follows its owner almost quasi-statically, so rounding noise does not grow
const float FOLLOWER_STRETCH @private = 0.5f; // a stiffer stretch amplifies rounding noise past what the tolerance leaves
const float SOFT_COMPLIANCE @private = 0.04f; // of the order of a particle's inverse mass over one substep squared
const Vec3 BREEZE @private = { 0, 0, 1 }; // m/s, across the hanging flag
const float BREEZE_CAP @private = 0.9f; // m/s; below the breeze, so the cap applies
const float BREEZE_DAMPING @private = 12; // per second; a flutter amplifies rounding noise, a damped hanging flag does not
const uint TRANSPORT_LEVELS @private = 4;
const uint JOINT_COUNT @private = 2;
const usz MAX_CONTROLS @private = 4; // soft, transport, wind and bends
const float FEATURE_FLOOR @private = 4e-3f; // metres; twice the tolerance, so a missing feature cannot hide inside it

struct Fixture @private {
    AssetStore     assets;
    Scene          scene;
    PhysicsWorld   physics;
    Renderer       renderer;
    GpuCloths      cloths;
    Node*          camera;
    RenderTargetId target;
    ViewId         view;
    SkeletonId     skeleton;
    Node*[2]       joints; // the rig of skinned flags: a root at the pole and a tip under it
}

struct FlagOptions @private {
    float bend_stiffness; // distance bends project at this stiffness
    bool  soft;           // the second row is held by soft attachments
    bool  transport;      // each particle follows its owner's motion by a weight that varies per particle
    bool  wind;           // a breeze blows across the flag
    bool  skinned;        // the owner is skinned to the rig
    bool  grounded;       // the ground plane stops the cloth
    bool  hanging;        // the flag starts hanging from its pins, so gravity only stretches it
    float damping;        // per second; zero keeps DAMPING
    float stretch_stiffness; // zero keeps the cloth default
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
fn GeometryId? add_flag_geometry(Fixture* fixture, uint cells, bool skinned = false, bool hanging = false) @private {
    uint side = cells + 1;
    Geometry sheet = {
        .positions = alloc::new_array(tmem, Vec3, (sz)(side * side)),
        .indices   = alloc::new_array(tmem, uint, (sz)(6 * cells * cells)),
    };
    if (skinned) {
        sheet.joints = alloc::new_array(tmem, ushort[<4>], (sz)(side * side));
        sheet.weights = alloc::new_array(tmem, Vec4, (sz)(side * side));
    }
    for (uint row = 0; row < side; row++) {
        for (uint column = 0; column < side; column++) {
            float depth = (float)row / cells * FLAG_DEPTH;
            sheet.positions[row * side + column] = {
                (float)column / cells * FLAG_WIDTH,
                hanging ? -depth : 0,
                hanging ? 0 : depth,
            };
            if (skinned) {
                float tip_share = (float)row / cells;
                sheet.joints[row * side + column] = { 0, 1, 0, 0 };
                sheet.weights[row * side + column] = { 1 - tip_share, tip_share, 0, 0 };
            }
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

fn void? add_rig(Fixture* fixture) @private {
    if (fixture.skeleton.generation) return;

    int[] parents = alloc::new_array(mem, int, JOINT_COUNT);
    parents[0] = -1;
    parents[1] = 0;
    Mat4[] inverse_bind = alloc::new_array(mem, Mat4, JOINT_COUNT);
    foreach (&bind : inverse_bind) *bind = matrix::IDENTITY4;
    Skeleton skeleton = { .parents = parents, .inverse_bind = inverse_bind };
    fixture.skeleton = fixture.assets.add_skeleton_owned(&skeleton)!;
    fixture.joints[0] = fixture.scene.add_node(name: "pole_joint")!;
    fixture.joints[0].local.position = { 0, POLE_HEIGHT, 0 };
    fixture.joints[1] = fixture.scene.add_node(fixture.joints[0], "tip_joint")!;
}

fn ClothAttachment[] soft_row(uint cells) @private {
    ClothAttachment[] row = alloc::new_array(tmem, ClothAttachment, (sz)(cells + 1));
    foreach (column, &attachment : row) {
        *attachment = { .particle = cells + 1 + (uint)column, .weight = 1, .compliance = SOFT_COMPLIANCE };
    }
    return row;
}

fn float[] transport_weights(uint particles) @private {
    float[] weights = alloc::new_array(tmem, float, (sz)particles);
    foreach (index, &weight : weights) *weight = (float)(index % TRANSPORT_LEVELS) / TRANSPORT_LEVELS;
    return weights;
}

fn Node*? add_flag(
    Fixture* fixture,
    GeometryId geometry,
    uint cells,
    ClothExecution execution,
    Entity[] colliders = {},
    uint[] pins = {},
    Vec3 position = FLAG_ORIGIN,
    float yaw = 0,
    FlagOptions options = {},
) @private {
    MaterialCommon two_sided = material::MATERIAL_COMMON_DEFAULT;
    two_sided.double_sided = true;
    MaterialId material = fixture.assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }, two_sided))!;
    Node* flag = fixture.scene.add_mesh(geometry, material, name: "flag")!;
    flag.local.position = position;
    flag.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, yaw);
    if (options.skinned) {
        add_rig(fixture)!;
        Node*[] joints = alloc::new_array(mem, Node*, JOINT_COUNT);
        joints[..] = fixture.joints[..];
        fixture.scene.add(flag, (SkinBinding){ .skeleton = fixture.skeleton, .joints = joints });
    }
    fixture.scene.update_world();

    if (!pins.len) {
        pins = alloc::new_array(tmem, uint, (sz)(cells + 1));
        foreach (index, &pin : pins) *pin = (uint)index;
    }
    ClothDesc desc = cloth::default_cloth_desc();
    desc.pins = pins;
    desc.colliders = colliders;
    desc.bend_stiffness = options.bend_stiffness;
    desc.damping = options.damping > 0 ? options.damping : DAMPING;
    desc.ground_height = TWIN_GROUND;
    desc.execution = execution;
    desc.collide_ground = options.grounded;
    if (options.stretch_stiffness > 0) desc.stretch_stiffness = options.stretch_stiffness;
    if (options.soft) desc.attachments = soft_row(cells);
    if (options.transport) desc.transport = transport_weights((cells + 1) * (cells + 1));
    fixture.scene.add_cloth(&fixture.assets, flag, desc, &fixture.physics)!;
    if (options.wind) {
        fixture.scene.add(flag, (Wind){ .velocity = BREEZE, .max_speed = BREEZE_CAP });
    }
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
    float effect;   // metres the least effective of the controls differs from the host twin
}

// The owner sways and turns along a period of MOTION_PERIOD steps; a skinned owner stays and its rig does.
fn void pose_owners(Fixture* fixture, Node*[] flags, uint step, bool skinned) @private {
    float phase = 2 * (float)math::PI * (float)step / MOTION_PERIOD;
    float sway = OWNER_MOTION * math::sin(phase);
    Quat yaw = quaternion::from_axis_angle{float}({ 0, 1, 0 }, OWNER_MOTION * math::sin(phase));
    if (skinned) {
        fixture.joints[0].local.position = { sway, POLE_HEIGHT, 0 };
        fixture.joints[0].local.rotation = yaw;
        float roll = OWNER_MOTION * TIP_ROLL_SHARE * math::sin(2 * phase);
        fixture.joints[1].local.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, roll);
    } else {
        foreach (flag : flags) {
            flag.local.position = { sway, POLE_HEIGHT, 0 };
            flag.local.rotation = yaw;
        }
    }
    fixture.scene.update_world();
}

fn TwinResult compare_twins(Fixture* fixture, Node* host, Node* device, Vec3[] initial) @private {
    ClothState* host_state = fixture.scene.get(host, Cloth).state;
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

// One option set per feature the case turns on, with that feature off.
fn usz feature_controls(FlagOptions options, FlagOptions[] controls) @private {
    usz count;
    if (options.soft) {
        controls[count] = options;
        controls[count++].soft = false;
    }
    if (options.transport) {
        controls[count] = options;
        controls[count++].transport = false;
    }
    if (options.wind) {
        controls[count] = options;
        controls[count++].wind = false;
    }
    if (options.bend_stiffness != 0) {
        controls[count] = options;
        controls[count++].bend_stiffness = 0;
    }
    return count;
}

// Host clothes with one feature of the case removed each; the case must differ from every one of them.
fn float least_effect(Fixture* fixture, Node* host, Node*[] controls) @private {
    ClothState* host_state = fixture.scene.get(host, Cloth).state;
    float least = float::max;
    foreach (control : controls) {
        ClothState* control_state = fixture.scene.get(control, Cloth).state;
        float effect;
        foreach (index, position : host_state.positions) {
            effect = math::max(effect, (position - control_state.positions[index]).length());
        }
        least = math::min(least, effect);
    }
    return least;
}

fn TwinResult twin_run(
    Fixture* fixture,
    uint cells,
    ClothStepShape shape,
    FlagOptions options = {},
    bool moving = false,
    bool controlled = false,
) @private {
    GeometryId geometry = add_flag_geometry(fixture, cells, options.skinned, options.hanging)!!;
    Node* host = add_flag(fixture, geometry, cells, ClothExecution.CPU, options: options)!!;
    Node* device = add_flag(fixture, geometry, cells, ClothExecution.GPU, options: options)!!;
    Node*[2 + MAX_CONTROLS] flags;
    flags[0] = host;
    flags[1] = device;
    usz flag_count = 2;
    if (controlled) {
        FlagOptions[MAX_CONTROLS] controls;
        usz control_count = feature_controls(options, controls[..]);
        foreach (control : controls[:control_count]) {
            flags[flag_count++] = add_flag(fixture, geometry, cells, ClothExecution.CPU, options: control)!!;
        }
    }
    ClothState* host_state = fixture.scene.get(host, Cloth).state;
    assert(cloth_gpu::step_shape((uint)host_state.positions.len) == shape);
    Vec3[] initial = alloc::new_array(tmem, Vec3, host_state.positions.len);
    initial[..] = host_state.positions[..];

    for (uint step = 0; step < TWIN_STEPS; step++) {
        if (moving) pose_owners(fixture, flags[:flag_count], step, options.skinned);
        run_frame(fixture, true)!!;
    }
    for (uint frame = 0; frame < render::FRAMES_IN_FLIGHT; frame++) run_frame(fixture, false)!!;
    TwinResult result = compare_twins(fixture, host, device, initial);
    if (controlled) result.effect = least_effect(fixture, host, flags[2:flag_count - 2]);
    return result;
}

fn void report_twin(String name, TwinResult result) @private {
    io::printfn(
        "%s worst %.3e m, travel %.3f m, touching %d, effect %.3e m",
        name,
        result.worst,
        result.travel,
        result.touching,
        result.effect,
    );
    assert(result.worst <= TWIN_TOLERANCE);
}

fn void test_small_flag_matches_its_cpu_twin_in_one_dispatch_per_step() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);

    @pool() {
        TwinResult result = twin_run(
            &fixture,
            SMALL_CELLS,
            ClothStepShape.SINGLE,
            { .bend_stiffness = cloth::DEFAULT_BEND_STIFFNESS, .grounded = true },
            controlled: true,
        );
        report_twin("v1 single", result);
        assert(result.travel > MIN_TRAVEL && result.touching > 0);
        assert(result.effect >= FEATURE_FLOOR);
    };
}

fn void test_large_flag_matches_its_cpu_twin_in_fused_passes() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);

    @pool() {
        TwinResult result = twin_run(
            &fixture,
            LARGE_CELLS,
            ClothStepShape.FUSED,
            { .bend_stiffness = cloth::DEFAULT_BEND_STIFFNESS, .grounded = true },
            controlled: true,
        );
        report_twin("v1 fused", result);
        assert(result.travel > MIN_TRAVEL && result.touching > 0);
        assert(result.effect >= FEATURE_FLOOR);
    };
}

fn FlagOptions breeze_options() @private {
    return { .wind = true, .hanging = true, .damping = BREEZE_DAMPING };
}

fn void test_small_flag_in_a_breeze_matches_its_cpu_twin() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);

    @pool() {
        TwinResult result = twin_run(&fixture, SMALL_CELLS, ClothStepShape.SINGLE, breeze_options(), controlled: true);
        report_twin("wind single", result);
        assert(result.effect >= FEATURE_FLOOR);
    };
}

fn void test_large_flag_in_a_breeze_matches_its_cpu_twin_in_fused_passes() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);

    @pool() {
        TwinResult result = twin_run(&fixture, LARGE_CELLS, ClothStepShape.FUSED, breeze_options(), controlled: true);
        report_twin("wind fused", result);
        assert(result.effect >= FEATURE_FLOOR);
    };
}

// A flag that follows its moving owner through soft attachments and transport.
fn FlagOptions follower_options(bool skinned) @private {
    return {
        .soft              = true,
        .transport         = true,
        .skinned           = skinned,
        .hanging           = true,
        .damping           = FOLLOWER_DAMPING,
        .stretch_stiffness = FOLLOWER_STRETCH,
    };
}

fn void test_small_flag_with_soft_attachments_follows_a_moving_owner_like_its_cpu_twin() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);

    @pool() {
        TwinResult result = twin_run(
            &fixture,
            SMALL_CELLS,
            ClothStepShape.SINGLE,
            follower_options(false),
            moving:     true,
            controlled: true,
        );
        report_twin("soft single", result);
        assert(result.effect >= FEATURE_FLOOR);
    };
}

fn void test_large_flag_with_soft_attachments_follows_a_moving_owner_like_its_cpu_twin() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);

    @pool() {
        TwinResult result = twin_run(
            &fixture,
            LARGE_CELLS,
            ClothStepShape.FUSED,
            follower_options(false),
            moving:     true,
            controlled: true,
        );
        report_twin("soft fused", result);
        assert(result.effect >= FEATURE_FLOOR);
    };
}

fn void test_small_skinned_flag_follows_its_reference_like_its_cpu_twin() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);

    @pool() {
        TwinResult result = twin_run(
            &fixture,
            SMALL_CELLS,
            ClothStepShape.SINGLE,
            follower_options(true),
            moving:     true,
            controlled: true,
        );
        report_twin("skinned single", result);
        assert(result.effect >= FEATURE_FLOOR);
    };
}

fn void test_large_skinned_flag_follows_its_reference_like_its_cpu_twin_in_fused_passes() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);

    @pool() {
        TwinResult result = twin_run(
            &fixture,
            LARGE_CELLS,
            ClothStepShape.FUSED,
            follower_options(true),
            moving:     true,
            controlled: true,
        );
        report_twin("skinned fused", result);
        assert(result.effect >= FEATURE_FLOOR);
    };
}

// Each differs from the others in size, pins or the pose of its owner, so a workgroup that reads another's parameters fails.
struct FlagSpec @private {
    uint   cells;
    uint[] pins; // empty pins the first row
    Vec3   position;
    float  yaw;
}

fn Node*? add_spec_flag(Fixture* fixture, GeometryId geometry, FlagSpec* spec, ClothExecution execution) @private {
    return add_flag(
        fixture:   fixture,
        geometry:  geometry,
        cells:     spec.cells,
        execution: execution,
        pins:      spec.pins,
        position:  spec.position,
        yaw:       spec.yaw,
    );
}

fn void test_small_flags_of_different_owners_and_pins_step_in_one_dispatch() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);

    @pool() {
        uint[2] corner_pins = { 0, 24 };
        FlagSpec[3] specs = {
            { .cells = 32, .position = FLAG_ORIGIN },
            { .cells = 24, .pins = corner_pins[..], .position = { 3, POLE_HEIGHT, 1 }, .yaw = 0.6f },
            { .cells = 16, .position = { -3, POLE_HEIGHT, -1 }, .yaw = -0.9f },
        };
        Node*[3] hosts;
        Node*[3] devices;
        Vec3[][3] initials;
        foreach (index, &spec : specs) {
            assert(cloth_gpu::step_shape((spec.cells + 1) * (spec.cells + 1)) == ClothStepShape.SINGLE);
            GeometryId geometry = add_flag_geometry(&fixture, spec.cells)!!;
            hosts[index] = add_spec_flag(&fixture, geometry, spec, ClothExecution.CPU)!!;
            devices[index] = add_spec_flag(&fixture, geometry, spec, ClothExecution.GPU)!!;
            ClothState* state = fixture.scene.get(hosts[index], Cloth).state;
            initials[index] = alloc::new_array(tmem, Vec3, state.positions.len);
            initials[index][..] = state.positions[..];
        }

        for (uint step = 0; step < TWIN_STEPS; step++) {
            run_frame(&fixture, true)!!;
            assert(fixture.renderer.stats.dispatches == 1);
        }
        for (uint frame = 0; frame < render::FRAMES_IN_FLIGHT; frame++) run_frame(&fixture, false)!!;

        foreach (index, host : hosts) {
            TwinResult result = compare_twins(&fixture, host, devices[index], initials[index]);
            io::printfn(
                "v1 batch cloth %d worst %.3e m, travel %.3f m, touching %d",
                index,
                result.worst,
                result.travel,
                result.touching,
            );
            assert(result.travel > MIN_TRAVEL && result.touching > 0);
            assert(result.worst <= TWIN_TOLERANCE);
        }
    };
}

fn void test_skinned_flags_of_different_sizes_stage_their_own_references_in_one_dispatch() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);

    @pool() {
        uint[2] sizes = { 32, 24 };
        Node*[2] hosts;
        Node*[2] devices;
        Vec3[][2] initials;
        foreach (index, cells : sizes) {
            GeometryId geometry = add_flag_geometry(&fixture, cells, skinned: true, hanging: true)!!;
            hosts[index] = add_flag(&fixture, geometry, cells, ClothExecution.CPU, options: follower_options(true))!!;
            devices[index] = add_flag(&fixture, geometry, cells, ClothExecution.GPU, options: follower_options(true))!!;
            ClothState* state = fixture.scene.get(hosts[index], Cloth).state;
            initials[index] = alloc::new_array(tmem, Vec3, state.positions.len);
            initials[index][..] = state.positions[..];
        }

        for (uint step = 0; step < TWIN_STEPS; step++) {
            pose_owners(&fixture, {}, step, true);
            run_frame(&fixture, true)!!;
            assert(fixture.renderer.stats.dispatches == 1);
        }
        for (uint frame = 0; frame < render::FRAMES_IN_FLIGHT; frame++) run_frame(&fixture, false)!!;

        foreach (index, host : hosts) {
            TwinResult result = compare_twins(&fixture, host, devices[index], initials[index]);
            report_twin("skinned batch", result);
            assert(result.travel > MIN_BATCH_TRAVEL);
        }
    };
}

fn void test_a_plain_flag_and_a_featured_flag_step_in_one_dispatch() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);

    @pool() {
        FlagOptions plain = { .hanging = true, .damping = FOLLOWER_DAMPING, .stretch_stiffness = FOLLOWER_STRETCH };
        FlagOptions[2] options = { plain, follower_options(false) };
        Node*[2] hosts;
        Node*[2] devices;
        Vec3[][2] initials;
        foreach (index, option : options) {
            GeometryId geometry = add_flag_geometry(&fixture, SMALL_CELLS, hanging: option.hanging)!!;
            hosts[index] = add_flag(&fixture, geometry, SMALL_CELLS, ClothExecution.CPU, options: option)!!;
            devices[index] = add_flag(&fixture, geometry, SMALL_CELLS, ClothExecution.GPU, options: option)!!;
            ClothState* state = fixture.scene.get(hosts[index], Cloth).state;
            initials[index] = alloc::new_array(tmem, Vec3, state.positions.len);
            initials[index][..] = state.positions[..];
        }

        for (uint step = 0; step < TWIN_STEPS; step++) {
            Node*[4] owners = { hosts[0], hosts[1], devices[0], devices[1] };
            pose_owners(&fixture, owners[..], step, false);
            run_frame(&fixture, true)!!;
            assert(fixture.renderer.stats.dispatches == 1);
        }
        for (uint frame = 0; frame < render::FRAMES_IN_FLIGHT; frame++) run_frame(&fixture, false)!!;

        foreach (index, host : hosts) {
            TwinResult result = compare_twins(&fixture, host, devices[index], initials[index]);
            report_twin("mixed batch", result);
        }
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

    fixture.scene.remove_cloth(large_flag);
    FlagOptions breeze = { .bend_stiffness = cloth::DEFAULT_BEND_STIFFNESS, .wind = true };
    Node* breezy_flag = add_flag(&fixture, large, LARGE_CELLS, ClothExecution.GPU, options: breeze)!!;
    state = fixture.scene.get(breezy_flag, Cloth).state;
    passes = state.desc.substeps * state.desc.iterations * (state.edge_colors + state.bend_colors);
    run_frame(&fixture, true)!!;
    assert(fixture.renderer.stats.dispatches == passes + 2); // the first step initializes in a pass of its own
    run_frame(&fixture, true)!!;
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
