module c3d_particle_parallel_test;

import c3d;
import c3d::maths;
import c3d::particle;
import c3d::scene;
import std::math;

const uint STEPS @local = 60;
const float STEP_SECONDS @local = 1.0f / 60;
const Vec3 WIND @local = { 1, 0, 0 };
const uint STRETCHED_CAPACITY @local = 5000;
const uint MESH_CAPACITY @local = 2000;
const uint MULTIPLE_BLOCKS @local = 2048; // more live particles than two kernel blocks

struct Reversal @local {
    uint calls;
    uint widest;
}

fn void run_last_to_first(
    void* context,
    ParallelRangeFn range,
    void* data,
    uint count,
    uint batch,
) @local {
    Reversal* reversal = context;
    reversal.calls++;
    reversal.widest = math::max(reversal.widest, (count + batch - 1) / batch);
    for (uint ranges = (count + batch - 1) / batch; ranges > 0; ranges--) {
        uint first = (ranges - 1) * batch;
        range(data, first, math::min(batch, count - first));
    }
}

fn ParticleSystemDesc stretched_desc() @local {
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = STRETCHED_CAPACITY;
    desc.seed = 11;
    desc.render_mode = STRETCHED;
    desc.shape = CONE;
    desc.radius = 0.5f;
    desc.cone_angle = 0.6f;
    desc.rate = 6000;
    desc.lifetime = { .min = 0.4f, .max = 1.2f };
    desc.speed = { .min = 1, .max = 3 };
    desc.size = { .min = 0.1f, .max = 0.3f };
    desc.rotation = { .min = -1, .max = 1 };
    desc.spin = { .min = -2, .max = 2 };
    desc.gravity_scale = 1;
    desc.drag = 0.5f;
    desc.stretch = 0.2f;
    desc.size_over_life.values = { 0, 0, 1, 1, 1, 1, 0.5f, 0.5f };
    desc.flipbook = {
        .columns = 4,
        .rows = 4,
        .frame_count = 16,
        .mode = FlipbookMode.FPS,
        .fps = 12,
        .random_start = true,
        .blend = true,
    };
    desc.turbulence = { .strength = 2, .frequency = 1.5f, .octaves = 2, .period = 16, .scroll = { 0, 0.4f, 0 } };
    desc.collision.response = CollisionResponse.BOUNCE;
    desc.collision.ground_plane = true;
    desc.collision.friction = 0.2f;
    desc.trail.max_points = 8;
    desc.trail.point_interval = 0.02f;
    desc.trail.lifetime = 0.2f;
    desc.trail.width = 0.05f;
    return desc;
}

fn ParticleSystemDesc mesh_desc() @local {
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = MESH_CAPACITY;
    desc.seed = 23;
    desc.render_mode = MESH;
    desc.shape = SPHERE;
    desc.radius = 0.4f;
    desc.rate = 3000;
    desc.lifetime = { .min = 0.5f, .max = 1.5f };
    desc.speed = { .min = 0.5f, .max = 2 };
    desc.size = { .min = 0.05f, .max = 0.2f };
    desc.spin = { .min = -3, .max = 3 };
    desc.gravity_scale = 1;
    desc.collision.response = CollisionResponse.DIE;
    desc.collision.ground_plane = true;
    return desc;
}

fn Scene make_scene() @local {
    Scene scene = scene::create_scene(mem, { .max_nodes = 8 });
    particle::register_particles(&scene)!!;
    Node* sparks = scene.add_particle_system(stretched_desc())!!;
    Node* debris = scene.add_particle_system(mesh_desc())!!;
    sparks.local.position = { 0, 1, 0 };
    debris.local.position = { 0.5f, 1.5f, 0 };
    scene.update_world();
    return scene;
}

macro bool same_prefix(first, second, usz count) @local {
    return mem::equals(first.ptr, second.ptr, (sz)(count * @sizeof(first[0])));
}

fn bool same_trails(ParticleSystem* first, ParticleSystem* second) @local {
    usz alive = first.alive;
    usz trail_points = alive * first.desc.trail.max_points;
    return same_prefix(first.trail_position, second.trail_position, trail_points)
        && same_prefix(first.trail_stamp, second.trail_stamp, trail_points)
        && same_prefix(first.trail_distance, second.trail_distance, trail_points)
        && same_prefix(first.trail_clock, second.trail_clock, alive)
        && same_prefix(first.path_length, second.path_length, alive)
        && same_prefix(first.trail_head, second.trail_head, alive)
        && same_prefix(first.trail_count, second.trail_count, alive);
}

fn bool same_system(ParticleSystem* first, ParticleSystem* second) @local {
    usz alive = first.alive;
    return first.alive == second.alive
        && first.dropped == second.dropped
        && first.evicted == second.evicted
        && first.next_spawn == second.next_spawn
        && first.next_event == second.next_event
        && first.emit_accumulator == second.emit_accumulator
        && first.turbulence_time == second.turbulence_time
        && first.collision_skips == second.collision_skips
        && same_prefix(first.position, second.position, alive)
        && same_prefix(first.velocity, second.velocity, alive)
        && same_prefix(first.age, second.age, alive)
        && same_prefix(first.lifetime, second.lifetime, alive)
        && same_prefix(first.size, second.size, alive)
        && same_prefix(first.rotation, second.rotation, alive)
        && same_prefix(first.spin, second.spin, alive)
        && same_prefix(first.seed, second.seed, alive)
        && same_prefix(first.spawn, second.spawn, alive)
        && (!first.desc.trail.max_points || same_trails(first, second));
}

fn void test_parallel_update_matches_serial_byte_for_byte() @test {
    Scene reversed = make_scene();
    defer scene::destroy_scene(&reversed);
    Scene serial = make_scene();
    defer scene::destroy_scene(&serial);
    Reversal reversal;
    ParallelFor parallel = { .run = &run_last_to_first, .context = &reversal };

    for (uint step = 0; step < STEPS; step++) {
        particle::update(
            scene: &reversed,
            dt: STEP_SECONDS,
            wind: WIND,
            parallel: parallel,
        );
        particle::update(&serial, STEP_SECONDS, WIND);
    }

    assert(reversal.calls > 0 && reversal.widest > 1);
    ParticleSystem* sparks_reversed;
    ParticleSystem* sparks_serial;
    ParticleSystem* debris_reversed;
    ParticleSystem* debris_serial;
    reversed.@each(ParticleSystem; entity, system) {
        if (system.desc.render_mode == ParticleRenderMode.MESH) {
            debris_reversed = system;
        } else {
            sparks_reversed = system;
        }
    };
    serial.@each(ParticleSystem; entity, system) {
        if (system.desc.render_mode == ParticleRenderMode.MESH) {
            debris_serial = system;
        } else {
            sparks_serial = system;
        }
    };
    assert(sparks_serial.alive > MULTIPLE_BLOCKS && debris_serial.alive > 0);
    assert(same_system(sparks_reversed, sparks_serial) && same_system(debris_reversed, debris_serial));

    BillboardBatch* records_reversed = reversed.get(reversed.node(sparks_reversed.draw_node), BillboardBatch);
    BillboardBatch* records_serial = serial.get(serial.node(sparks_serial.draw_node), BillboardBatch);
    assert(records_serial.count > 0 && records_serial.count < sparks_serial.alive);
    assert(records_reversed.count == records_serial.count);
    assert(same_prefix(records_reversed.records, records_serial.records, records_serial.count));
    uint drawn;
    foreach (index, size : sparks_serial.size[:sparks_serial.alive]) {
        float life = sparks_serial.age[index] / sparks_serial.lifetime[index];
        float extent = size * sparks_serial.desc.size_over_life.sample(life);
        if (extent == 0) continue;

        Vec3 position = sparks_serial.position[index];
        assert(records_serial.records[drawn++].position_width == (Vec4){ position.x, position.y, position.z, extent });
    }
    assert(drawn == records_serial.count);

    RibbonBatch* points_reversed = reversed.get(reversed.node(sparks_reversed.trail_node), RibbonBatch);
    RibbonBatch* points_serial = serial.get(serial.node(sparks_serial.trail_node), RibbonBatch);
    assert(points_serial.count > 0 && points_reversed.count == points_serial.count);
    assert(same_prefix(points_reversed.points, points_serial.points, points_serial.count));

    InstancedMesh* meshes_reversed = reversed.get(reversed.node(debris_reversed.draw_node), InstancedMesh);
    InstancedMesh* meshes_serial = serial.get(serial.node(debris_serial.draw_node), InstancedMesh);
    assert(meshes_serial.count > 0 && meshes_reversed.count == meshes_serial.count);
    assert(same_prefix(meshes_reversed.transforms, meshes_serial.transforms, meshes_serial.count));
    assert(same_prefix(meshes_reversed.colors, meshes_serial.colors, meshes_serial.count));
}
