module c3d_particle_turbulence_test;

import c3d;
import c3d::maths;
import c3d::particle;
import c3d::scene;
import std::math;

const uint BURST @local = 24;
const float REBASE_OFFSET @local = 1024; // positions in [1024, 2048) shift by it without float rounding
const float EMITTER_DISTANCE @local = 1.5f * REBASE_OFFSET;
const float STEP @local = 0.05f;
const float FULL_COUPLING_STEP @local = 0.1f; // with the drag below, the blend toward the air is exactly one
const float FULL_COUPLING_DRAG @local = 100;
const float PROBE_SPACING @local = 0.01f; // metres; small against a lattice cell yet large against float rounding
const float DIVERGENCE_TOLERANCE @local = 0.05f; // 1/s; the field's own gradients are of order ten
const float GRADIENT_FLOOR @local = 10 * DIVERGENCE_TOLERANCE; // 1/s; a zero field would pass the divergence check
const float STEERING_FLOOR @local = 0.05f; // metres per second the field adds to a particle in one step
const uint CENTRES @local = 8;
const uint PROBES_PER_CENTRE @local = 7;

fn Scene make_scene() @local {
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    particle::register_particles(&scene)!!;
    return scene;
}

fn ParticleTurbulence field_settings() @local {
    return {
        .strength = 2,
        .frequency = 0.4f, // a 12.5 m tile, which the rebase offset does not divide
        .octaves = 3,
        .period = 5,
        .scroll = { 0.7f, 0.2f, -0.3f },
    };
}

fn ParticleSystem* add_shifted_emitter(Scene* scene) @local {
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = BURST;
    desc.seed = 11;
    desc.shape = SPHERE;
    desc.radius = 3;
    desc.speed = { .min = 0.5f, .max = 1.5f };
    desc.lifetime = { .min = 5, .max = 5 };
    desc.drag = 4;
    desc.turbulence = field_settings();
    Node* emitter = scene.add_particle_system(desc)!!;
    emitter.local.position = { EMITTER_DISTANCE, 2, EMITTER_DISTANCE };
    scene.update_world();
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(BURST);
    particle::update(scene, STEP);
    return system;
}

fn void test_turbulence_is_invariant_under_world_shift() @test {
    Scene unshifted = make_scene();
    Scene shifted = make_scene();
    defer scene::destroy_scene(&unshifted);
    defer scene::destroy_scene(&shifted);
    ParticleSystem* steady = add_shifted_emitter(&unshifted);
    ParticleSystem* moved = add_shifted_emitter(&shifted);
    assert(steady.alive == BURST && moved.alive == BURST);

    Vec3 offset = { REBASE_OFFSET, 0, REBASE_OFFSET };
    shifted.shift_origin(offset);
    shifted.shift_particles(offset);
    shifted.update_world();

    Vec3[BURST] before;
    foreach (index, &velocity : before) *velocity = steady.velocity[index];
    for (uint index = 0; index < BURST; index++) assert(steady.position[index] - moved.position[index] == offset);

    particle::update(&unshifted, STEP);
    particle::update(&shifted, STEP);

    bool steered;
    for (uint index = 0; index < BURST; index++) {
        assert(steady.velocity[index] == moved.velocity[index]);
        steered = steered || (steady.velocity[index] - before[index]).length() > STEERING_FLOOR;
    }
    assert(steered);
}

fn void test_turbulence_field_is_divergence_free() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = CENTRES * PROBES_PER_CENTRE;
    desc.lifetime = { .min = 5, .max = 5 };
    desc.drag = FULL_COUPLING_DRAG;
    desc.turbulence = field_settings();
    desc.turbulence.scroll = {};
    ParticleSystem* system = scene.get(scene.add_particle_system(desc)!!, ParticleSystem);

    Vec3[CENTRES] centres;
    foreach (index, &centre : centres) {
        float spread = (float)index;
        *centre = { 1.3f + spread * 0.771f, 2.9f + spread * 0.313f, 0.4f + spread * 0.529f };
    }
    system.alive = CENTRES * PROBES_PER_CENTRE;
    for (uint slot = 0; slot < system.alive; slot++) {
        Vec3 position = centres[slot / PROBES_PER_CENTRE];
        uint probe = slot % PROBES_PER_CENTRE;
        if (probe > 0) position[(probe - 1) / 2] += probe % 2 ? -PROBE_SPACING : PROBE_SPACING;
        system.position[slot] = position;
        system.velocity[slot] = {};
        system.age[slot] = 0;
        system.lifetime[slot] = desc.lifetime.min;
    }

    particle::step(
        system: system,
        emitter_world: matrix::IDENTITY4,
        dt: FULL_COUPLING_STEP,
        wind: {},
    );

    float steepest;
    for (uint centre = 0; centre < CENTRES; centre++) {
        float divergence;
        for (uint axis = 0; axis < 3; axis++) {
            uint minus = centre * PROBES_PER_CENTRE + 1 + axis * 2;
            float slope = (system.velocity[minus + 1][axis] - system.velocity[minus][axis]) / (2 * PROBE_SPACING);
            divergence += slope;
            steepest = math::max(steepest, math::abs(slope));
        }
        assert(math::abs(divergence) < DIVERGENCE_TOLERANCE);
    }
    assert(steepest > GRADIENT_FLOOR);
}

fn void test_turbulence_rejects_values_the_field_cannot_use() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.turbulence = field_settings();
    ParticleSystemDesc off = desc;
    off.turbulence = {};
    assert(@ok(scene.add_particle_system(off)));
    assert(@ok(scene.add_particle_system(desc)));

    desc.turbulence.octaves = 0;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);
    desc.turbulence.octaves = particle::MAX_TURBULENCE_OCTAVES + 1;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);

    desc.turbulence = field_settings();
    desc.turbulence.period = 0;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);
    desc.turbulence.period = particle::MAX_TURBULENCE_PERIOD + 1;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);

    desc.turbulence = field_settings();
    desc.turbulence.frequency = 0;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);
    desc.turbulence = field_settings();
    desc.turbulence.strength = -1;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);

    desc.turbulence = field_settings();
    desc.turbulence.scroll.y = float::nan;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);
    desc.turbulence = field_settings();
    desc.turbulence.strength = float::inf;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);

    desc.turbulence = {};
    desc.turbulence.frequency = float::nan;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);
}
