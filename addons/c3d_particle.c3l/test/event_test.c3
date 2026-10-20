module c3d_particle_event_test;

import c3d;
import c3d::particle;
import c3d::scene;
import std::math;

const float TOLERANCE @local = 1e-4f;
const float STEP @local = 0.1f;
const float SHORT_LIFETIME @local = 0.05f; // shorter than STEP, so newborns expire in their first step

fn Scene make_scene() @local {
    Scene scene = scene::create_scene(mem, { .max_nodes = 32 });
    particle::register_particles(&scene)!!;
    return scene;
}

fn ParticleSystemDesc quiet_desc(uint capacity = 16) @local {
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = capacity;
    desc.lifetime = { .min = 5, .max = 5 };
    return desc;
}

fn ParticleSystemDesc listening_desc(SubEmitter sub_emitter, uint max_events = 8) @local {
    ParticleSystemDesc desc = quiet_desc();
    desc.max_events = max_events;
    desc.sub_emitter_count = 1;
    desc.sub_emitters[0] = sub_emitter;
    return desc;
}

fn void test_child_seeds_are_deterministic() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc child_desc = quiet_desc(64);
    child_desc.shape = EmitterShape.SPHERE;
    child_desc.radius = 0.5f;
    child_desc.speed = { .min = 1, .max = 2 };
    child_desc.rotation = { .min = -1, .max = 1 };
    uint[3] parent_seeds = { 5, 5, 6 };
    ParticleSystem*[3] parents;
    ParticleSystem*[3] children;
    foreach (index, parent_seed : parent_seeds) {
        Node* child = scene.add_particle_system(child_desc)!!;
        ParticleSystemDesc desc = listening_desc({
            .trigger = DEATH,
            .target = child.id,
            .count = 2,
            .inherit_velocity = 0.5f,
        });
        desc.seed = parent_seed;
        desc.shape = EmitterShape.SPHERE;
        desc.lifetime = { .min = SHORT_LIFETIME, .max = SHORT_LIFETIME };
        desc.speed = { .min = 1, .max = 3 };
        parents[index] = scene.get(scene.add_particle_system(desc)!!, ParticleSystem);
        children[index] = scene.get(child, ParticleSystem);
        parents[index].emit_burst(8);
    }
    scene.update_world();
    particle::update(&scene, STEP);

    assert(parents[0].dropped_events == 0 && parents[0].alive == 0);
    assert(children[0].alive == 16 && children[1].alive == 16 && children[2].alive == 16);
    bool differs;
    for (uint index = 0; index < children[0].alive; index++) {
        assert(children[0].position[index] == children[1].position[index]);
        assert(children[0].velocity[index] == children[1].velocity[index]);
        assert(children[0].seed[index] == children[1].seed[index]);
        assert(children[0].rotation[index] == children[1].rotation[index]);
        differs = differs || children[0].seed[index] != children[2].seed[index];
    }
    assert(differs);
}

fn void test_death_sub_emitter_spawns_at_the_event_position_with_inherited_velocity() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    Node* child_node = scene.add_particle_system(quiet_desc())!!;
    child_node.local.position = { 7, 7, 7 };
    ParticleSystemDesc desc = listening_desc({
        .trigger = DEATH,
        .target = child_node.id,
        .count = 1,
        .inherit_velocity = 0.5f,
    });
    desc.speed = { .min = 2, .max = 2 };
    desc.lifetime = { .min = 0.15f, .max = 0.15f };
    ParticleSystem* parent = scene.get(scene.add_particle_system(desc)!!, ParticleSystem);
    ParticleSystem* child = scene.get(child_node, ParticleSystem);
    parent.emit_burst(1);
    scene.update_world();
    particle::update(&scene, STEP);
    assert(parent.alive == 1 && child.alive == 0);

    Vec3 death_position = parent.position[0];
    Vec3 death_velocity = parent.velocity[0];
    particle::update(&scene, STEP);

    assert(parent.alive == 0 && child.alive == 1);
    assert((child.position[0] - death_position).length() < TOLERANCE);
    assert((child.velocity[0] - death_velocity * 0.5f).length() < TOLERANCE);
    assert(child.age[0] == 0);
}

fn void test_full_event_queue_counts_dropped_events() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    Node* child_node = scene.add_particle_system(quiet_desc())!!;
    ParticleSystemDesc desc = listening_desc({ .trigger = DEATH, .target = child_node.id, .count = 1 }, 2);
    desc.lifetime = { .min = SHORT_LIFETIME, .max = SHORT_LIFETIME };
    ParticleSystem* parent = scene.get(scene.add_particle_system(desc)!!, ParticleSystem);
    ParticleSystem* child = scene.get(child_node, ParticleSystem);
    parent.emit_burst(5);
    scene.update_world();
    particle::update(&scene, STEP);

    assert(parent.dropped_events == 3 && parent.event_count == 0);
    assert(child.alive == 2 && parent.skipped_events == 0);
}

fn void test_events_no_sub_emitter_accepts_are_not_queued() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    Node* child_node = scene.add_particle_system(quiet_desc())!!;
    ParticleSystemDesc desc = listening_desc({ .trigger = IMPACT, .target = child_node.id, .count = 1 }, 1);
    desc.lifetime = { .min = SHORT_LIFETIME, .max = SHORT_LIFETIME };
    ParticleSystem* parent = scene.get(scene.add_particle_system(desc)!!, ParticleSystem);
    parent.emit_burst(5);
    scene.update_world();
    particle::update(&scene, STEP);

    assert(parent.dropped_events == 0 && parent.next_event == 0);
}

fn void test_events_from_event_spawns_wait_a_frame() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    Node* first_node = scene.add_node()!!;
    Node* second_node = scene.add_node()!!;
    ParticleSystemDesc first_desc = listening_desc({ .trigger = BIRTH, .target = second_node.id, .count = 1 });
    ParticleSystemDesc second_desc = listening_desc({ .trigger = BIRTH, .target = first_node.id, .count = 1 });
    scene.attach_particle_system(first_node, first_desc)!!;
    scene.attach_particle_system(second_node, second_desc)!!;
    particle::prepare_subtree(&scene)!!;
    ParticleSystem* first = scene.get(first_node, ParticleSystem);
    ParticleSystem* second = scene.get(second_node, ParticleSystem);
    scene.update_world();

    first.emit_burst(1);
    uint[4] first_alive = { 1, 2, 2, 3 };
    uint[4] second_alive = { 1, 1, 2, 2 };
    for (usz frame = 0; frame < first_alive.len; frame++) {
        particle::update(&scene, 0);
        assert(first.alive == first_alive[frame] && second.alive == second_alive[frame]);
    }
    assert(first.dropped_events == 0 && second.dropped_events == 0);
}

fn void test_evicted_particles_fire_death_only_with_on_evict() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    bool[2] on_evict = { true, false };
    ParticleSystem*[2] parents;
    ParticleSystem*[2] children;
    foreach (index, evicts : on_evict) {
        Node* child = scene.add_particle_system(quiet_desc())!!;
        ParticleSystemDesc desc = listening_desc({
            .trigger = DEATH,
            .target = child.id,
            .count = 1,
            .on_evict = evicts,
        });
        desc.capacity = 4;
        desc.saturation = DROP_OLDEST;
        parents[index] = scene.get(scene.add_particle_system(desc)!!, ParticleSystem);
        children[index] = scene.get(child, ParticleSystem);
    }
    scene.update_world();
    foreach (parent : parents) parent.emit_burst(4);
    particle::update(&scene, STEP);
    foreach (parent : parents) parent.emit_burst(3);
    particle::update(&scene, STEP);

    assert(parents[0].evicted == 3 && parents[1].evicted == 3);
    assert(children[0].alive == 3 && children[1].alive == 0);
    assert(parents[0].dropped_events == 0 && parents[1].dropped_events == 0);
}

fn void test_shift_moves_queued_events() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    Node* child_node = scene.add_particle_system(quiet_desc())!!;
    ParticleSystemDesc desc = listening_desc({ .trigger = DEATH, .target = child_node.id, .count = 1 });
    desc.lifetime = { .min = SHORT_LIFETIME, .max = SHORT_LIFETIME };
    desc.speed = { .min = 1, .max = 1 };
    Node* emitter = scene.add_particle_system(desc)!!;
    emitter.local.position = { 20, 3, 8 };
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(1);
    scene.update_world();
    particle::step(
        system: system,
        emitter_world: emitter.world,
        dt: STEP,
        wind: {},
    );
    assert(system.event_count == 1);
    Vec3 queued = system.events[0].position;
    Vec3 offset = { 16, 0, -4 };

    scene.shift_particles(offset);

    assert((system.events[0].position - (queued - offset)).length() < TOLERANCE);
}

fn void test_unavailable_targets_count_skipped_events() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    Node* plain = scene.add_node()!!;
    Node* removed = scene.add_particle_system(quiet_desc())!!;
    Entity removed_id = removed.id;
    scene.remove(removed);
    Node* pending = scene.add_node()!!;
    scene.attach_particle_system(pending, quiet_desc())!!;
    ParticleSystemDesc desc = quiet_desc();
    desc.lifetime = { .min = SHORT_LIFETIME, .max = SHORT_LIFETIME };
    desc.max_events = 4;
    desc.sub_emitter_count = 3;
    desc.sub_emitters[0] = { .trigger = DEATH, .target = plain.id, .count = 1 };
    desc.sub_emitters[1] = { .trigger = DEATH, .target = removed_id, .count = 1 };
    desc.sub_emitters[2] = { .trigger = DEATH, .target = pending.id, .count = 1 };
    ParticleSystem* parent = scene.get(scene.add_particle_system(desc)!!, ParticleSystem);
    parent.emit_burst(1);
    scene.update_world();
    particle::update(&scene, STEP);

    assert(parent.skipped_events == 3 && parent.dropped_events == 0);
    assert(!scene.get(pending, ParticleSystem).is_prepared());
}

fn void test_sub_emitter_validation_rejects_unusable_fields() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    Node* target = scene.add_node()!!;
    SubEmitter sub_emitter = { .trigger = DEATH, .target = target.id, .inherit_velocity = 0.5f };
    for (uint variant = 0; variant < 3; variant++) {
        ParticleSystemDesc desc = listening_desc(sub_emitter);
        switch (variant) {
            case 0: desc.sub_emitter_count = particle::MAX_SUB_EMITTERS + 1;
            case 1: desc.sub_emitters[0].inherit_velocity = 1.5f;
            case 2: desc.max_events = 0;
        }
        assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);
    }
    scene.add_particle_system(listening_desc(sub_emitter))!!;
}
