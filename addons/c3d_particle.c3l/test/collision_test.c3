module c3d_particle_collision_test;

import c3d;
import c3d::particle;
import c3d::scene;
import std::math;

const float TOLERANCE @local = 1e-4f;
const float STEP @local = 0.1f;
const float PARTICLE_SIZE @local = 0.2f;
const float RADIUS @local = 0.1f; // PARTICLE_SIZE at the radius scale of the test descriptors
const float IMPACT_SPEED @local = 1; // above the speed gravity adds in one STEP

fn Scene make_scene() @local {
    Scene scene = scene::create_scene(mem, { .max_nodes = 32 });
    particle::register_particles(&scene)!!;
    return scene;
}

fn ParticleSystemDesc colliding_desc(CollisionResponse response) @local {
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = 16;
    desc.lifetime = { .min = 5, .max = 5 };
    desc.size = { .min = PARTICLE_SIZE, .max = PARTICLE_SIZE };
    desc.collision = {
        .response = response,
        .restitution = 0.5f,
        .friction = 0.25f,
        .radius_scale = 0.5f,
        .ground_plane = true,
        .max_queries = 4,
        .impact_speed = IMPACT_SPEED,
    };
    return desc;
}

fn void emit_resting(ParticleSystem* system, Mat4 emitter_world, uint count) @local {
    system.emit_burst(count);
    particle::step(
        system: system,
        emitter_world: emitter_world,
        dt: 0,
        wind: {},
    );
    assert(system.alive == count);
}

fn void advance(ParticleSystem* system, Mat4 emitter_world) @local {
    particle::step(
        system: system,
        emitter_world: emitter_world,
        dt: STEP,
        wind: {},
    );
}

fn void test_bounce_keeps_restitution_and_friction_against_a_plane() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    Node* emitter = scene.add_particle_system(colliding_desc(BOUNCE))!!;
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    scene.update_world();
    emit_resting(system, emitter.world, 1);
    system.position[0] = { 0, 1, 0 };
    system.velocity[0] = { 2, -10, 0 };

    advance(system, emitter.world);

    assert(system.alive == 1);
    assert((system.position[0] - (Vec3){ 0.18f, RADIUS, 0 }).length() < TOLERANCE);
    assert((system.velocity[0] - (Vec3){ 1.5f, 5, 0 }).length() < TOLERANCE);
}

fn void test_stick_and_die_responses() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    Node* target = scene.add_particle_system(colliding_desc(NONE))!!;
    ParticleSystemDesc dying_desc = colliding_desc(DIE);
    dying_desc.max_events = 4;
    dying_desc.sub_emitter_count = 1;
    dying_desc.sub_emitters[0] = { .trigger = DEATH, .target = target.id, .count = 1 };
    Node* sticking_node = scene.add_particle_system(colliding_desc(STICK))!!;
    Node* dying_node = scene.add_particle_system(dying_desc)!!;
    ParticleSystem* sticking = scene.get(sticking_node, ParticleSystem);
    ParticleSystem* dying = scene.get(dying_node, ParticleSystem);
    scene.update_world();
    emit_resting(sticking, sticking_node.world, 1);
    emit_resting(dying, dying_node.world, 2);
    sticking.position[0] = { 0, 1, 0 };
    sticking.velocity[0] = { 2, -10, 0 };
    dying.position[0] = { 0, 1, 0 };
    dying.velocity[0] = { 0, -10, 0 };
    dying.position[1] = { 0, 3, 0 };
    dying.velocity[1] = { 0, 0.5f, 0 };

    advance(sticking, sticking_node.world);
    advance(dying, dying_node.world);

    assert(sticking.alive == 1 && sticking.velocity[0] == (Vec3){});
    assert((sticking.position[0] - (Vec3){ 0.18f, RADIUS, 0 }).length() < TOLERANCE);
    assert(dying.alive == 1 && dying.position[0].y > 3);
    assert(dying.event_count == 1);
    assert(dying.events[0].trigger == DEATH && dying.events[0].cause == IMPACT);
}

struct CastLog @local {
    uint[3] queried;
}

fn bool log_cast(void* context, Vec3 from, Vec3 to, float radius, ParticleHit* out) @local {
    CastLog* log = context;
    log.queried[(uint)(from.x / 10 + 0.5f)]++;
    return false;
}

fn void test_collision_budget_rotates_and_counts_skips() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc desc = colliding_desc(BOUNCE);
    desc.collision.ground_plane = false;
    desc.collision.max_queries = 2;
    Node* emitter = scene.add_particle_system(desc)!!;
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    CastLog log;
    system.set_collision(&log_cast, &log);
    scene.update_world();
    emit_resting(system, emitter.world, 3);
    foreach (index, &position : system.position[:3]) *position = { 10 * (float)index, 0, 0 };
    foreach (&velocity : system.velocity[:3]) *velocity = { 0, 1, 0 };

    advance(system, emitter.world);

    assert(log.queried == (uint[3]){ 1, 1, 0 });
    assert(system.collision_skips == 1 && system.query_cursor == 2);

    advance(system, emitter.world);

    assert(log.queried == (uint[3]){ 2, 1, 1 });
    assert(system.collision_skips == 2 && system.query_cursor == 1);
}

fn void test_impact_sub_emitter_fires_at_the_hit_point() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    Node* target_node = scene.add_particle_system(colliding_desc(NONE))!!;
    target_node.local.position = { 7, 7, 7 };
    ParticleSystemDesc desc = colliding_desc(BOUNCE);
    desc.max_events = 4;
    desc.sub_emitter_count = 1;
    desc.sub_emitters[0] = { .trigger = IMPACT, .target = target_node.id, .count = 1 };
    Node* emitter = scene.add_particle_system(desc)!!;
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    ParticleSystem* target = scene.get(target_node, ParticleSystem);
    system.emit_burst(1);
    scene.update_world();
    particle::update(&scene, 0);
    system.position[0] = { 0.5f, 1, -0.5f };
    system.velocity[0] = { 0, -10, 0 };

    particle::update(&scene, STEP);

    assert(system.alive == 1 && target.alive == 1);
    assert((target.position[0] - (Vec3){ 0.5f, 0, -0.5f }).length() < TOLERANCE);
    assert(system.dropped_events == 0 && system.skipped_events == 0);
}

fn void test_stuck_particle_under_gravity_raises_one_impact() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    Node* target_node = scene.add_particle_system(colliding_desc(NONE))!!;
    ParticleSystemDesc desc = colliding_desc(STICK);
    desc.gravity_scale = 1;
    desc.max_events = 8;
    desc.sub_emitter_count = 1;
    desc.sub_emitters[0] = { .trigger = IMPACT, .target = target_node.id, .count = 1 };
    Node* emitter = scene.add_particle_system(desc)!!;
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    scene.update_world();
    emit_resting(system, emitter.world, 1);
    system.position[0] = { 0, 1, 0 };
    system.velocity[0] = { 0, -10, 0 };

    for (uint step = 0; step < 5; step++) advance(system, emitter.world);

    assert(system.alive == 1 && system.next_event == 1 && system.event_count == 1);
    assert(math::abs(system.position[0].y - RADIUS) < TOLERANCE);
}

fn void test_a_response_needs_a_plane_or_queries() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc desc = colliding_desc(BOUNCE);
    desc.collision.ground_plane = false;
    desc.collision.max_queries = 0;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);

    desc.collision.ground_plane = true;
    scene.add_particle_system(desc)!!;
}
