module c3d_particle_shift_test;

import std::math;
import c3d;
import c3d::maths;
import c3d::particle;
import c3d::scene;

const uint  BURST @local = 8;
const float REBASE_OFFSET @local = 4 * 256; // a multiple of the 256 m render cell
const float EMITTER_DISTANCE @local = 3 * REBASE_OFFSET;
const float STEP @local = 0.1f;
const float TOLERANCE @local = 1e-3f;
const uint TRAIL_POINTS @local = 4;
const float TRAIL_LIFETIME @local = 5;
const float TRAIL_SPEED @local = 2;

fn void test_shift_particles_keeps_relative_positions() @test {
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    particle::register_particles(&scene)!!;
    Node* emitter = scene.add_particle_system(particle::default_particle_system_desc())!!;
    emitter.local.position = { EMITTER_DISTANCE, 2, EMITTER_DISTANCE };
    scene.update_world();
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(BURST);
    particle::update(&scene, STEP);
    assert(system.alive == BURST);

    Vec3[BURST] before;
    foreach (index, &position : before) *position = system.position[index];
    Node* draw = scene.node(system.draw_node);
    Vec3 offset = { REBASE_OFFSET, 0, REBASE_OFFSET };

    scene.shift_origin(offset);
    assert(draw.local.position == -offset);
    scene.shift_particles(offset);
    scene.update_world();
    particle::update(&scene, 0);

    assert(system.alive == BURST);
    foreach (index, position : before) {
        assert((system.position[index] - (position - offset)).length() <= TOLERANCE);
    }
    assert(draw.local.position == (Vec3){});
    assert(draw.local.scale == (Vec3){ 1, 1, 1 });
    assert(draw.world_position() == (Vec3){});
}

fn void test_shift_moves_trail_points() @test {
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    particle::register_particles(&scene)!!;
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.speed = { .min = TRAIL_SPEED, .max = TRAIL_SPEED };
    desc.trail = {
        .max_points = TRAIL_POINTS,
        .point_interval = STEP,
        .lifetime = TRAIL_LIFETIME,
        .width = 1,
        .width_over_trail = desc.trail.width_over_trail,
        .color_over_trail = desc.trail.color_over_trail,
    };
    Node* emitter = scene.add_particle_system(desc)!!;
    emitter.local.position = { EMITTER_DISTANCE, 2, EMITTER_DISTANCE };
    scene.update_world();
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(BURST);
    for (uint step = 0; step < TRAIL_POINTS; step++) particle::update(&scene, STEP);

    Node* trail = scene.node(system.trail_node);
    RibbonBatch* batch = scene.get(trail, RibbonBatch);
    assert(batch.count == BURST * (TRAIL_POINTS + 1));
    RibbonPoint[BURST * (TRAIL_POINTS + 1)] before;
    before[..] = batch.points[:batch.count];
    Vec3 offset = { REBASE_OFFSET, 0, REBASE_OFFSET };

    scene.shift_origin(offset);
    assert(trail.local.position == -offset);
    scene.shift_particles(offset);
    scene.update_world();
    particle::update(&scene, 0);

    assert(batch.count == before.len);
    foreach (index, point : before) {
        assert((batch.points[index].position - (point.position - offset)).length() <= TOLERANCE);
    }
    assert(trail.local.position == (Vec3){});
    assert(trail.world_position() == (Vec3){});
}
