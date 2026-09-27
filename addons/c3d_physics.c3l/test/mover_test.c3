module c3d_physics_mover_test;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::maths;
import c3d::physics;
import c3d::scene;

alias Quat @private = Quaternionf;

const float TOLERANCE @private = 0.0001f;
const float CAPSULE_RADIUS @private = 0.3f;
const float CAPSULE_HALF_HEIGHT @private = 0.5f;
const float SINK @private = 0.01f;  // how far a resting capsule reaches into a surface
const float CLOSING_BAND @private = 0.02f;  // box3d stops a cast within about a slop of contact
const Vec3  WALL_HALF_EXTENTS @private = { 0.5f, 2, 2 };

struct Fixture @private {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
}

struct RecordingPass @private {
    PhysicsWorld* world;
    Node*         target;
    uint          steps;
    uint          writes;
    float         alpha;
}

fn void setup(Fixture* fixture) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    physics::register_physics(&fixture.scene)!!;
    fixture.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &fixture.assets,
        scene:     &fixture.scene,
        desc:      physics::default_physics_desc(),
    )!!;
}

fn void teardown(Fixture* fixture) @private {
    physics::destroy_physics_world(&fixture.physics);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn bool close(float first, float second, float tolerance = TOLERANCE) @private {
    return math::abs(first - second) <= tolerance;
}

fn bool close_vec(Vec3 first, Vec3 second, float tolerance = TOLERANCE) @private {
    return close(first.x, second.x, tolerance) && close(first.y, second.y, tolerance) && close(first.z, second.z, tolerance);
}

fn Node* add_box(
    Fixture* fixture,
    Vec3 position,
    Vec3 half_extents,
    BodyKind kind = STATIC,
) @private {
    Node* node = fixture.scene.add_node(name: "box")!!;
    node.local.position = position;
    fixture.scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = half_extents;
    fixture.physics.add_body(node, physics::default_body_desc(kind), (&collider)[:1])!!;
    return node;
}

fn Node* add_ground(Fixture* fixture) @private {
    return add_box(fixture, { 0, -0.5f, 0 }, { 10, 0.5f, 10 });
}

fn MoverCapsule capsule(Vec3 center) @private {
    return { .center = center, .half_height = CAPSULE_HALF_HEIGHT, .radius = CAPSULE_RADIUS };
}

fn MoverCapsule resting_capsule() @private {
    return capsule({ 0, CAPSULE_HALF_HEIGHT + CAPSULE_RADIUS - SINK, 0 });
}

fn bool accept_all_but(Entity entity, void* context) @private {
    return !c3d::same_id(entity, *(Entity*)context);
}

fn void record_step(void* context, PhysicsWorld* world, float fixed_dt) @private {
    RecordingPass* pass = context;
    pass.steps++;
    if (pass.target) world.set_kinematic_target(pass.target, { 1, 0, 0 }, quaternion::IDENTITY)!!;
}

fn void record_write(void* context, PhysicsWorld* world, float alpha) @private {
    RecordingPass* pass = context;
    pass.writes++;
    pass.alpha = alpha;
}

fn void test_cast_mover_stops_at_a_wall() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_box(&fixture, { 2, 0, 0 }, WALL_HALF_EXTENTS);

    float fraction = fixture.physics.cast_mover(capsule({ 0, 0, 0 }), { 3, 0, 0 });

    assert(close(fraction * 3, 2 - WALL_HALF_EXTENTS.x - CAPSULE_RADIUS, CLOSING_BAND));
}

fn void test_cast_mover_is_one_in_open_space() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    assert(fixture.physics.cast_mover(capsule({ 0, 0, 0 }), { 3, 0, 0 }) == 1);
}

fn void test_cast_mover_accept_rejects_a_node() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* wall = add_box(&fixture, { 2, 0, 0 }, WALL_HALF_EXTENTS);

    float fraction = fixture.physics.cast_mover(
        capsule:     capsule({ 0, 0, 0 }),
        translation: { 3, 0, 0 },
        accept:      &accept_all_but,
        context:     &wall.id,
    );

    assert(fraction == 1);
}

fn void test_collide_mover_reports_the_ground_plane() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* ground = add_ground(&fixture);
    MoverCapsule mover = resting_capsule();

    MoverPlane[4] planes;
    usz count = fixture.physics.collide_mover(mover, planes[..]);

    assert(count == 1);
    assert(close_vec(planes[0].normal, { 0, 1, 0 }, 1e-3));
    assert(c3d::same_id(planes[0].entity, ground.id));
    assert(planes[0].push_limit == float::max);
    assert(planes[0].clip_velocity);
    assert(planes[0].point.y < mover.center.y);
}

fn void test_collide_mover_truncates_to_the_slice() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_ground(&fixture);
    float wall_x = WALL_HALF_EXTENTS.x + CAPSULE_RADIUS - SINK;
    add_box(&fixture, { wall_x, 0, 0 }, WALL_HALF_EXTENTS);
    add_box(&fixture, { -wall_x, 0, 0 }, WALL_HALF_EXTENTS);

    MoverPlane[2] planes;
    usz count = fixture.physics.collide_mover(resting_capsule(), planes[..]);

    assert(count == 2);
}

fn void test_solve_then_clip_removes_velocity_into_the_ground() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_ground(&fixture);
    MoverPlane[4] storage;
    MoverPlane[] planes = storage[:fixture.physics.collide_mover(resting_capsule(), storage[..])];
    assert(planes.len == 1);

    MoverSolve solve = physics::solve_planes({ 0, 0, 0 }, planes);
    assert(solve.delta.y > 0);
    assert(planes[0].push > 0, "the solve writes push back into the caller's planes");

    Vec3 clipped = physics::clip_vector({ 1, -5, 0 }, planes);
    assert(close(clipped.x, 1));
    assert(close(clipped.y, 0));

    MoverPlane unpushed = planes[0];
    unpushed.push = 0;
    Vec3 unclipped = physics::clip_vector({ 1, -5, 0 }, (&unpushed)[:1]);
    assert(close_vec(unclipped, { 1, -5, 0 }));
}

fn void test_mover_step_runs_once_per_fixed_step_before_the_solver() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* box = add_box(&fixture, { 0, 0, 0 }, { 0.5f, 0.5f, 0.5f }, KINEMATIC);
    RecordingPass recording = { .world = &fixture.physics, .target = box };
    fixture.physics.set_mover_pass({ .step = &record_step, .write = &record_write, .context = &recording });

    float fixed_dt = fixture.physics.desc.tuning.fixed_dt;
    fixture.physics.update(3.5f * fixed_dt);

    assert(recording.steps == 3);
    assert(fixture.physics.steps_last_update == 3);
    assert(close_vec(fixture.scene.get(box, RigidBody).current.position, { 1, 0, 0 }, 1e-3));
    assert(close_vec(box.world_position(), { 0, 0, 0 }), "the node never moved; the step's target did");
}

fn void test_mover_write_runs_after_zero_steps_with_alpha() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    RecordingPass recording = { .world = &fixture.physics };
    fixture.physics.set_mover_pass({ .step = &record_step, .write = &record_write, .context = &recording });
    float fixed_dt = fixture.physics.desc.tuning.fixed_dt;

    fixture.physics.update(0.5f * fixed_dt);
    assert(recording.steps == 0);
    assert(recording.writes == 1);
    assert(close(recording.alpha, 0.5f, 1e-5));

    PhysicsTuning tuning = fixture.physics.desc.tuning;
    tuning.interpolate = false;
    fixture.physics.set_tuning(tuning);
    fixture.physics.update(0.25f * fixed_dt);
    assert(recording.writes == 2);
    assert(recording.alpha == 1);
}

fn void test_empty_pass_is_skipped() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    RecordingPass recording = { .world = &fixture.physics };
    fixture.physics.set_mover_pass({ .step = &record_step, .write = &record_write, .context = &recording });
    fixture.physics.set_mover_pass({});

    fixture.physics.update(2.5f * fixture.physics.desc.tuning.fixed_dt);

    assert(recording.steps == 0 && recording.writes == 0);
}

fn void test_point_velocity_of_a_moving_kinematic_body() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* box = add_box(&fixture, { 0, 0, 0 }, { 0.5f, 0.5f, 0.5f }, KINEMATIC);
    Node* bare = fixture.scene.add_node(name: "bare")!!;
    float fixed_dt = fixture.physics.desc.tuning.fixed_dt;

    box.local.position = { 0.1f, 0, 0 };
    fixture.scene.update_world();
    fixture.physics.update(1.5f * fixed_dt);

    Vec3 velocity = fixture.physics.point_velocity(box, box.world_position())!!;
    assert(close_vec(velocity, { 0.1f / fixed_dt, 0, 0 }, 1e-2));
    if (catch excuse = fixture.physics.point_velocity(bare, { 0, 0, 0 })) {
        assert(excuse == physics::NO_BODY);
    } else {
        assert(false, "a node without a body faults");
    }
}

fn void test_set_kinematic_target_faults() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* dynamic_box = add_box(&fixture, { 0, 2, 0 }, { 0.5f, 0.5f, 0.5f }, DYNAMIC);
    Node* bare = fixture.scene.add_node(name: "bare")!!;

    if (catch excuse = fixture.physics.set_kinematic_target(dynamic_box, { 1, 0, 0 }, quaternion::IDENTITY)) {
        assert(excuse == physics::NOT_KINEMATIC);
    } else {
        assert(false, "a dynamic body faults");
    }
    if (catch excuse = fixture.physics.set_kinematic_target(bare, { 1, 0, 0 }, quaternion::IDENTITY)) {
        assert(excuse == physics::NO_BODY);
    } else {
        assert(false, "a node without a body faults");
    }
}
