module c3d::particle;

import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import std::math;

<*
 Advance prepared particles and publish child draws; skip pending systems.
 @param [&inout] scene : "Registered; matrices current; no active component iteration."
 @param dt : "Finite nonnegative seconds."
 @param wind : "Finite world-space air velocity in metres per second."
 @require dt >= 0 && math::is_finite(dt)
 @require math::is_finite(wind.x) && math::is_finite(wind.y) && math::is_finite(wind.z)
*>
fn void update(Scene* scene, float dt, Vec3 wind = {}) {
    remove_orphan_draws(scene);
    scene.@each(ParticleSystem; Entity entity, ParticleSystem* system) {
        if (system.is_prepared()) {
            Node* emitter = scene.node(entity);
            Node* child = scene.node(system.draw_node);
            child.layers = emitter.layers;
            particle::step(
                system: system,
                emitter_world: emitter.world,
                dt: dt,
                wind: wind,
            );
            if (system.desc.render_mode == ParticleRenderMode.MESH) {
                publish_meshes(scene, child, system);
            } else {
                publish_billboards(scene, child, system);
            }
        }
    };
}

fn void publish_billboards(Scene* scene, Node* node, ParticleSystem* system) @private {
    BillboardBatch* batch = scene.get(node, BillboardBatch);
    uint written;
    for (uint index = 0; index < system.alive; index++) {
        float life = system.age[index] / system.lifetime[index];
        float width = system.size[index] * system.desc.size_over_life.sample(life);
        if (width == 0) continue;
        float height = width;
        Vec3 direction;
        if (system.desc.render_mode == ParticleRenderMode.STRETCHED) {
            direction = system.velocity[index];
            height += direction.length() * system.desc.stretch;
        }
        batch.billboards[written++] = {
            .position = system.position[index],
            .size = { width, height },
            .direction = direction,
            .rotation = system.rotation[index],
            .color = particle_color(system, index, life),
        };
    }
    bool changed = written || batch.count;
    batch.count = written;
    if (changed) scene.mark_billboards_dirty(node);
}

fn void publish_meshes(Scene* scene, Node* node, ParticleSystem* system) @private {
    InstancedMesh* batch = scene.get(node, InstancedMesh);
    uint written;
    for (uint index = 0; index < system.alive; index++) {
        float life = system.age[index] / system.lifetime[index];
        float size = system.size[index] * system.desc.size_over_life.sample(life);
        if (size == 0) continue;
        batch.transforms[written] = {
            .position = system.position[index],
            .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, system.rotation[index]),
            .scale = { size, size, size },
        };
        batch.colors[written++] = particle_color(system, index, life);
    }
    bool changed = written || batch.count;
    batch.count = written;
    if (changed) scene.mark_instances_dirty(node);
}

fn bool draw_has_owner(Scene* scene, Entity child, ParticleDrawOwner* owner) @private {
    if (!scene.world.is_alive(owner.emitter)) return false;
    ParticleSystem* system = scene.get(scene.node(owner.emitter), ParticleSystem);
    return system && c3d::same_id(system.draw_node, child);
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
