module c3d_particle_test;

import c3d;
import c3d::maths;
import c3d::particle;
import c3d::scene;
import std::math;

const uint REACH_STEPS @local = 480;
const float REACH_STEP_SECONDS @local = 1.0f / 60;
const float EMITTER_SPEED @local = 5;
const Vec3 REACH_WIND @local = { 3, 0, 0 };

fn Scene reach_scene() @local {
    Scene scene = scene::create_scene(mem, { .max_nodes = 8 });
    particle::register_particles(&scene)!!;
    return scene;
}

fn bool bound_contains(Aabb bound, Vec3 point) @local {
    return point.x >= bound.min.x && point.y >= bound.min.y && point.z >= bound.min.z
        && point.x <= bound.max.x && point.y <= bound.max.y && point.z <= bound.max.z;
}

fn void test_reach_bounds_contain_every_particle() @test {
    Scene scene = reach_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = 2000;
    desc.shape = EmitterShape.CONE;
    desc.radius = 0.5f;
    desc.rate = 300;
    desc.lifetime = { .min = 8, .max = 8 };
    desc.speed = { .min = 1, .max = 4 };
    desc.size = { .min = 0.1f, .max = 0.3f };
    desc.gravity_scale = 1;
    desc.drag = 0.5f;
    desc.turbulence = { .strength = 2, .frequency = 1, .octaves = 1, .period = 16 };
    Node* emitter = scene.add_particle_system(desc)!!;
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    ParticleReach reach;
    uint checked;
    for (uint step = 0; step < REACH_STEPS; step++) {
        emitter.local.position.x = EMITTER_SPEED * REACH_STEP_SECONDS * (float)step;
        scene.update_world();
        reach.record(
            desc: &desc,
            emitter_world: emitter.world,
            wind: REACH_WIND,
            seconds: REACH_STEP_SECONDS,
        );
        particle::update(&scene, REACH_STEP_SECONDS, REACH_WIND);
        Aabb bound = reach.bound(&desc);
        foreach (position : system.position[:system.alive]) {
            assert(bound_contains(bound, position));
            checked++;
        }
    }
    assert(checked > 0);
}
