module c3d_particle_test;

import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::particle;
import c3d::scene;
import std::math;

const float TOLERANCE @local = 1e-4f;

fn Scene make_scene(uint nodes = 8, Allocator allocator = mem) @local {
    Scene scene = scene::create_scene(allocator, { .max_nodes = nodes });
    particle::register_particles(&scene)!!;
    return scene;
}

fn ParticleSystemDesc quiet_desc(uint capacity = 16) @local {
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = capacity;
    desc.lifetime = { .min = 5, .max = 5 };
    return desc;
}

fn void test_rate_and_burst_counts_with_fractional_credit() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc desc = quiet_desc(128);
    desc.rate = 100;
    Node* emitter = scene.add_particle_system(desc)!!;
    scene.update_world();
    for (uint frame = 0; frame < 100; frame++) particle::update(&scene, 0.01f);
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    assert(system.alive == 99 || system.alive == 100);
    assert(system.dropped == 0);
    assert(system.emit_accumulator >= 0 && system.emit_accumulator < 1);
    system.emitting = false;
    uint before = system.alive;
    system.emit_burst(7);
    particle::update(&scene, 0);
    assert(system.alive == before + 7);
    particle::update(&scene, 0);
    assert(system.alive == before + 7);
}

fn void test_capacity_overflow_does_not_wrap_or_iterate_dropped_requests() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    Node* emitter = scene.add_particle_system(quiet_desc(8))!!;
    scene.update_world();
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(uint::max);
    system.emit_burst(20);
    particle::update(&scene, 0.01f);
    assert(system.alive == 8);
    assert(system.dropped == (ulong)uint::max + 12);
    assert(system.pending_burst == 0);
    foreach (age : system.age[:system.alive]) assert(math::abs(age - 0.01f) < TOLERANCE);
    ParticleSystemDesc intense = quiet_desc(2);
    intense.rate = float::max;
    Node* fast = scene.add_particle_system(intense)!!;
    scene.update_world();
    particle::update(&scene, 0.1f);
    ParticleSystem* saturated = scene.get(fast, ParticleSystem);
    assert(saturated.alive == 2 && saturated.dropped == ulong::max);
    assert(saturated.emit_accumulator >= 0 && saturated.emit_accumulator < 1);
}

fn void test_expiry_reuses_slots_before_accepting_a_burst() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc desc = quiet_desc(4);
    desc.lifetime = { .min = 0.2f, .max = 0.2f };
    Node* emitter = scene.add_particle_system(desc)!!;
    scene.update_world();
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(4);
    particle::update(&scene, 0.1f);
    system.emit_burst(4);
    particle::update(&scene, 0.1f);
    assert(system.alive == 4 && system.dropped == 0);
    foreach (age : system.age[:system.alive]) assert(math::abs(age - 0.1f) < TOLERANCE);
    particle::update(&scene, 0.1f);
    assert(system.alive == 0);
    assert(scene.get(scene.node(system.draw_node), BillboardBatch).count == 0);
}

fn void test_step_caps_hitches_and_expires_short_lived_newborns() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc long_desc = quiet_desc();
    ParticleSystemDesc short_desc = quiet_desc();
    short_desc.lifetime = { .min = 0.05f, .max = 0.05f };
    Node* long_node = scene.add_particle_system(long_desc)!!;
    Node* short_node = scene.add_particle_system(short_desc)!!;
    ParticleSystem* long_system = scene.get(long_node, ParticleSystem);
    ParticleSystem* short_system = scene.get(short_node, ParticleSystem);
    long_system.emit_burst(1);
    short_system.emit_burst(1);
    scene.update_world();
    particle::update(&scene, 1);
    assert(math::abs(long_system.age[0] - particle::MAX_PARTICLE_STEP_SECONDS) < TOLERANCE);
    assert(short_system.alive == 0 && short_system.dropped == 0);
}

fn void test_gravity_and_drag_follow_the_step_contract() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc gravity_desc = quiet_desc();
    gravity_desc.gravity_scale = 1;
    ParticleSystemDesc drag_desc = quiet_desc();
    drag_desc.drag = 10;
    drag_desc.speed = { .min = 2, .max = 2 };
    Node* falling = scene.add_particle_system(gravity_desc)!!;
    Node* dragged = scene.add_particle_system(drag_desc)!!;
    ParticleSystem* gravity = scene.get(falling, ParticleSystem);
    ParticleSystem* drag = scene.get(dragged, ParticleSystem);
    gravity.emit_burst(1);
    drag.emit_burst(1);
    for (uint frame = 0; frame < 50; frame++) {
        particle::step(
            system: gravity,
            emitter_world: matrix::IDENTITY4,
            dt: 0.02f,
            wind: {},
        );
        particle::step(
            system: drag,
            emitter_world: matrix::IDENTITY4,
            dt: 0.02f,
            wind: { 1, 0, 0 },
        );
    }
    Vec3 expected = particle::PARTICLE_GRAVITY * (0.02f * 0.02f * 50 * 51 / 2);
    assert((gravity.position[0] - expected).length() < TOLERANCE);
    assert((drag.velocity[0] - (Vec3){ 1, 0, 0 }).length() < TOLERANCE);
}

fn void test_seed_replays_every_pool_stream() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc desc = quiet_desc(64);
    desc.seed = 7;
    desc.shape = EmitterShape.SPHERE;
    desc.speed = { .min = 1, .max = 3 };
    desc.rotation = { .min = -1, .max = 1 };
    desc.spin = { .min = -2, .max = 2 };
    Node* first = scene.add_particle_system(desc)!!;
    Node* second = scene.add_particle_system(desc)!!;
    desc.seed = 8;
    Node* third = scene.add_particle_system(desc)!!;
    ParticleSystem* one = scene.get(first, ParticleSystem);
    ParticleSystem* two = scene.get(second, ParticleSystem);
    ParticleSystem* other = scene.get(third, ParticleSystem);
    one.emit_burst(32);
    two.emit_burst(32);
    other.emit_burst(32);
    scene.update_world();
    for (uint frame = 0; frame < 30; frame++) particle::update(&scene, 0.01f, { 1, 0, 0 });
    bool differs;
    assert(one.alive == two.alive && one.alive == other.alive);
    for (uint index = 0; index < one.alive; index++) {
        assert(one.position[index] == two.position[index] && one.velocity[index] == two.velocity[index]);
        assert(one.age[index] == two.age[index] && one.lifetime[index] == two.lifetime[index]);
        assert(one.size[index] == two.size[index] && one.rotation[index] == two.rotation[index]);
        assert(one.spin[index] == two.spin[index] && one.seed[index] == two.seed[index]);
        differs = differs || one.position[index] != other.position[index];
    }
    assert(differs);
}

fn void test_emission_shapes_obey_volume_and_direction_contracts() @test {
    EmitterShape[4] shapes = { POINT, SPHERE, BOX, CONE };
    foreach (shape : shapes) {
        Scene scene = make_scene();
        defer scene::destroy_scene(&scene);
        ParticleSystemDesc desc = quiet_desc(4096);
        desc.shape = shape;
        desc.radius = 2;
        desc.half_extents = { 1, 2, 3 };
        desc.cone_angle = (float)math::PI / 3;
        desc.speed = { .min = 1, .max = 1 };
        Node* emitter = scene.add_particle_system(desc)!!;
        ParticleSystem* system = scene.get(emitter, ParticleSystem);
        system.emit_burst(desc.capacity);
        particle::step(
            system: system,
            emitter_world: matrix::IDENTITY4,
            dt: 0,
            wind: {},
        );
        double radial_mean;
        double cosine_mean;
        for (uint index = 0; index < system.alive; index++) {
            Vec3 position = system.position[index];
            Vec3 velocity = system.velocity[index];
            assert(math::abs(velocity.length() - 1) < TOLERANCE);
            switch (shape) {
                case POINT: assert(position == (Vec3){});
                case SPHERE:
                    float radius = position.length() / desc.radius;
                    assert(radius <= 1 + TOLERANCE);
                    radial_mean += (double)(radius * radius * radius);
                    assert(position.dot(velocity) >= -TOLERANCE);
                case BOX:
                    assert(math::abs(position.x) <= 1 && math::abs(position.y) <= 2 && math::abs(position.z) <= 3);
                case CONE:
                    assert(math::abs(position.y) < TOLERANCE);
                    float radius_squared = (position.x * position.x + position.z * position.z) / 4;
                    assert(radius_squared <= 1 + TOLERANCE && velocity.y >= 0.5f - TOLERANCE);
                    radial_mean += radius_squared;
                    cosine_mean += velocity.y;
            }
        }
        if (shape == SPHERE || shape == CONE) assert(math::abs(radial_mean / system.alive - 0.5) < 0.04);
        if (shape == CONE) assert(math::abs(cosine_mean / system.alive - 0.75) < 0.04);
    }
}

fn void test_lifetime_tables_interpolate_endpoints_and_channels() @test {
    LifetimeTable scalar = { .values = { 0, 1, 0, 1, 0, 1, 0, 1 } };
    LifetimeColorTable colour;
    colour.values[1] = { 1, 0.5f, 0.25f, 1 };
    assert(scalar.sample(0) == 0 && scalar.sample(1) == 1);
    assert(math::abs(scalar.sample(1.0f / 14) - 0.5f) < TOLERANCE);
    Vec4 middle = colour.sample(1.0f / 14);
    assert((middle - (Vec4){ 0.5f, 0.25f, 0.125f, 0.5f }).length() < TOLERANCE);
}

fn void test_bad_desc_and_child_capacity_failure_leave_no_partial_system() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        Scene scene = make_scene(1, &tracker);
        defer scene::destroy_scene(&scene);
        sz before = tracker.allocated();
        ParticleSystemDesc desc = quiet_desc();
        desc.lifetime.min = 0;
        assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);
        desc = quiet_desc();
        assert(@catch(scene.add_particle_system(desc)) == c3d::CAPACITY_EXCEEDED);
        assert(scene.count(ParticleSystem) == 0 && scene.count(BillboardBatch) == 0);
        assert(tracker.allocated() == before);
        Node* survivor = scene.add_node()!!;
        assert(scene.world.is_alive(survivor.id));
    }
    assert(!tracker.has_leaks());
}

fn void test_world_particles_ignore_later_emitter_motion_and_copy_layers() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    Node* emitter = scene.add_particle_system(quiet_desc())!!;
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(1);
    scene.update_world();
    particle::update(&scene, 0);
    emitter.local.position = { 10, 2, -3 };
    emitter.layers = 4;
    emitter.visible = false;
    system.emit_burst(1);
    scene.update_world();
    particle::update(&scene, 0.01f);
    Node* child = scene.node(system.draw_node);
    BillboardBatch* batch = scene.get(child, BillboardBatch);
    assert(system.position[0] == (Vec3){});
    assert(system.position[1] == (Vec3){ 10, 2, -3 });
    assert(batch.billboards[0].position == (Vec3){});
    assert(batch.billboards[1].position == (Vec3){ 10, 2, -3 });
    assert(child.transform_space == TransformSpace.WORLD && child.layers == 4);
    assert(!child.visible_effective && system.age[0] > 0);
}

fn void test_stretch_and_zero_size_mesh_output_follow_simulation() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc stretched = quiet_desc();
    stretched.render_mode = STRETCHED;
    stretched.speed = { .min = 2, .max = 2 };
    stretched.stretch = 0.5f;
    ParticleSystemDesc mesh = quiet_desc();
    mesh.render_mode = MESH;
    mesh.size_over_life.values[..] = 0;
    Node* sparks = scene.add_particle_system(stretched)!!;
    Node* debris = scene.add_particle_system(mesh)!!;
    ParticleSystem* spark_system = scene.get(sparks, ParticleSystem);
    ParticleSystem* mesh_system = scene.get(debris, ParticleSystem);
    spark_system.emit_burst(1);
    mesh_system.emit_burst(1);
    scene.update_world();
    particle::update(&scene, 0);
    BillboardBatch* batch = scene.get(scene.node(spark_system.draw_node), BillboardBatch);
    assert(batch.facing == BillboardFacing.DIRECTIONAL && batch.count == 1);
    assert((batch.billboards[0].size - (Vec2){ 1, 2 }).length() < TOLERANCE);
    assert(batch.billboards[0].direction == spark_system.velocity[0]);
    assert(mesh_system.alive == 1);
    assert(scene.get(scene.node(mesh_system.draw_node), InstancedMesh).count == 0);
}

fn void test_updates_allocate_nothing_and_removal_releases_owned_children() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        Scene scene = make_scene(8, &tracker);
        defer scene::destroy_scene(&scene);
        Node* emitter = scene.add_particle_system(quiet_desc())!!;
        scene.update_world();
        ParticleSystem* system = scene.get(emitter, ParticleSystem);
        Entity child = system.draw_node;
        sz allocations = tracker.total_allocation_count();
        for (uint frame = 0; frame < 100; frame++) {
            system.emit_burst(1);
            particle::update(&scene, 0.01f);
        }
        assert(tracker.total_allocation_count() == allocations);
        scene.remove_component(emitter, ParticleSystem);
        particle::update(&scene, 0);
        assert(!scene.world.is_alive(child));
        Node* second = scene.add_particle_system(quiet_desc())!!;
        Entity second_child = scene.get(second, ParticleSystem).draw_node;
        scene.remove(second);
        assert(!scene.world.is_alive(second_child));
    }
    assert(!tracker.has_leaks());
}

fn void test_desc_validation_rejects_unusable_fields_atomically() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Scene scene = make_scene(8, &tracker);
    defer scene::destroy_scene(&scene);
    sz allocations = tracker.total_allocation_count();
    uint free_nodes = scene.world.entities.free_count;
    for (uint variant = 0; variant < 12; variant++) {
        ParticleSystemDesc desc = quiet_desc();
        switch (variant) {
            case 0: desc.capacity = 0;
            case 1: desc.lifetime = { .min = 2, .max = 1 };
            case 2: desc.rate = -1;
            case 3: desc.size.min = -1;
            case 4: desc.spin.min = bitcast(0x7fc00000u, float);
            case 5: desc.half_extents.z = -1;
            case 6: desc.cone_angle = (float)math::PI + 0.1f;
            case 7: desc.drag = -1;
            case 8: desc.stretch = -1;
            case 9: desc.size_over_life.values[3] = -1;
            case 10: desc.color_min.a = -0.1f;
            case 11: desc.color_over_life.values[4].a = 1.1f;
        }
        assert(@catch(scene.add_particle_system(desc)) == c3d::INVALID_ARGUMENT);
        assert(scene.world.entities.free_count == free_nodes);
        assert(tracker.total_allocation_count() == allocations);
    }
}

fn void test_emitter_scale_changes_volume_without_changing_world_speed() @test {
    Scene scene = make_scene();
    defer scene::destroy_scene(&scene);
    ParticleSystemDesc desc = quiet_desc();
    desc.shape = CONE;
    desc.radius = 0;
    desc.cone_angle = 0;
    desc.speed = { .min = 2, .max = 2 };
    Node* emitter = scene.add_particle_system(desc)!!;
    emitter.local.position = { 3, 4, 5 };
    emitter.local.scale = { 2, 3, 4 };
    emitter.local.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 2);
    scene.update_world();
    ParticleSystem* system = scene.get(emitter, ParticleSystem);
    system.emit_burst(1);
    particle::update(&scene, 0);
    assert(system.position[0] == (Vec3){ 3, 4, 5 });
    assert((system.velocity[0] - (Vec3){ -2, 0, 0 }).length() < TOLERANCE);
    BillboardBatch* batch = scene.get(scene.node(system.draw_node), BillboardBatch);
    assert(batch.billboards[0].size == (Vec2){ 1, 1 });
}
