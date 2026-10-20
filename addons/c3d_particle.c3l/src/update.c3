module c3d::particle;

import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import std::math;

struct BillboardJob @private {
    ParticleSystem* system;
    BillboardBatch* batch;
}

struct MeshJob @private {
    ParticleSystem* system;
    InstancedMesh* batch;
}

<*
 Advance prepared particles, run their sub-emitters and publish child draws; skip pending systems.
 @param [&inout] scene : "Registered; matrices current; no active component iteration."
 @param dt : "Finite nonnegative seconds."
 @param wind : "Finite world-space air velocity in metres per second."
 @param parallel : "Runs the range kernels; ranges never share writes."
 @require dt >= 0 && math::is_finite(dt)
 @require math::is_finite(wind.x) && math::is_finite(wind.y) && math::is_finite(wind.z)
*>
fn void update(
    Scene* scene,
    float dt,
    Vec3 wind = {},
    ParallelFor parallel = {},
) {
    remove_orphan_draws(scene);
    scene.@each(ParticleSystem; Entity entity, ParticleSystem* system) {
        if (system.is_prepared()) {
            Node* emitter = scene.node(entity);
            Node* child = scene.node(system.draw_node);
            child.layers = emitter.layers;
            if (system.desc.trail.max_points) scene.node(system.trail_node).layers = emitter.layers;
            particle::step(
                system: system,
                emitter_world: emitter.world,
                dt: dt,
                wind: wind,
                world_shift: scene.world_shift,
                parallel: parallel,
            );
        }
    };
    scene.@each(ParticleSystem; Entity entity, ParticleSystem* system) {
        if (system.is_prepared()) process_events(scene, system);
    };
    scene.@each(ParticleSystem; Entity entity, ParticleSystem* system) {
        if (system.is_prepared()) {
            Node* child = scene.node(system.draw_node);
            if (system.desc.render_mode == ParticleRenderMode.MESH) {
                publish_meshes(scene, child, system, parallel);
            } else {
                publish_billboards(scene, child, system, parallel);
            }
            if (system.desc.trail.max_points) publish_trails(scene, scene.node(system.trail_node), system);
        }
    };
}

fn void process_events(Scene* scene, ParticleSystem* source) @private {
    // Events appended while processing, here or by another system, wait for the next update.
    uint due = source.event_due;
    for (uint queued = 0; queued < due; queued++) {
        ParticleEvent* event = &source.events[queued];
        foreach (sub_index, &sub_emitter : source.desc.sub_emitters[:source.desc.sub_emitter_count]) {
            if (!accepts_event(sub_emitter, event)) continue;

            ParticleSystem* target;
            Node* node;
            if (scene.world.is_alive(sub_emitter.target)) {
                node = scene.node(sub_emitter.target);
                target = scene.get(node, ParticleSystem);
            }
            if (!target || !target.is_prepared()) {
                source.skipped_events = saturating_add(source.skipped_events, 1);
                continue;
            }
            emit_at(
                system: target,
                emitter_world: node.world,
                position: event.position,
                inherited_velocity: event.velocity * sub_emitter.inherit_velocity,
                seed: child_seed(event.parent_seed, event.index, (uint)sub_index),
                count: sub_emitter.count,
            );
        }
    }

    uint remaining = source.event_count - due;
    for (uint kept = 0; kept < remaining; kept++) source.events[kept] = source.events[due + kept];
    source.event_count = remaining;
    source.event_due = 0;
}

fn void publish_billboards(
    Scene* scene,
    Node* node,
    ParticleSystem* system,
    ParallelFor parallel,
) @private {
    BillboardBatch* batch = scene.get(node, BillboardBatch);
    BillboardJob job = { .system = system, .batch = batch };
    uint written = assign_draw_slots(system, parallel);
    parallel.for_ranges(
        range: &write_billboard_blocks,
        data: &job,
        count: block_count(system.alive),
        batch: 1,
    );

    bool changed = written || batch.count;
    batch.count = written;
    if (changed) scene.mark_billboards_dirty(node);
}

fn void publish_meshes(
    Scene* scene,
    Node* node,
    ParticleSystem* system,
    ParallelFor parallel,
) @private {
    InstancedMesh* batch = scene.get(node, InstancedMesh);
    MeshJob job = { .system = system, .batch = batch };
    uint written = assign_draw_slots(system, parallel);
    parallel.for_ranges(
        range: &write_mesh_blocks,
        data: &job,
        count: block_count(system.alive),
        batch: 1,
    );

    bool changed = written || batch.count;
    batch.count = written;
    if (changed) scene.mark_instances_dirty(node);
}

fn float draw_extent(ParticleSystem* system, uint index, float life) @private {
    return system.size[index] * system.desc.size_over_life.sample(life);
}

fn uint assign_draw_slots(ParticleSystem* system, ParallelFor parallel) @private {
    uint blocks = block_count(system.alive);
    parallel.for_ranges(
        range: &count_drawn_blocks,
        data: system,
        count: blocks,
        batch: 1,
    );

    uint total;
    foreach (&offset : system.block_offsets[:blocks]) {
        uint drawn = *offset;
        *offset = total;
        total += drawn;
    }
    return total;
}

fn void count_drawn_blocks(void* data, uint first, uint count) @private {
    ParticleSystem* system = data;
    for (uint block = first; block < first + count; block++) {
        ParticleSpan span = particle_span(system.alive, block);
        uint drawn;
        for (uint index = span.begin; index < span.end; index++) {
            float life = system.age[index] / system.lifetime[index];
            if (draw_extent(system, index, life) != 0) drawn++;
        }
        system.block_offsets[block] = drawn;
    }
}

fn void write_billboard_blocks(void* data, uint first, uint count) @private {
    BillboardJob* job = data;
    ParticleSystem* system = job.system;
    BillboardBatch* batch = job.batch;
    ParticleFlipbook* flipbook = &system.desc.flipbook;
    bool stretched = system.desc.render_mode == ParticleRenderMode.STRETCHED;
    for (uint block = first; block < first + count; block++) {
        ParticleSpan span = particle_span(system.alive, block);
        uint written = system.block_offsets[block];
        for (uint index = span.begin; index < span.end; index++) {
            float life = system.age[index] / system.lifetime[index];
            float width = draw_extent(system, index, life);
            if (width == 0) continue;

            float height = width;
            Vec3 direction;
            if (stretched) {
                Vec3 velocity = system.velocity[index];
                float speed = velocity.length();
                height += speed * system.desc.stretch;
                if (speed > 0) direction = velocity / speed;
            }
            float frame;
            if (flipbook.columns) {
                frame = flipbook_frame(
                    flipbook: flipbook,
                    seed: system.seed[index],
                    age: system.age[index],
                    lifetime: system.lifetime[index],
                );
            }
            Vec3 position = system.position[index];
            batch.records[written++] = {
                .position_width = { position.x, position.y, position.z, width },
                .direction_height = { direction.x, direction.y, direction.z, height },
                .color = particle_color(system, index, life),
                .rotation = system.rotation[index],
                .facing = (uint)batch.facing.ordinal,
                .frame = frame,
            };
        }
    }
}

fn void write_mesh_blocks(void* data, uint first, uint count) @private {
    MeshJob* job = data;
    ParticleSystem* system = job.system;
    InstancedMesh* batch = job.batch;
    for (uint block = first; block < first + count; block++) {
        ParticleSpan span = particle_span(system.alive, block);
        uint written = system.block_offsets[block];
        for (uint index = span.begin; index < span.end; index++) {
            float life = system.age[index] / system.lifetime[index];
            float size = draw_extent(system, index, life);
            if (size == 0) continue;

            batch.transforms[written] = {
                .position = system.position[index],
                .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, system.rotation[index]),
                .scale = { size, size, size },
            };
            batch.colors[written++] = particle_color(system, index, life);
        }
    }
}

fn bool draw_has_owner(Scene* scene, Entity child, ParticleDrawOwner* owner) @private {
    if (!scene.world.is_alive(owner.emitter)) return false;
    ParticleSystem* system = scene.get(scene.node(owner.emitter), ParticleSystem);
    return system && (c3d::same_id(system.draw_node, child) || c3d::same_id(system.trail_node, child));
}

fn void remove_orphan_draws(Scene* scene) @private {
    while (true) {
        Entity orphan;
        scene.@each(ParticleDrawOwner; Entity child, ParticleDrawOwner* owner) {
            if (!orphan.generation && !draw_has_owner(scene, child, owner)) orphan = child;
        };
        if (!orphan.generation) return;
        scene.remove(scene.node(orphan));
    }
}
