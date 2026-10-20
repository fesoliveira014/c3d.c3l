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
