module c3d_physics_test;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::debug;
import c3d::physics @public;
import c3d::scene;
import b3;
import b3::draw;

const float SLIDER_FRICTION @private = 0.2f;
const float SLOPE_FRICTION @private = 0.8f;
const float SLOPE_ANGLE @private = 0.3f;     // radians; steep enough that 0.2 slides and 0.8 holds
const uint  RECORDED_UPDATES @private = 30;

fn float max_friction(
    float friction_a,
    SurfaceMaterialId surface_a,
    float friction_b,
    SurfaceMaterialId surface_b,
) @private => math::max(friction_a, friction_b);

fn void build_slope(Fixture* fixture) @private {
    Node* slope = add_static_node(fixture);
    slope.local.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, SLOPE_ANGLE);
    fixture.scene.update_world();
    ColliderDesc surface = box_collider({ 10, 0.5f, 4 });
    surface.material.friction = SLOPE_FRICTION;
    fixture.physics.add_body(slope, physics::default_body_desc(STATIC), (&surface)[:1])!!;
    for (uint index = 0; index < 3; index++) {
        Node* box = add_static_node(fixture, { -2 + 2 * (float)index, 2, (float)index - 1 });
        box.local.rotation = slope.local.rotation;
        fixture.scene.update_world();
        ColliderDesc crate = box_collider({ 0.4f, 0.4f, 0.4f });
        crate.material.friction = SLIDER_FRICTION;
        fixture.physics.add_body(box, physics::default_body_desc(DYNAMIC), (&crate)[:1])!!;
    }
}

fn char[] record_slope(Fixture* fixture, Allocator allocator, uint* steps) @private {
    fixture.physics.start_recording(0)!!;
    build_slope(fixture);
    for (uint update = 0; update < RECORDED_UPDATES; update++) {
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        *steps += fixture.physics.steps_last_update;
    }
    return fixture.physics.stop_recording(allocator)!!;
}

fn void replay_to_end(PhysicsReplay* replay) @private {
    while (replay.step()) {}
}

fn PhysicsDesc mixed_desc(uint workers = 1) @private {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.friction_mix = &max_friction;
    desc.worker_count = workers;
    return desc;
}

fn void test_recording_round_trips_through_a_replay() @test {
    assert(max_friction(SLIDER_FRICTION, {}, SLOPE_FRICTION, {}) != math::sqrt(SLIDER_FRICTION * SLOPE_FRICTION));
    Fixture fixture;
    setup(&fixture, mixed_desc());
    defer teardown(&fixture);
    uint steps;
    char[] bytes = record_slope(&fixture, mem, &steps);
    defer free(bytes);

    PhysicsReplay replay = physics::create_physics_replay(mem, bytes, &max_friction, null)!!;
    defer physics::destroy_physics_replay(&replay);
    assert(replay.frame_count() == steps);
    replay_to_end(&replay);
    assert(@catch(replay.diverge_frame()) == b3::NO_HIT);
    replay.seek(0);
    replay_to_end(&replay);
    assert(@catch(replay.diverge_frame()) == b3::NO_HIT);
    replay.restart();
    replay_to_end(&replay);
    assert(@catch(replay.diverge_frame()) == b3::NO_HIT);
    assert(replay.frame() == steps);
}

fn void test_replay_without_the_mix_diverges() @test {
    Fixture fixture;
    setup(&fixture, mixed_desc());
    defer teardown(&fixture);
    uint steps;
    char[] bytes = record_slope(&fixture, mem, &steps);
    defer free(bytes);

    PhysicsReplay replay = physics::create_physics_replay(mem, bytes, null, null)!!;
    defer physics::destroy_physics_replay(&replay);
    replay_to_end(&replay);
    assert(@ok(replay.diverge_frame()));
}

fn void test_replay_across_worker_counts() @test {
    uint[2] worker_counts = { 1, 4 };
    foreach (workers : worker_counts) {
        Fixture fixture;
        setup(&fixture, mixed_desc(workers));
        defer teardown(&fixture);
        uint steps;
        char[] bytes = record_slope(&fixture, mem, &steps);
        defer free(bytes);

        PhysicsReplay replay = physics::create_physics_replay(mem, bytes, &max_friction, null)!!;
        defer physics::destroy_physics_replay(&replay);
        replay_to_end(&replay);
        assert(@catch(replay.diverge_frame()) == b3::NO_HIT);
    }
}

fn void test_recording_faults() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    assert(!fixture.physics.recording_active());
    fixture.physics.start_recording(0)!!;
    assert(fixture.physics.recording_active());
    assert(@catch(fixture.physics.start_recording(0)) == physics::RECORDING_ACTIVE);
    char[] bytes = fixture.physics.stop_recording(mem)!!;
    free(bytes);
    assert(!fixture.physics.recording_active());
    assert(@catch(fixture.physics.stop_recording(mem)) == physics::NOT_RECORDING);
}

fn void test_replay_shapes_cook_wires_and_bounds() @test {
    b3::BoxHull box = b3::make_box_hull(0.5f, 0.5f, 0.5f);
    draw::DebugShape box_shape = { .type = HULL, .hull = &box.base };
    ReplayShape cooked = physics::cook_replay_shape(tmem, &box_shape);
    assert(cooked.wire.len == physics::BOX_EDGE_POINTS && !cooked.has_bounds);

    b3::CompoundHullDef[1] hulls = {{ .hull = &box.base, .transform = { .q = quaternion::IDENTITY } }};
    b3::CompoundSphereDef[1] spheres = {{ .sphere = { .center = { 2, 0, 0 }, .radius = 0.5f } }};
    b3::CompoundDef compound_def = { .hulls = &hulls[0], .hull_count = 1, .spheres = &spheres[0], .sphere_count = 1 };
    b3::CompoundData* compound = b3::create_compound(&compound_def)!!;
    defer b3::destroy_compound(compound);
    draw::DebugShape compound_shape = { .type = COMPOUND, .compound = compound };
    cooked = physics::cook_replay_shape(tmem, &compound_shape);
    assert(cooked.wire.len == physics::BOX_EDGE_POINTS + 3 * physics::COMPOUND_RING_SEGMENTS * 2 && !cooked.has_bounds);

    Vec3[3] vertices = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 0, 1 } };
    int[3] indices = { 0, 1, 2 };
    b3::MeshDef mesh_def = { .vertices = &vertices[0], .indices = &indices[0], .vertex_count = 3, .triangle_count = 1 };
    b3::MeshData* mesh_data = b3::create_mesh(&mesh_def)!!;
    defer b3::destroy_mesh(mesh_data);
    b3::Mesh mesh = { .data = mesh_data, .scale = { 2, 1, 2 } };
    draw::DebugShape mesh_shape = { .type = MESH, .mesh = &mesh };
    cooked = physics::cook_replay_shape(tmem, &mesh_shape);
    b3::Aabb expected = mesh_data.compute_aabb({ .q = quaternion::IDENTITY }, mesh.scale);
    assert(cooked.wire.len == 0 && cooked.has_bounds);
    assert(close_vec(cooked.bounds.min, expected.lower_bound) && close_vec(cooked.bounds.max, expected.upper_bound));
}

fn void test_replay_draws_the_recorded_queries() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    add_ground(&fixture);
    add_box(&fixture, { 0, 0.5f, 0 });
    fixture.physics.start_recording(0)!!;
    for (uint update = 0; update < RECORDED_UPDATES; update++) {
        (void)fixture.physics.overlap_sphere(tmem, { 0, 0.5f, 0 }, 1);
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
    }
    char[] bytes = fixture.physics.stop_recording(mem)!!;
    defer free(bytes);

    PhysicsReplay replay = physics::create_physics_replay(mem, bytes, null, null)!!;
    defer physics::destroy_physics_replay(&replay);
    assert(replay.step() && replay.step());
    debug::DebugDraw sink = debug::create_debug_draw(mem, 1 << 14);
    defer debug::destroy_debug_draw(&sink);
    replay.debug_draw(&sink, { .colliders = true });
    usz without_queries = (usz)sink.vertices.len();
    sink.clear();
    replay.debug_draw(&sink, { .colliders = true, .queries = true });
    assert((usz)sink.vertices.len() > without_queries);
}
