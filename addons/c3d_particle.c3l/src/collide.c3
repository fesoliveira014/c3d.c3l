module c3d::particle;

import c3d::maths;
import std::math;

const Vec3 GROUND_NORMAL @private = { 0, 1, 0 };

fn void collide(ParticleSystem* system, float seconds, double world_shift_y) @private {
    ParticleCollision* collision = &system.desc.collision;
    bool queries_enabled = system.collision_cast && collision.max_queries > 0;
    if (collision.response == CollisionResponse.NONE || !system.alive) return;
    if (!collision.ground_plane && !queries_enabled) return;

    float plane_height = (float)((double)collision.ground_height - world_shift_y);
    bool dies = collision.response == CollisionResponse.DIE;
    uint count = system.alive;
    uint start = system.query_cursor % count;
    uint queries;
    bool exhausted;
    bool retired;
    for (uint visit = 0; visit < count; visit++) {
        uint index = (start + visit) % count;
        Vec3 to = system.position[index];
        // The pool keeps no previous position; the last move was exactly velocity * seconds.
        Vec3 from = to - system.velocity[index] * seconds;
        if (from == to) continue;

        float life = system.age[index] / system.lifetime[index];
        float radius = system.size[index] * system.desc.size_over_life.sample(life) * collision.radius_scale;
        ParticleHit hit;
        bool found = collision.ground_plane && hit_ground_plane(
            from: from,
            to: to,
            radius: radius,
            plane_height: plane_height,
            hit: &hit,
        );
        if (queries_enabled) {
            if (queries < collision.max_queries) {
                queries++;
                ParticleHit cast_hit;
                bool cast_found = system.collision_cast(
                    context: system.collision_context,
                    from: from,
                    to: to,
                    radius: radius,
                    out: &cast_hit,
                );
                if (cast_found && (!found || cast_hit.fraction < hit.fraction)) {
                    hit = cast_hit;
                    found = true;
                }
            } else {
                if (!exhausted) system.query_cursor = index;
                exhausted = true;
                system.collision_skips = saturating_add(system.collision_skips, 1);
            }
        }

        if (found) {
            respond_to_hit(
                system: system,
                index: index,
                hit: hit,
                radius: radius,
            );
            retired = retired || dies;
        }
    }
    if (retired) remove_retired(system);
}

fn bool hit_ground_plane(
    Vec3 from,
    Vec3 to,
    float radius,
    float plane_height,
    ParticleHit* hit,
) @private {
    float clearance_from = from.y - plane_height - radius;
    float clearance_to = to.y - plane_height - radius;
    if (clearance_to >= 0 || to.y >= from.y) return false;

    // A path that starts at or below the plane hits at once, so rounding cannot let a resting particle through.
    float fraction = clearance_from > 0 ? clearance_from / (clearance_from - clearance_to) : 0;
    Vec3 centre = from + (to - from) * fraction;
    *hit = { .point = { centre.x, plane_height, centre.z }, .normal = GROUND_NORMAL, .fraction = fraction };
    return true;
}

fn void respond_to_hit(
    ParticleSystem* system,
    uint index,
    ParticleHit hit,
    float radius,
) @private {
    ParticleCollision* collision = &system.desc.collision;
    Vec3 velocity = system.velocity[index];
    system.position[index] = hit.point;
    raise_event(system, index, { .trigger = ParticleTrigger.IMPACT });

    Vec3 resting = hit.point + hit.normal * radius;
    switch (collision.response) {
        case NONE:
            return;
        case BOUNCE:
            float approach = velocity.dot(hit.normal);
            if (approach < 0) {
                Vec3 into = hit.normal * approach;
                system.velocity[index] = (velocity - into) * (1 - collision.friction) - into * collision.restitution;
            }
            system.position[index] = resting;
        case STICK:
            system.velocity[index] = {};
            system.position[index] = resting;
        case DIE:
            raise_event(system, index, { .trigger = ParticleTrigger.DEATH, .cause = ParticleEventCause.IMPACT });
            system.age[index] = system.lifetime[index];
    }
}

fn void remove_retired(ParticleSystem* system) @private {
    uint index;
    while (index < system.alive) {
        if (system.age[index] >= system.lifetime[index]) {
            remove_particle(system, index);
        } else {
            index++;
        }
    }
}
