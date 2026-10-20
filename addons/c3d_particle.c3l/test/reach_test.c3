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
const float WIDE_TRAIL @local = 100; // far beyond the half-extent a particle adds to its bound

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

fn void test_trail_bound_holds_the_strip_edges() @test {
    Scene scene = reach_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = 4;
    desc.shape = EmitterShape.POINT;
    desc.lifetime = { .min = 4, .max = 4 };
    desc.speed = { .min = 0, .max = 0 };
    desc.size = { .min = 0.1f, .max = 0.1f };
    desc.trail.max_points = 2;
    desc.trail.point_interval = REACH_STEP_SECONDS;
    desc.trail.lifetime = 1;
    desc.trail.width = WIDE_TRAIL;
    Node* emitter = scene.add_particle_system(desc)!!;
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(1);
    scene.update_world();
    ParticleReach reach;
    for (uint step = 0; step < 10; step++) {
        reach.record(
            desc: &desc,
            emitter_world: emitter.world,
            wind: {},
            seconds: REACH_STEP_SECONDS,
        );
        particle::update(&scene, REACH_STEP_SECONDS);
    }

    Aabb bound = reach.trail_bound(&desc);
    RibbonBatch* batch = scene.get(scene.node(system.trail_node), RibbonBatch);
    assert(batch.count > 0 && batch.points[0].width == WIDE_TRAIL);
    foreach (point : batch.points[:batch.count]) {
        Vec3 half = { 0.5f * point.width, 0.5f * point.width, 0.5f * point.width };
        assert(bound_contains(bound, point.position - half) && bound_contains(bound, point.position + half));
    }
}

fn void test_mesh_bound_holds_the_corners_of_every_instance() @test {
    Scene scene = reach_scene();
    defer scene::destroy_scene(&scene);
    Aabb geometry_bounds = { .min = { -1, -0.5f, -2 }, .max = { 1, 0.5f, 2 } };
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = 64;
    desc.render_mode = ParticleRenderMode.MESH;
    desc.shape = EmitterShape.POINT;
    desc.lifetime = { .min = 4, .max = 4 };
    desc.speed = { .min = 0, .max = 0 };
    desc.size = { .min = 0.5f, .max = 0.5f };
    desc.rotation = { .min = -(float)math::PI, .max = (float)math::PI };
    Node* emitter = scene.add_particle_system(desc)!!;
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(desc.capacity);
    scene.update_world();
    ParticleReach reach;
    reach.record(
        desc: &desc,
        emitter_world: emitter.world,
        wind: {},
        seconds: REACH_STEP_SECONDS,
    );
    particle::update(&scene, REACH_STEP_SECONDS);

    float radius = geometry_bounds.max.length(); // the bounds are symmetric about the origin
    Aabb bound = reach.bound(&desc, radius);
    InstancedMesh* batch = scene.get(scene.node(system.draw_node), InstancedMesh);
    assert(batch.count == desc.capacity);
    foreach (transform : batch.transforms[:batch.count]) {
        Aabb placed = maths::aabb_transform(geometry_bounds, transform.to_mat4());
        assert(bound_contains(bound, placed.min) && bound_contains(bound, placed.max));
    }
}
