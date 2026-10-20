module c3d::particle;

import c3d;
import c3d::scene;
import std::math;

struct TrailJob @private {
    ParticleSystem* system;
    float seconds;
}

fn void reset_trail(ParticleSystem* system, uint index) @private {
    if (!system.desc.trail.max_points) return;

    system.trail_head[index] = 0;
    system.trail_count[index] = 0;
    system.trail_clock[index] = 0;
    system.path_length[index] = 0;
}

fn void copy_trail(ParticleSystem* system, uint to, uint from) @private {
    uint size = system.desc.trail.max_points;
    if (!size || to == from) return;

    usz target = (usz)to * size;
    usz source = (usz)from * size;
    system.trail_position[target:size] = system.trail_position[source:size];
    system.trail_stamp[target:size] = system.trail_stamp[source:size];
    system.trail_distance[target:size] = system.trail_distance[source:size];
    system.trail_head[to] = system.trail_head[from];
    system.trail_count[to] = system.trail_count[from];
    system.trail_clock[to] = system.trail_clock[from];
    system.path_length[to] = system.path_length[from];
}

fn void swap_trails(ParticleSystem* system, uint first, uint second) @private {
    uint size = system.desc.trail.max_points;
    if (!size) return;

    usz left = (usz)first * size;
    usz right = (usz)second * size;
    for (usz slot = 0; slot < size; slot++) {
        @swap(system.trail_position[left + slot], system.trail_position[right + slot]);
        @swap(system.trail_stamp[left + slot], system.trail_stamp[right + slot]);
        @swap(system.trail_distance[left + slot], system.trail_distance[right + slot]);
    }
    @swap(system.trail_head[first], system.trail_head[second]);
    @swap(system.trail_count[first], system.trail_count[second]);
    @swap(system.trail_clock[first], system.trail_clock[second]);
    @swap(system.path_length[first], system.path_length[second]);
}

fn usz trail_slot(ParticleSystem* system, uint index, uint newest_rank) @private {
    uint size = system.desc.trail.max_points;
    uint slot = (system.trail_head[index] + size - 1 - newest_rank) % size;
    return (usz)index * size + slot;
}

fn void append_trail_point(ParticleSystem* system, uint index) @private {
    uint size = system.desc.trail.max_points;
    uint count = system.trail_count[index];
    Vec3 position = system.position[index];
    float distance = system.path_length[index];
    if (count) distance += (position - system.trail_position[trail_slot(system, index, 0)]).length();

    uint head = system.trail_head[index];
    usz slot = (usz)index * size + head;
    system.trail_position[slot] = position;
    system.trail_stamp[slot] = system.age[index];
    system.trail_distance[slot] = distance;
    system.path_length[index] = distance;
    system.trail_head[index] = (head + 1) % size;
    system.trail_count[index] = math::min(count + 1, size);
}

fn void drop_expired_trail_points(ParticleSystem* system, uint index) @private {
    uint count = system.trail_count[index];
    float lifetime = system.desc.trail.lifetime;
    while (count) {
        usz oldest = trail_slot(system, index, count - 1);
        if (system.age[index] - system.trail_stamp[oldest] <= lifetime) break;
        count--;
    }
    system.trail_count[index] = count;
}

fn void record_trails(ParticleSystem* system, float seconds, ParallelFor parallel) @private {
    if (!system.desc.trail.max_points) return;

    TrailJob job = { .system = system, .seconds = seconds };
    run_blocks(
        parallel: parallel,
        range: &record_trail_blocks,
        data: &job,
        blocks: block_count(system.alive),
    );
}

fn void record_trail_blocks(void* data, uint first, uint count) @private {
    TrailJob* job = data;
    ParticleSystem* system = job.system;
    ParticleTrail* trail = &system.desc.trail;
    for (uint block = first; block < first + count; block++) {
        ParticleSpan span = particle_span(system.alive, block);
        for (uint index = span.begin; index < span.end; index++) {
            float clock = system.trail_clock[index] + job.seconds;
            if (clock >= trail.point_interval) {
                append_trail_point(system, index);
                clock -= trail.point_interval;
                if (clock >= trail.point_interval) clock = 0;
            }
            system.trail_clock[index] = clock;
            drop_expired_trail_points(system, index);
        }
    }
}

fn void shift_trail_points(ParticleSystem* system, Vec3 offset) @private {
    for (uint index = 0; index < system.alive; index++) {
        for (uint rank = 0; rank < system.trail_count[index]; rank++) {
            system.trail_position[trail_slot(system, index, rank)] -= offset;
        }
    }
}

fn RibbonPoint trail_point(
    ParticleSystem* system,
    Vec4 color,
    Vec3 position,
    float point_age,
    float v,
    uint flags,
) @private {
    ParticleTrail* trail = &system.desc.trail;
    float fraction = point_age / trail.lifetime;
    return {
        .position = position,
        .width = trail.width * trail.width_over_trail.sample(fraction),
        .color = color * trail.color_over_trail.sample(fraction),
        .v = v,
        .flags = flags,
    };
}

fn void publish_trails(Scene* scene, Node* node, ParticleSystem* system) @private {
    RibbonBatch* batch = scene.get(node, RibbonBatch);
    ParticleTrail* trail = &system.desc.trail;
    bool tiled = trail.uv == TrailUv.TILE;
    uint written;
    for (uint index = 0; index < system.alive; index++) {
        uint count = system.trail_count[index];
        if (!count) continue;

        Vec4 color = particle_color(system, index, system.age[index] / system.lifetime[index]);
        usz newest = trail_slot(system, index, 0);
        Vec3 head = system.position[index];
        float head_distance = system.trail_distance[newest] + (head - system.trail_position[newest]).length();
        batch.points[written++] = trail_point(
            system: system,
            color: color,
            position: head,
            point_age: 0,
            v: tiled ? -head_distance / trail.tile_length : 0,
            flags: scene::RIBBON_BREAK,
        );
        for (uint rank = 0; rank < count; rank++) {
            usz slot = trail_slot(system, index, rank);
            float point_age = system.age[index] - system.trail_stamp[slot];
            batch.points[written++] = trail_point(
                system: system,
                color: color,
                position: system.trail_position[slot],
                point_age: point_age,
                v: tiled ? -system.trail_distance[slot] / trail.tile_length : point_age / trail.lifetime,
                flags: 0,
            );
        }
    }
    bool changed = written || batch.count;
    batch.count = written;
    if (changed) scene.mark_ribbons_dirty(node);
}
