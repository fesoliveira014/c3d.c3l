module c3d_particle_trail_test;

import c3d;
import c3d::particle;
import c3d::scene;
import std::math;

const float STEP @local = 0.1f; // equals the point interval, so every update records one point
const float TOLERANCE @local = 1e-4f;
const uint RING_POINTS @local = 4;
const uint WIDE_RING_POINTS @local = 8;
const float SHORT_LIFETIME @local = 0.35f; // between the ages of the fourth and fifth newest points after ten updates
const float TRAIL_LIFETIME @local = 0.5f;
const float TRAIL_WIDTH @local = 2;
const float TILE_LENGTH @local = 0.5f;
const float SLOW_INTERVAL @local = 0.2f; // two updates per point
const float SHORT_PARTICLE_LIFETIME @local = 0.25f;

fn Scene make_scene() @local {
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    particle::register_particles(&scene)!!;
    return scene;
}

fn ParticleSystemDesc trail_desc(uint max_points, float trail_lifetime = 100) @local {
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = 8;
    desc.shape = CONE;
    desc.radius = 0;
    desc.cone_angle = 0;
    desc.lifetime = { .min = 5, .max = 5 };
    desc.speed = { .min = 1, .max = 1 };
    desc.trail.max_points = max_points;
    desc.trail.point_interval = STEP;
    desc.trail.lifetime = trail_lifetime;
    desc.trail.width = 1;
    return desc;
}

fn RibbonBatch* trail_batch(Scene* scene, ParticleSystem* system) @local {
    return scene.get(scene.node(system.trail_node), RibbonBatch);
}

fn void advance(Scene* scene, uint steps) @local {
    for (uint step = 0; step < steps; step++) particle::update(scene, STEP);
}

fn void assert_heights(RibbonBatch* batch, float[] heights) @local {
    assert(batch.count == heights.len);
    foreach (index, height : heights) assert(math::abs(batch.points[index].position.y - height) < TOLERANCE);
}

fn void assert_trails_match_particles(Scene* scene, ParticleSystem* system) @local {
    RibbonBatch* batch = trail_batch(scene, system);
    uint cursor;
    for (uint index = 0; index < system.alive; index++) {
        float speed = system.velocity[index].y;
        uint steps = (uint)math::round(system.age[index] / STEP);
        assert(batch.points[cursor].flags == scene::RIBBON_BREAK);
        assert(math::abs(batch.points[cursor].position.y - system.position[index].y) < TOLERANCE);
        cursor++;
        for (uint rank = 0; rank < math::min(steps, WIDE_RING_POINTS); rank++) {
            float expected = speed * STEP * (float)(steps - rank);
            assert(math::abs(batch.points[cursor].position.y - expected) < TOLERANCE);
            cursor++;
        }
    }
    assert(cursor == batch.count);
}

fn void test_trail_ring_keeps_the_newest_points() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    Node* emitter = scene.add_particle_system(trail_desc(RING_POINTS))!!;
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(1);
    scene.update_world();
    advance(&scene, 10);

    RibbonBatch* batch = trail_batch(&scene, system);
    assert(batch.points[0].flags == scene::RIBBON_BREAK);
    assert_heights(batch, { 1.0f, 1.0f, 0.9f, 0.8f, 0.7f });
}

fn void test_trail_points_expire_by_lifetime() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    Node* emitter = scene.add_particle_system(trail_desc(WIDE_RING_POINTS, SHORT_LIFETIME))!!;
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(1);
    scene.update_world();
    advance(&scene, 10);

    assert_heights(trail_batch(&scene, system), { 1.0f, 1.0f, 0.9f, 0.8f, 0.7f });
}

fn void test_trail_is_removed_with_its_particle() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    Node* emitter = scene.add_particle_system(trail_desc(WIDE_RING_POINTS))!!;
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(2);
    scene.update_world();
    particle::update(&scene, 0);
    system.velocity[0] = { 0, 1, 0 };
    system.velocity[1] = { 0, 2, 0 };
    system.lifetime[0] = SHORT_PARTICLE_LIFETIME;
    advance(&scene, 3);

    assert(system.alive == 1);
    assert_heights(trail_batch(&scene, system), { 0.6f, 0.6f, 0.4f, 0.2f });

    system.lifetime[0] = STEP;
    advance(&scene, 1);
    assert(system.alive == 0 && trail_batch(&scene, system).count == 0);
}

fn void test_trails_stay_with_their_particles_through_removal_and_eviction() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc desc = trail_desc(WIDE_RING_POINTS);
    desc.capacity = 4;
    desc.saturation = DROP_OLDEST;
    Node* emitter = scene.add_particle_system(desc)!!;
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(4);
    scene.update_world();
    particle::update(&scene, 0);
    foreach (index, &velocity : system.velocity[:system.alive]) *velocity = { 0, (float)index + 1, 0 };
    system.lifetime[0] = SHORT_PARTICLE_LIFETIME;
    advance(&scene, 3);

    assert(system.alive == 3 && system.evicted == 0);
    assert_trails_match_particles(&scene, system);

    system.emit_burst(2);
    advance(&scene, 1);
    assert(system.alive == 4 && system.evicted == 1);
    assert_trails_match_particles(&scene, system);
}

fn void test_stretched_trail_maps_point_age_to_width_colour_and_coordinate() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc desc = trail_desc(WIDE_RING_POINTS, TRAIL_LIFETIME);
    desc.trail.width = TRAIL_WIDTH;
    foreach (index, &width : desc.trail.width_over_trail.values) *width = 1 - (float)index / 7;
    foreach (index, &color : desc.trail.color_over_trail.values) *color = { 1, 1, 1, 1 - (float)index / 7 };
    Node* emitter = scene.add_particle_system(desc)!!;
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(1);
    scene.update_world();
    advance(&scene, 3);

    RibbonBatch* batch = trail_batch(&scene, system);
    float[4] fractions = { 0, 0, 0.2f, 0.4f };
    assert(batch.count == fractions.len);
    foreach (index, fraction : fractions) {
        RibbonPoint point = batch.points[index];
        assert(math::abs(point.width - TRAIL_WIDTH * (1 - fraction)) < TOLERANCE);
        assert(math::abs(point.color.a - (1 - fraction)) < TOLERANCE);
        assert(math::abs(point.v - fraction) < TOLERANCE);
    }
}

fn void test_tiled_trail_keeps_its_coordinates_fixed_along_the_path() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc desc = trail_desc(WIDE_RING_POINTS);
    desc.trail.point_interval = SLOW_INTERVAL;
    desc.trail.uv = TILE;
    desc.trail.tile_length = TILE_LENGTH;
    Node* emitter = scene.add_particle_system(desc)!!;
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(1);
    scene.update_world();
    advance(&scene, 3);

    RibbonBatch* batch = trail_batch(&scene, system);
    assert(batch.count == 2);
    assert(math::abs(batch.points[0].v - -0.2f) < TOLERANCE);
    assert(math::abs(batch.points[1].v) < TOLERANCE);

    advance(&scene, 1);
    assert(batch.count == 3);
    assert(math::abs(batch.points[0].v - -0.4f) < TOLERANCE);
    assert(math::abs(batch.points[1].v - -0.4f) < TOLERANCE);
    assert(math::abs(batch.points[2].v) < TOLERANCE);
}

fn void test_trail_rejects_values_the_trail_cannot_use() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc desc = trail_desc(RING_POINTS);
    ParticleSystemDesc off = desc;
    off.trail = {};
    off.trail.point_interval = 0;
    assert(@ok(scene.add_particle_system(off)));
    assert(@ok(scene.add_particle_system(desc)));

    desc.trail.max_points = 1;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);
    desc.trail.max_points = particle::MAX_TRAIL_POINTS + 1;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);

    desc = trail_desc(RING_POINTS);
    desc.trail.point_interval = 0;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);
    desc = trail_desc(RING_POINTS);
    desc.trail.lifetime = -1;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);

    desc = trail_desc(RING_POINTS);
    desc.trail.uv = TILE;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);
    desc.trail.tile_length = TILE_LENGTH;
    assert(@ok(scene.add_particle_system(desc)));

    desc = trail_desc(RING_POINTS);
    desc.trail.width = -1;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);
    desc.trail.width = float::nan;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);

    desc = trail_desc(RING_POINTS);
    desc.trail.width_over_trail.values[3] = float::inf;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);
    desc = trail_desc(RING_POINTS);
    desc.trail.color_over_trail.values[2].r = -1;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);

    desc = trail_desc(RING_POINTS);
    desc.capacity = int::max;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);

    desc.trail = {};
    desc.trail.lifetime = float::nan;
    assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);
}
