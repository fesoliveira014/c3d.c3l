module c3d_buoyancy_test;

import std::math;
import c3d;
import c3d::asset;
import c3d::physics;
import c3d::scene;
import b3;

const uint SETTLE_STEPS @local = 900; // 15 s of fixed steps: the damped bob decays well below the tolerances
const uint RECORDED_SAMPLES @local = 64;
const uint WATCH_STEPS @local = 62; // two of box3d's 0.5 s sleep periods at 60 Hz
const float FLUID_LEVEL @local = 0;
const float DENSITY_TOLERANCE @local = 0.01f; // submerged fraction after settling
const float DRAFT_TOLERANCE @local = 0.01f; // metres
const float FORCE_TOLERANCE @local = 0.001f; // metres per second after one step
const Vec3 RAFT_HALF_EXTENTS @local = { 1, 0.25f, 1 }; // low and wide: floats upright at any density
const float RAFT_DRAG @local = 3000; // newton-seconds per metre; damps the raft's bob within a few seconds
const float LOW_SHORE_X @local = 0; // west of this line the analytic surface lies LOW_SHORE_DEPTH lower
const float LOW_SHORE_DEPTH @local = 5;
const float DRY_SHORE_Z @local = 20; // north of this line there is no fluid at all
const float DEEP_LEVEL @local = 1000; // above every body in the drag tests, so each cell stays fully submerged
const float DENSE_HALF_SIDE @local = 0.5f; // a one metre cube
const float DENSE_DENSITY @local = 3000; // three times the fluid: it sinks to a terminal speed
const float DRAG_COEFFICIENT @local = 1;
const float TERMINAL_SECONDS @local = 10; // about thirty time constants of the cube's approach
const float TERMINAL_TOLERANCE @local = 0.0001f; // relative; measured 4e-6 at 1/60 and 8e-6 at 1/120, float rounding of the velocity update
const float STRONG_DRAG_COEFFICIENT @local = 1e6f; // unclamped, one step would throw the body past the current
const float CURRENT_SPEED @local = 5; // metres per second
const float REVERSAL_TOLERANCE @local = 0.0001f; // metres per second; float rounding of eight cell forces and the velocity update
const uint CURRENT_STEPS @local = 30; // the clamped body reaches the current on the first step
const float DRIFT_TOLERANCE @local = 0.0001f; // metres per second; measured 1e-6 once the raft's drift settles
const uint COMPARED_STEPS @local = 120;
const float REST_TOLERANCE @local = 0.0001f; // metres and metres per second; measured 1e-8 m and 1.3e-7 m/s, float rounding of the cell fractions
const float DROP_HEIGHT @local = 1.5f; // above the surface: the raft splashes in and bobs

struct FluidSurface @local {
    float  level;
    bool   shores;
    Vec3   velocity;
    uint   samples;
    float[RECORDED_SAMPLES] step_offsets;
}

struct Fixture @local {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
}

fn float? analytic_surface(void* context, float x, float z, float step_offset) @local {
    FluidSurface* surface = context;
    if (surface.samples < RECORDED_SAMPLES) surface.step_offsets[surface.samples] = step_offset;
    surface.samples++;
    if (surface.shores && z > DRY_SHORE_Z) return NOT_FOUND~;
    if (surface.shores && x < LOW_SHORE_X) return surface.level - LOW_SHORE_DEPTH;
    return surface.level;
}

fn float? analytic_sampler(
    void* context,
    float x,
    float z,
    float step_offset,
    Vec3* velocity,
) @local {
    FluidSurface* surface = context;
    float height = analytic_surface(context, x, z, step_offset)!;
    *velocity = surface.velocity;
    return height;
}

fn void setup(
    Fixture* fixture,
    FluidSurface* surface,
    PhysicsDesc desc = physics::default_physics_desc(),
) @local {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    physics::register_physics(&fixture.scene)!!;
    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      desc,
    )!!;
    fixture.physics.set_fluid_surface(&analytic_surface, surface);
}

fn void teardown(Fixture* fixture) @local {
    physics::destroy_physics_world(&fixture.physics);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn ColliderDesc box(Vec3 half_extents, float density, Vec3 offset = {}) @local {
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = half_extents;
    collider.density = density;
    collider.local.position = offset;
    return collider;
}

fn Node* add_floater(
    Fixture* fixture,
    Vec3 position,
    ColliderDesc[] colliders,
    float drag,
    float drag_coefficient = 0,
) @local {
    Node* node = fixture.scene.add_node()!!;
    node.local.position = position;
    fixture.scene.update_world();
    fixture.physics.add_body(node, physics::default_body_desc(DYNAMIC), colliders)!!;
    fixture.scene.add(node, (Buoyancy){
        .fluid_density    = physics::DEFAULT_FLUID_DENSITY,
        .linear_drag      = drag,
        .drag_coefficient = drag_coefficient,
    });
    return node;
}

fn void settle(Fixture* fixture) @local {
    for (uint step = 0; step < SETTLE_STEPS; step++) fixture.physics.update(fixture.physics.desc.tuning.fixed_dt);
}

fn float fraction_of(Fixture* fixture, Node* node) @local => fixture.scene.get(node, Buoyancy).submerged_fraction;

fn float body_height(Fixture* fixture, Node* node) @local => fixture.scene.get(node, RigidBody).current.position.y;

fn Vec3 body_velocity(Fixture* fixture, Node* node) @local => fixture.physics.body(node)!!.linear_velocity();

fn float equilibrium_height() @local {
    float height = 2 * RAFT_HALF_EXTENTS.y;
    return FLUID_LEVEL - 0.6f * height + RAFT_HALF_EXTENTS.y;
}

fn void test_lighter_box_settles_at_its_density_line() @test {
    FluidSurface surface = { .level = FLUID_LEVEL };
    Fixture fixture;
    setup(&fixture, &surface);
    defer teardown(&fixture);
    ColliderDesc raft = box(RAFT_HALF_EXTENTS, 600);
    Node* node = add_floater(
        fixture:   &fixture,
        position:  { 0, 0.5f, 0 },
        colliders: (&raft)[:1],
        drag:      RAFT_DRAG,
    );

    settle(&fixture);
    float height = 2 * RAFT_HALF_EXTENTS.y;
    assert(math::abs(fraction_of(&fixture, node) - 0.6f) <= DENSITY_TOLERANCE);
    float expected_center = FLUID_LEVEL - 0.6f * height + RAFT_HALF_EXTENTS.y;
    assert(math::abs(body_height(&fixture, node) - expected_center) <= DRAFT_TOLERANCE);
}

fn void test_heavier_box_sinks() @test {
    FluidSurface surface = { .level = FLUID_LEVEL };
    Fixture fixture;
    setup(&fixture, &surface);
    defer teardown(&fixture);
    ColliderDesc block = box({ 0.5f, 0.5f, 0.5f }, 1500);
    Node* node = add_floater(
        fixture:   &fixture,
        position:  { 0, 0, 0 },
        colliders: (&block)[:1],
        drag:      RAFT_DRAG,
    );

    settle(&fixture);
    assert(body_height(&fixture, node) < FLUID_LEVEL - 10);
    assert(fraction_of(&fixture, node) == 1);
    assert(fixture.physics.body(node)!!.linear_velocity().y < 0);
}

fn Node* add_slab(Fixture* fixture, Vec3 position) @local {
    Node* ground = fixture.scene.add_node()!!;
    ground.local.position = position;
    fixture.scene.update_world();
    ColliderDesc slab = box({ 2, 0.5f, 2 }, 1000);
    fixture.physics.add_body(ground, physics::default_body_desc(STATIC), (&slab)[:1])!!;
    return ground;
}

fn void test_only_submerged_bodies_stay_awake() @test {
    FluidSurface surface = { .level = FLUID_LEVEL, .shores = true };
    Fixture fixture;
    setup(&fixture, &surface);
    defer teardown(&fixture);
    add_slab(&fixture, { -5, -2, 0 });
    add_slab(&fixture, { 5, 1.5f, 30 });
    ColliderDesc raft = box(RAFT_HALF_EXTENTS, 600);
    Node* beached = add_floater(
        fixture:   &fixture,
        position:  { -5, -1.25f, 0 },
        colliders: (&raft)[:1],
        drag:      RAFT_DRAG,
    );
    Node* stranded = add_floater(
        fixture:   &fixture,
        position:  { 5, 2.25f, 30 },
        colliders: (&raft)[:1],
        drag:      RAFT_DRAG,
    );
    Node* afloat = add_floater(
        fixture:   &fixture,
        position:  { 5, 0, 0 },
        colliders: (&raft)[:1],
        drag:      RAFT_DRAG,
    );

    settle(&fixture);
    // A resting floater may nap for one step each sleep period; the next step's buoyancy wakes it.
    bool napped;
    for (uint step = 0; step < WATCH_STEPS; step++) {
        fixture.physics.update(fixture.physics.desc.tuning.fixed_dt);
        assert(!fixture.physics.body(beached)!!.is_awake() && fraction_of(&fixture, beached) == 0);
        assert(!fixture.physics.body(stranded)!!.is_awake() && fraction_of(&fixture, stranded) == 0);
        bool asleep = !fixture.physics.body(afloat)!!.is_awake();
        assert(!(asleep && napped), "A floater slept through two steps.");
        napped = asleep;
    }
    assert(fraction_of(&fixture, afloat) > 0);
}

fn void test_surface_samples_carry_the_step_offset() @test {
    FluidSurface surface = { .level = FLUID_LEVEL };
    Fixture fixture;
    setup(&fixture, &surface);
    defer teardown(&fixture);
    ColliderDesc raft = box(RAFT_HALF_EXTENTS, 600);
    add_floater(
        fixture:   &fixture,
        position:  { 0, 0, 0 },
        colliders: (&raft)[:1],
        drag:      RAFT_DRAG,
    );
    float fixed_dt = fixture.physics.desc.tuning.fixed_dt;

    fixture.physics.update(3.5f * fixed_dt);
    assert(fixture.physics.steps_last_update == 3);
    assert(surface.samples == 3 * physics::BUOYANCY_CELLS);
    for (uint sample = 0; sample < surface.samples; sample++) {
        float step_index = (float)(sample / physics::BUOYANCY_CELLS);
        assert(surface.step_offsets[sample] == step_index * fixed_dt);
    }
}

fn void test_installing_a_surface_replaces_the_previous_one() @test {
    FluidSurface first = { .level = FLUID_LEVEL };
    FluidSurface second = { .level = FLUID_LEVEL };
    Fixture fixture;
    setup(&fixture, &first);
    defer teardown(&fixture);
    ColliderDesc raft = box(RAFT_HALF_EXTENTS, 600);
    Node* node = add_floater(
        fixture:   &fixture,
        position:  { 0, 0, 0 },
        colliders: (&raft)[:1],
        drag:      RAFT_DRAG,
    );
    float fixed_dt = fixture.physics.desc.tuning.fixed_dt;

    fixture.physics.set_fluid_surface(&analytic_surface, &second);
    fixture.physics.update(fixed_dt);
    assert(first.samples == 0);
    assert(second.samples == physics::BUOYANCY_CELLS);
    assert(fraction_of(&fixture, node) > 0);

    fixture.physics.set_fluid_surface(null, null);
    fixture.physics.update(fixed_dt);
    assert(second.samples == physics::BUOYANCY_CELLS);
    assert(fraction_of(&fixture, node) == 0);
}

fn void test_sphere_and_box_of_equal_volume_float_alike() @test {
    FluidSurface surface = { .level = FLUID_LEVEL };
    Fixture fixture;
    setup(&fixture, &surface);
    defer teardown(&fixture);
    float radius = 0.5f;
    float volume = 4.0f / 3.0f * (float)math::PI * radius * radius * radius;
    float half_side = math::pow(volume, 1.0f / 3.0f) / 2;
    ColliderDesc ball = physics::default_collider_desc(SPHERE);
    ball.radius = radius;
    ball.density = 500;
    ColliderDesc cube = box({ half_side, half_side, half_side }, 500);
    Node* sphere_node = add_floater(
        fixture:   &fixture,
        position:  { -3, 0, 0 },
        colliders: (&ball)[:1],
        drag:      RAFT_DRAG,
    );
    Node* box_node = add_floater(
        fixture:   &fixture,
        position:  { 3, 0, 0 },
        colliders: (&cube)[:1],
        drag:      RAFT_DRAG,
    );
    assert(math::abs(fixture.scene.get(sphere_node, RigidBody).solid_volume - volume) <= 0.01f * volume);
    assert(math::abs(fixture.scene.get(box_node, RigidBody).solid_volume - volume) <= 0.001f * volume);

    settle(&fixture);
    assert(math::abs(fraction_of(&fixture, sphere_node) - 0.5f) <= DENSITY_TOLERANCE);
    assert(math::abs(fraction_of(&fixture, box_node) - 0.5f) <= DENSITY_TOLERANCE);

    // Deep under the surface, lift is fluid density x g x volume: net acceleration g at half the fluid's density.
    surface.level = 100;
    float fixed_dt = fixture.physics.desc.tuning.fixed_dt;
    foreach (node : (Node*[2]){ sphere_node, box_node }) {
        fixture.physics.set_velocity(node, {}, {});
    }
    fixture.physics.update(fixed_dt);
    foreach (node : (Node*[2]){ sphere_node, box_node }) {
        assert(fraction_of(&fixture, node) == 1);
        float gained = fixture.physics.body(node)!!.linear_velocity().y;
        assert(math::abs(gained - 9.81f * fixed_dt) <= FORCE_TOLERANCE);
    }
}

fn void test_two_collider_body_floats_at_its_summed_volume() @test {
    FluidSurface surface = { .level = FLUID_LEVEL };
    Fixture fixture;
    setup(&fixture, &surface);
    defer teardown(&fixture);
    ColliderDesc[2] layers = {
        box(RAFT_HALF_EXTENTS, 800, { 0, -RAFT_HALF_EXTENTS.y, 0 }),
        box(RAFT_HALF_EXTENTS, 400, { 0, RAFT_HALF_EXTENTS.y, 0 }),
    };
    Node* node = add_floater(
        fixture:   &fixture,
        position:  { 0, 0, 0 },
        colliders: layers[..],
        drag:      RAFT_DRAG,
    );
    RigidBody* body = fixture.scene.get(node, RigidBody);
    float layer_volume = 8 * RAFT_HALF_EXTENTS.x * RAFT_HALF_EXTENTS.y * RAFT_HALF_EXTENTS.z;
    assert(math::abs(body.solid_volume - 2 * layer_volume) <= 0.001f);

    settle(&fixture);
    // (800 + 400) / 2 over 1000: the summed volume floats at 0.6 of the stack's height.
    float height = 4 * RAFT_HALF_EXTENTS.y;
    assert(math::abs(fraction_of(&fixture, node) - 0.6f) <= DENSITY_TOLERANCE);
    float expected_origin = FLUID_LEVEL - 0.6f * height + height / 2;
    assert(math::abs(body_height(&fixture, node) - expected_origin) <= DRAFT_TOLERANCE);
}

fn float terminal_speed(float time_step) @local {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.fixed_dt = time_step;
    FluidSurface surface = { .level = DEEP_LEVEL };
    Fixture fixture;
    setup(&fixture, &surface, desc);
    defer teardown(&fixture);
    ColliderDesc cube = box({ DENSE_HALF_SIDE, DENSE_HALF_SIDE, DENSE_HALF_SIDE }, DENSE_DENSITY);
    Node* node = add_floater(
        fixture:          &fixture,
        position:         { 0, 0, 0 },
        colliders:        (&cube)[:1],
        drag:             0,
        drag_coefficient: DRAG_COEFFICIENT,
    );

    uint steps = (uint)(TERMINAL_SECONDS / time_step);
    for (uint step = 0; step < steps; step++) fixture.physics.update(time_step);
    return -body_velocity(&fixture, node).y;
}

fn void test_quadratic_drag_reaches_terminal_velocity() @test {
    float side = 2 * DENSE_HALF_SIDE;
    float volume = side * side * side;
    float mass = DENSE_DENSITY * volume;
    float cell_area = (side / 2) * (side / 2); // a cell is half the box along each axis
    float swept_area = cell_area * physics::BUOYANCY_CELLS; // the cells fall side by side and one behind the other
    float net_weight = (mass - physics::DEFAULT_FLUID_DENSITY * volume) * 9.81f;
    float expected = math::sqrt(2 * net_weight / (physics::DEFAULT_FLUID_DENSITY * DRAG_COEFFICIENT * swept_area));

    foreach (time_step : (float[2]){ 1.0f / 60, 1.0f / 120 }) {
        float speed = terminal_speed(time_step);
        assert(math::abs(speed - expected) <= TERMINAL_TOLERANCE * expected, "%f against %f at %f s", speed, expected, time_step);
    }
}

fn void test_drag_clamp_prevents_reversal() @test {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.gravity = {};
    FluidSurface surface = { .level = DEEP_LEVEL, .velocity = { CURRENT_SPEED, 0, 0 } };
    Fixture fixture;
    setup(&fixture, &surface, desc);
    defer teardown(&fixture);
    fixture.physics.set_fluid_sampler(&analytic_sampler, &surface);
    ColliderDesc cube = box({ DENSE_HALF_SIDE, DENSE_HALF_SIDE, DENSE_HALF_SIDE }, physics::DEFAULT_FLUID_DENSITY);
    Node* node = add_floater(
        fixture:          &fixture,
        position:         { 0, 0, 0 },
        colliders:        (&cube)[:1],
        drag:             0,
        drag_coefficient: STRONG_DRAG_COEFFICIENT,
    );

    float previous;
    for (uint step = 0; step < CURRENT_STEPS; step++) {
        fixture.physics.update(fixture.physics.desc.tuning.fixed_dt);
        float speed = body_velocity(&fixture, node).x;
        assert(speed <= CURRENT_SPEED + REVERSAL_TOLERANCE, "step %d overshot the current at %f", step, speed);
        assert(speed >= previous - REVERSAL_TOLERANCE, "step %d slowed to %f", step, speed);
        previous = speed;
    }
    assert(math::abs(previous - CURRENT_SPEED) <= REVERSAL_TOLERANCE);
}

fn void test_moving_fluid_carries_a_floating_body() @test {
    FluidSurface surface = { .level = FLUID_LEVEL, .velocity = { 2, 0, 0 } };
    Fixture fixture;
    setup(&fixture, &surface);
    defer teardown(&fixture);
    fixture.physics.set_fluid_sampler(&analytic_sampler, &surface);
    ColliderDesc raft = box(RAFT_HALF_EXTENTS, 600);
    Node* node = add_floater(
        fixture:          &fixture,
        position:         { 0, equilibrium_height(), 0 },
        colliders:        (&raft)[:1],
        drag:             RAFT_DRAG,
        drag_coefficient: DRAG_COEFFICIENT,
    );

    settle(&fixture);
    assert(math::abs(body_velocity(&fixture, node).x - surface.velocity.x) <= DRIFT_TOLERANCE);
    assert(fixture.scene.get(node, RigidBody).current.position.x > 0);
    assert(math::abs(fraction_of(&fixture, node) - 0.6f) <= DENSITY_TOLERANCE);
    assert(math::abs(body_height(&fixture, node) - equilibrium_height()) <= DRAFT_TOLERANCE);
}

fn void test_floating_body_at_equilibrium_stays_put_under_quadratic_drag() @test {
    FluidSurface surface = { .level = FLUID_LEVEL };
    Fixture fixture;
    setup(&fixture, &surface);
    defer teardown(&fixture);
    fixture.physics.set_fluid_sampler(&analytic_sampler, &surface);
    ColliderDesc raft = box(RAFT_HALF_EXTENTS, 600);
    Node* node = add_floater(
        fixture:          &fixture,
        position:         { 0, equilibrium_height(), 0 },
        colliders:        (&raft)[:1],
        drag:             RAFT_DRAG,
        drag_coefficient: DRAG_COEFFICIENT,
    );

    float worst_offset;
    float worst_speed;
    for (uint step = 0; step < SETTLE_STEPS; step++) {
        fixture.physics.update(fixture.physics.desc.tuning.fixed_dt);
        worst_offset = max(worst_offset, math::abs(body_height(&fixture, node) - equilibrium_height()));
        worst_speed = max(worst_speed, body_velocity(&fixture, node).length());
    }
    assert(worst_offset <= REST_TOLERANCE && worst_speed <= REST_TOLERANCE, "offset %e, speed %e", worst_offset, worst_speed);
}

fn bool same_body_state(Fixture* first, Node* first_node, Fixture* second, Node* second_node) @local {
    RigidBody* a = first.scene.get(first_node, RigidBody);
    RigidBody* b = second.scene.get(second_node, RigidBody);
    return a.current.position == b.current.position
        && a.current.rotation.v == b.current.rotation.v
        && first.physics.body(first_node)!!.linear_velocity() == second.physics.body(second_node)!!.linear_velocity()
        && first.physics.body(first_node)!!.angular_velocity() == second.physics.body(second_node)!!.angular_velocity();
}

fn void test_height_only_surface_equals_a_zero_velocity_sampler() @test {
    FluidSurface surface_context = { .level = FLUID_LEVEL };
    FluidSurface sampler_context = { .level = FLUID_LEVEL };
    Fixture with_surface;
    setup(&with_surface, &surface_context);
    defer teardown(&with_surface);
    Fixture with_sampler;
    setup(&with_sampler, &sampler_context);
    defer teardown(&with_sampler);
    with_sampler.physics.set_fluid_sampler(&analytic_sampler, &sampler_context);
    ColliderDesc raft = box(RAFT_HALF_EXTENTS, 600);
    Node*[2] nodes;
    foreach (index, fixture : (Fixture*[2]){ &with_surface, &with_sampler }) {
        nodes[index] = add_floater(
            fixture:          fixture,
            position:         { 0, DROP_HEIGHT, 0 },
            colliders:        (&raft)[:1],
            drag:             RAFT_DRAG,
            drag_coefficient: DRAG_COEFFICIENT,
        );
    }

    for (uint step = 0; step < COMPARED_STEPS; step++) {
        with_surface.physics.update(with_surface.physics.desc.tuning.fixed_dt);
        with_sampler.physics.update(with_sampler.physics.desc.tuning.fixed_dt);
        assert(same_body_state(&with_surface, nodes[0], &with_sampler, nodes[1]), "bodies diverged at step %d", step);
    }
    assert(fraction_of(&with_surface, nodes[0]) > 0);
}
