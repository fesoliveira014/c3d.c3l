module c3d::particle;

import c3d;
import std::math;

const Vec3 GROUND_NORMAL @private = { 0, 1, 0 };

struct GroundJob @private {
    ParticleSystem* system;
    float seconds;
}

fn void collide(ParticleSystem* system, float seconds, ParallelFor parallel) @private {
    ParticleCollision* collision = &system.desc.collision;
    bool queries_enabled = system.collision_cast && collision.max_queries > 0;
    if (collision.response == CollisionResponse.NONE || !system.alive) return;
    if (!collision.ground_plane && !queries_enabled) return;

    // Events are raised in visit order, so only a system that raises none can visit blocks in any order.
    if (!system.collision_cast && !system.desc.sub_emitter_count) {
        collide_ground_plane(system, seconds, parallel);
        return;
    }

    bool dies = collision.response == CollisionResponse.DIE;
    uint count = system.alive;
    uint start = system.query_cursor % count;
    uint queries;
    bool exhausted;
    bool retired;
    for (uint visit = 0; visit < count; visit++) {
        uint index = (start + visit) % count;
        Vec3 to = system.position[index];
        Vec3 from = previous_position(system, index, seconds);
        if (from == to) continue;

        float radius = collision_radius(system, index);
        ParticleHit hit;
        bool found = collision.ground_plane && hit_ground_plane(
            from: from,
            to: to,
            radius: radius,
            plane_height: collision.ground_height,
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

fn void collide_ground_plane(ParticleSystem* system, float seconds, ParallelFor parallel) @private {
    GroundJob job = { .system = system, .seconds = seconds };
    uint blocks = block_count(system.alive);
    parallel.for_ranges(
        range: &collide_ground_blocks,
        data: &job,
        count: blocks,
        batch: 1,
    );

    uint retired;
    foreach (block_retired : system.block_offsets[:blocks]) retired += block_retired;
    if (retired) remove_retired(system);
}

fn void collide_ground_blocks(void* data, uint first, uint count) @private {
    GroundJob* job = data;
    ParticleSystem* system = job.system;
    ParticleCollision* collision = &system.desc.collision;
    bool dies = collision.response == CollisionResponse.DIE;
    for (uint block = first; block < first + count; block++) {
        ParticleSpan span = particle_span(system.alive, block);
        uint retired;
        for (uint index = span.begin; index < span.end; index++) {
            Vec3 to = system.position[index];
            Vec3 from = previous_position(system, index, job.seconds);
            if (from == to) continue;

            float radius = collision_radius(system, index);
            ParticleHit hit;
            bool found = hit_ground_plane(
                from: from,
                to: to,
                radius: radius,
                plane_height: collision.ground_height,
                hit: &hit,
            );
            if (found) {
                respond_to_hit(
                    system: system,
                    index: index,
                    hit: hit,
                    radius: radius,
                );
                if (dies) retired++;
            }
        }
        system.block_offsets[block] = retired;
    }
}

// The pool keeps no previous position; the last move was exactly velocity * seconds.
fn Vec3 previous_position(ParticleSystem* system, uint index, float seconds) @private {
    return system.position[index] - system.velocity[index] * seconds;
}

fn float collision_radius(ParticleSystem* system, uint index) @private {
    float life = system.age[index] / system.lifetime[index];
    return system.size[index] * system.desc.size_over_life.sample(life) * system.desc.collision.radius_scale;
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
    float approach_speed = math::max(0.0f, -velocity.dot(hit.normal));
    system.position[index] = hit.point;
    if (approach_speed >= collision.impact_speed) raise_event(system, index, { .trigger = ParticleTrigger.IMPACT });

    Vec3 resting = hit.point + hit.normal * radius;
    switch (collision.response) {
        case NONE:
            return;
        case BOUNCE:
            if (approach_speed > 0) {
                Vec3 into = hit.normal * -approach_speed;
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
