module rebase_bench;

import std::io;
import std::math;
import std::math::quaternion;
import std::sort;
import std::time;
import std::time::clock;
import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::nav;
import c3d::physics;
import c3d::scene;

const uint  STACK_HEIGHT @local = 3;
const float STACK_SKEW @local = 0.0371f; // metres; keeps the boxes off representable coordinates at distance
const float STACK_YAW @local = 0.3f; // radians between neighbouring boxes
const uint  SETTLE_STEPS @local = 120;
const uint  NOISE_STEPS @local = 600;
const float[3] STACK_DISTANCES @local = { 0, 10000, 50000 }; // metres from the origin
const float MICROMETRES @local = 1000000;
const uint  BODY_COLUMNS @local = 64;
const uint  BODY_COUNT @local = BODY_COLUMNS * BODY_COLUMNS;
const float BODY_SPACING @local = 1.5f;
const float BODY_GROUND_HALF @local = 60;
const uint  TILES_PER_SIDE @local = 8; // 64 tiles
const uint  CROWD_AGENTS @local = 64;
const uint  CROWD_WARMUP_UPDATES @local = 30;
const float CROWD_STEP @local = 1.0f / 60.0f;
const uint  BUILD_BUDGET @local = 64;
const uint  COST_RUNS @local = 11;
const float COST_SHIFT @local = 256; // one render cell
const double NANOSECONDS_PER_MICROSECOND @local = 1000.0;
const uint  PHASE_COUNT @local = 6;

enum Phase : uint @local {
    SCENE,
    WORLD,
    PHYSICS,
    NAV_MESH,
    NAV_AGENTS,
    TOTAL,
}

const String[PHASE_COUNT] PHASE_NAMES @local = {
    "scene.shift_origin",
    "scene.update_world",
    "physics.shift_origin",
    "mesh + builder shift",
    "crowd + navigation shift",
    "total",
};

struct Stack @local {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
    Node*[STACK_HEIGHT] boxes;
}

struct Noise @local {
    double sum_squares;
    float  max;
    uint   samples;
}

fn PhysicsDesc awake_physics_desc() @local {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.sleep = false;
    return desc;
}

fn Node* add_box_body(
    Scene* scene,
    PhysicsWorld* physics,
    Vec3 position,
    BodyKind kind,
    Vec3 half_extents,
    float yaw = 0,
) @local {
    Node* node = scene.add_node()!!;
    node.local.position = position;
    node.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, yaw);
    scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = half_extents;
    BodyDesc body = physics::default_body_desc(kind);
    body.allow_sleep = false;
    physics.add_body(node, body, (&collider)[:1])!!;
    return node;
}

fn void build_stack(Stack* stack, float distance) @local {
    stack.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    stack.scene = scene::create_scene(mem, scene::default_scene_desc());
    physics::register_physics(&stack.scene)!!;
    stack.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &stack.assets,
        scene:     &stack.scene,
        desc:      awake_physics_desc(),
    )!!;
    add_box_body(
        scene:        &stack.scene,
        physics:      &stack.physics,
        position:     { distance, -0.5f, 0 },
        kind:         STATIC,
        half_extents: { 10, 0.5f, 10 },
    );
    foreach (index, &box : stack.boxes) {
        *box = add_box_body(
            scene:        &stack.scene,
            physics:      &stack.physics,
            position:     { distance + STACK_SKEW * (float)(index + 1), 0.5f + (float)index, STACK_SKEW },
            kind:         DYNAMIC,
            half_extents: { 0.5f, 0.5f, 0.5f },
            yaw:          STACK_YAW * (float)index,
        );
    }
}

fn void destroy_stack(Stack* stack) @local {
    physics::destroy_physics_world(&stack.physics);
    scene::destroy_scene(&stack.scene);
    asset::destroy_asset_store(&stack.assets);
}

fn void step_stack(Stack* stack) @local {
    stack.physics.update(physics::DEFAULT_FIXED_DT);
    stack.scene.update_world();
}

fn Noise measure_noise(Stack* stack) @local {
    Vec3[STACK_HEIGHT] reference;
    foreach (index, box : stack.boxes) reference[index] = stack.scene.get(box, RigidBody).current.position;
    Noise noise;
    for (uint step = 0; step < NOISE_STEPS; step++) {
        step_stack(stack);
        foreach (index, box : stack.boxes) {
            float change = (stack.scene.get(box, RigidBody).current.position - reference[index]).length();
            noise.sum_squares += (double)(change * change);
            noise.max = math::max(noise.max, change);
            noise.samples++;
        }
    }
    return noise;
}

fn float rms_micrometres(Noise noise) @local {
    return (float)math::sqrt(noise.sum_squares / noise.samples) * MICROMETRES;
}

fn void report_noise(float distance) @local {
    Stack* stack = mem::new(Stack);
    defer free(stack);
    build_stack(stack, distance);
    defer destroy_stack(stack);
    for (uint step = 0; step < SETTLE_STEPS; step++) step_stack(stack);

    Noise before = measure_noise(stack);
    if (distance == 0) {
        io::printfn(
            "%8.0f m   %10.2f %10.2f   %10s %10s",
            distance,
            rms_micrometres(before),
            before.max * MICROMETRES,
            "-",
            "-",
        );
        return;
    }
    Vec3 offset = { distance, 0, 0 };
    stack.scene.shift_origin(offset);
    stack.scene.update_world();
    stack.physics.shift_origin(&stack.scene, offset);
    Noise after = measure_noise(stack);
    io::printfn(
        "%8.0f m   %10.2f %10.2f   %10.2f %10.2f",
        distance,
        rms_micrometres(before),
        before.max * MICROMETRES,
        rms_micrometres(after),
        after.max * MICROMETRES,
    );
}

struct CostWorld @local {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
    NavBuilder   builder;
    NavMesh      mesh;
    Crowd        crowd;
    uint         bodies;
    uint         nodes;
}

fn void add_body_grid(CostWorld* world) @local {
    add_box_body(
        scene:        &world.scene,
        physics:      &world.physics,
        position:     { 0, -0.5f, 0 },
        kind:         STATIC,
        half_extents: { BODY_GROUND_HALF, 0.5f, BODY_GROUND_HALF },
    );
    float origin = -(float)BODY_COLUMNS * BODY_SPACING * 0.5f;
    for (uint index = 0; index < BODY_COUNT; index++) {
        Node*? node = world.scene.add_node();
        if (catch node) return;
        node.local.position = {
            origin + (float)(index % BODY_COLUMNS) * BODY_SPACING,
            0.5f,
            origin + (float)(index / BODY_COLUMNS) * BODY_SPACING,
        };
        world.scene.update_world();
        ColliderDesc collider = physics::default_collider_desc(BOX);
        collider.half_extents = { 0.5f, 0.5f, 0.5f };
        if (catch world.physics.add_body(node, physics::default_body_desc(DYNAMIC), (&collider)[:1])) return;
        world.bodies++;
    }
}

fn void fill_nodes(CostWorld* world) @local {
    Node* parent = world.scene.add_node()!!;
    for (uint count; ; count++) {
        Node*? node = world.scene.add_node(count % 2 ? parent : null);
        if (catch node) break;
        node.local.position = { (float)count * 0.01f, 0, 0 };
    }
    world.scene.update_world();
}

fn void build_navigation(CostWorld* world) @local {
    NavBuildConfig config = nav::default_nav_build_config();
    float side = (float)TILES_PER_SIDE * (config.tile_size * config.cell_size);
    GeometryId plane;
    @pool() {
        Geometry geometry = geometry::plane(tmem, side, side, 1, 1);
        plane = world.assets.add_geometry(&geometry)!!;
    };
    Node* floor = world.scene.add_mesh(plane, {})!!;
    floor.local.position = { side * 0.5f, 0, side * 0.5f };
    world.scene.update_world();
    world.scene.add_nav_source(floor)!!;

    world.builder = nav::create_nav_builder(
        mem,
        &world.scene,
        nav::default_nav_builder_desc({ .min = { 0, -1, 0 }, .max = { side, 5, side } }, config),
    )!!;
    world.mesh = nav::create_nav_mesh_for(mem, &world.builder)!!;
    NavSyncResult built = nav::nav_sync(
        builder: &world.builder,
        mesh:    &world.mesh,
        scene:   &world.scene,
        assets:  &world.assets,
        budget:  BUILD_BUDGET,
    );
    assert(!built.failed && !built.pending);
    world.crowd = nav::create_crowd(
        allocator: mem,
        desc:      { .max_agents = CROWD_AGENTS, .max_agent_radius = nav::default_nav_agent_params().radius },
        mesh:      &world.mesh,
        scene:     &world.scene,
    )!!;
    for (uint index = 0; index < CROWD_AGENTS; index++) {
        Vec3 start = { side * (0.15f + 0.1f * (float)(index % 8)), 0, side * (0.15f + 0.1f * (float)(index / 8)) };
        Vec3 target = { side - start.x, 0, side - start.z };
        uint slot = world.crowd.add_agent(start, nav::default_nav_agent_params())!!;
        NearestPoly goal = world.crowd.query.find_nearest_poly(
            target,
            world.crowd.query_half_extents(),
            world.crowd.filter(0),
        )!!;
        world.crowd.request_move_target(slot, goal.ref, goal.point);
    }
    for (uint update = 0; update < CROWD_WARMUP_UPDATES; update++) world.crowd.update(CROWD_STEP);
}

fn double elapsed_microseconds(time::Clock started) @local {
    return (double)(clock::now() - started) / NANOSECONDS_PER_MICROSECOND;
}

fn double median(double[] values) @local {
    sort::quicksort(values);
    return values[values.len / 2];
}

fn void report_cost() @local {
    CostWorld* world = mem::new(CostWorld);
    defer free(world);
    world.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&world.assets);
    world.scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&world.scene);
    physics::register_physics(&world.scene)!!;
    nav::register_nav(&world.scene)!!;
    world.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &world.assets,
        scene:     &world.scene,
        desc:      physics::default_physics_desc(),
    )!!;
    defer physics::destroy_physics_world(&world.physics);

    build_navigation(world);
    defer {
        nav::destroy_crowd(&world.crowd);
        nav::destroy_nav_mesh(&world.mesh);
        nav::destroy_nav_builder(&world.builder);
    }
    add_body_grid(world);
    fill_nodes(world);
    world.nodes = (uint)world.scene.nodes.len - world.scene.world.entities.free_count;

    double[COST_RUNS][PHASE_COUNT] samples;
    for (uint run = 0; run < COST_RUNS; run++) {
        Vec3 offset = { run % 2 ? -COST_SHIFT : COST_SHIFT, 0, 0 };
        time::Clock started = clock::now();
        time::Clock phase = started;

        world.scene.shift_origin(offset);
        samples[Phase.SCENE][run] = elapsed_microseconds(phase);
        phase = clock::now();
        world.scene.update_world();
        samples[Phase.WORLD][run] = elapsed_microseconds(phase);
        phase = clock::now();
        world.physics.shift_origin(&world.scene, offset);
        samples[Phase.PHYSICS][run] = elapsed_microseconds(phase);
        phase = clock::now();
        world.mesh.shift_origin(offset);
        world.builder.shift_origin(offset);
        samples[Phase.NAV_MESH][run] = elapsed_microseconds(phase);
        phase = clock::now();
        world.crowd.shift_origin(offset);
        world.scene.shift_navigation(offset);
        samples[Phase.NAV_AGENTS][run] = elapsed_microseconds(phase);
        samples[Phase.TOTAL][run] = elapsed_microseconds(started);
    }
    uint resident;
    foreach (&tile : world.mesh.tiles) {
        if (tile.header) resident++;
    }
    io::printfn(
        "nodes %d (limit %d), bodies %d of %d requested, resident tiles %d of %d, agents %d",
        world.nodes,
        world.scene.nodes.len,
        world.bodies,
        BODY_COUNT,
        resident,
        TILES_PER_SIDE * TILES_PER_SIDE,
        CROWD_AGENTS,
    );
    io::printfn("median of %d runs", COST_RUNS);
    foreach (phase_index, name : PHASE_NAMES) {
        io::printfn("  %-26s %10.1f us", name, median(&samples[phase_index]));
    }
}

fn int main() {
    io::printfn("Resting-stack noise, %d steps at %.4f s, sleep disabled (um)", NOISE_STEPS, physics::DEFAULT_FIXED_DT);
    io::printfn("%10s   %10s %10s   %10s %10s", "distance", "rms", "max", "rebased rms", "rebased max");
    foreach (distance : STACK_DISTANCES) report_noise(distance);
    io::printn("");
    report_cost();
    return 0;
}
