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

struct FluidSurface @local {
    float  level;
    bool   shores;
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

fn void setup(Fixture* fixture, FluidSurface* surface) @local {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    physics::register_physics(&fixture.scene)!!;
    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      physics::default_physics_desc(),
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
) @local {
    Node* node = fixture.scene.add_node()!!;
    node.local.position = position;
    fixture.scene.update_world();
    fixture.physics.add_body(node, physics::default_body_desc(DYNAMIC), colliders)!!;
    fixture.scene.add(node, (Buoyancy){ .fluid_density = physics::DEFAULT_FLUID_DENSITY, .linear_drag = drag });
    return node;
}

fn void settle(Fixture* fixture) @local {
    for (uint step = 0; step < SETTLE_STEPS; step++) fixture.physics.update(fixture.physics.desc.tuning.fixed_dt);
}

fn float fraction_of(Fixture* fixture, Node* node) @local => fixture.scene.get(node, Buoyancy).submerged_fraction;

fn float body_height(Fixture* fixture, Node* node) @local => fixture.scene.get(node, RigidBody).current.position.y;

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
