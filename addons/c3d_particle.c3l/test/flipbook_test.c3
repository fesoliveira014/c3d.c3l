module c3d_particle_flipbook_test;

import c3d;
import c3d::particle;
import c3d::scene;
import std::math;

const float TOLERANCE @local = 1e-3f;
const uint SHEET_FRAMES @local = 16;
const float NEAR_EXPIRY @local = 0.99999f; // share of the lifetime elapsed, just before the particle leaves
const float FRAMES_PER_SECOND @local = 8; // a power of two, so the wrap test ages are exact in a float

fn Scene make_scene() @local {
    Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
    particle::register_particles(&scene)!!;
    return scene;
}

fn ParticleSystemDesc flipbook_desc(FlipbookMode mode, bool blend = true) @local {
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = 32;
    desc.lifetime = { .min = 5, .max = 5 };
    desc.flipbook = {
        .columns = 4,
        .rows = 4,
        .frame_count = SHEET_FRAMES,
        .mode = mode,
        .fps = FRAMES_PER_SECOND,
        .blend = blend,
    };
    return desc;
}

fn float published_frame(Scene* scene, ParticleSystem* system, uint index = 0) @local {
    particle::update(scene, 0);
    return scene.get(scene.node(system.draw_node), BillboardBatch).billboards[index].frame;
}

fn void test_flipbook_over_life_spans_first_to_last_frame() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    Node* blended = scene.add_particle_system(flipbook_desc(OVER_LIFE))!!;
    Node* whole = scene.add_particle_system(flipbook_desc(OVER_LIFE, blend: false))!!;
    ParticleSystem* smooth = scene.get(blended, ParticleSystem);
    ParticleSystem* stepped = scene.get(whole, ParticleSystem);
    smooth.emit_burst(1);
    stepped.emit_burst(1);
    scene.update_world();

    assert(published_frame(&scene, smooth) == 0 && published_frame(&scene, stepped) == 0);

    smooth.age[0] = smooth.lifetime[0] / 2;
    stepped.age[0] = stepped.lifetime[0] / 2;
    assert(math::abs(published_frame(&scene, smooth) - 7.5f) < TOLERANCE);
    assert(published_frame(&scene, stepped) == 8);

    smooth.age[0] = smooth.lifetime[0] * NEAR_EXPIRY;
    stepped.age[0] = stepped.lifetime[0] * NEAR_EXPIRY;
    assert(math::abs(published_frame(&scene, smooth) - (SHEET_FRAMES - 1)) < TOLERANCE);
    assert(published_frame(&scene, stepped) == SHEET_FRAMES - 1);
}

fn void test_flipbook_fps_wraps() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc desc = flipbook_desc(FPS);
    desc.lifetime = { .min = 100, .max = 100 };
    Node* emitter = scene.add_particle_system(desc)!!;
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(1);
    scene.update_world();
    particle::update(&scene, 0);

    system.age[0] = (SHEET_FRAMES + 0.5f) / FRAMES_PER_SECOND;
    assert(published_frame(&scene, system) == 0.5f);

    system.desc.flipbook.blend = false;
    assert(published_frame(&scene, system) == 0);
}

fn void test_flipbook_random_start_is_seeded() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc desc = flipbook_desc(OVER_LIFE);
    desc.seed = 7;
    desc.shape = SPHERE;
    desc.speed = { .min = 1, .max = 3 };
    ParticleSystemDesc plain = desc;
    plain.flipbook = {};
    desc.flipbook.random_start = true;
    ParticleSystem* first = scene.get(scene.add_particle_system(desc)!!, ParticleSystem);
    ParticleSystem* second = scene.get(scene.add_particle_system(desc)!!, ParticleSystem);
    ParticleSystem* unanimated = scene.get(scene.add_particle_system(plain)!!, ParticleSystem);
    first.emit_burst(desc.capacity);
    second.emit_burst(desc.capacity);
    unanimated.emit_burst(desc.capacity);
    scene.update_world();
    particle::update(&scene, 0);

    bool varied;
    BillboardBatch* batch = scene.get(scene.node(first.draw_node), BillboardBatch);
    BillboardBatch* repeat = scene.get(scene.node(second.draw_node), BillboardBatch);
    assert(first.alive == desc.capacity);
    for (uint index = 0; index < first.alive; index++) {
        float frame = batch.billboards[index].frame;
        assert(frame == repeat.billboards[index].frame && frame >= 0 && frame < SHEET_FRAMES);
        varied = varied || frame != batch.billboards[0].frame;
        assert(first.position[index] == unanimated.position[index]);
        assert(first.velocity[index] == unanimated.velocity[index]);
    }
    assert(varied);
}

fn void test_flipbook_rejects_mesh_mode_and_a_stalled_rate() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc mesh = flipbook_desc(OVER_LIFE);
    mesh.render_mode = MESH;
    assert(@catch(scene.add_particle_system(mesh)) == c3d::INVALID_ARGUMENT);

    ParticleSystemDesc stalled = flipbook_desc(FPS);
    stalled.flipbook.fps = 0;
    assert(@catch(scene.add_particle_system(stalled)) == c3d::INVALID_ARGUMENT);
}
