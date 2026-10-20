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
const float PLANE_HEIGHT @local = 5; // absolute world height
const float VERTICAL_REBASE @local = 3; // shift_origin rejects vertical offsets, so the test writes the result
const float PLANE_PARTICLE_SIZE @local = 0.2f;

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

fn void test_ground_plane_keeps_its_absolute_height_after_a_rebase() @test {
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    particle::register_particles(&scene)!!;
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.lifetime = { .min = 5, .max = 5 };
    desc.size = { .min = PLANE_PARTICLE_SIZE, .max = PLANE_PARTICLE_SIZE };
    desc.collision = {
        .response = BOUNCE,
        .restitution = 0.5f,
        .radius_scale = 0.5f,
        .ground_plane = true,
        .ground_height = PLANE_HEIGHT,
    };
    Node* emitter = scene.add_particle_system(desc)!!;
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(1);
    scene.update_world();
    particle::update(&scene, 0);

    scene.world_shift.y = VERTICAL_REBASE;
    system.position[0] = { 0, PLANE_HEIGHT - VERTICAL_REBASE + 0.5f, 0 };
    system.velocity[0] = { 0, -10, 0 };
    particle::update(&scene, STEP);

    float resting_height = PLANE_HEIGHT - VERTICAL_REBASE + PLANE_PARTICLE_SIZE / 2;
    assert(math::abs(system.position[0].y - resting_height) <= TOLERANCE);
    assert(system.velocity[0].y > 0);
}
