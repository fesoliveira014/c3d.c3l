#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "particle/particle_step.glsl"

layout(local_size_x = 256) in; // mirrored as GROUP_SIZE in gpu/system.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) buffer ParticleRecords {
    BillboardGpu values[];
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer RibbonRecords {
    RibbonPointGpu values[];
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer ParticleCountWord {
    uint value;
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer ParticleCounters {
    uvec4 value; // alive, dropped low and high words, unused
};

// Mirrors flipbook_frame in flipbook.c3, in float.
float flipbook_frame(StepRoot root, ParticleGpu particle) {
    float frames = float(root.flipbook_frames);
    bool blended = (root.flipbook_flags & PARTICLE_FLIPBOOK_BLEND) != 0u;
    float position = 0.0;
    if ((root.flipbook_flags & PARTICLE_FLIPBOOK_RANDOM_START) != 0u) {
        uint sample_hash = particle_pcg_hash(particle_pcg_hash(particle.seed));
        float fraction = float(sample_hash >> 8u) * PARTICLE_UNIT_SCALE;
        position = float(min(uint(fraction * frames), root.flipbook_frames - 1u));
    }
    if ((root.flipbook_flags & PARTICLE_FLIPBOOK_FPS) != 0u) {
        float elapsed = particle.age * root.flipbook_fps;
        position += blended ? elapsed : floor(elapsed);
    } else {
        float life = clamp(particle.age / particle.lifetime, 0.0, 1.0);
        position += blended ? life * (frames - 1.0) : min(floor(life * frames), frames - 1.0);
    }
    float wrapped = position - floor(position / frames) * frames;
    return clamp(wrapped, 0.0, frames);
}

// Mirrors particle_color in step.c3.
vec4 particle_color(StepRoot root, ParticleGpu particle) {
    float life = particle.age / particle.lifetime;
    float fraction = float(particle_pcg_hash(particle.seed) >> 8u) * PARTICLE_UNIT_SCALE;
    return (root.color_min * (1.0 - fraction) + root.color_max * fraction) * particle_color_scale(root, life);
}

// Mirrors write_billboard_blocks, relative to the frame origin.
BillboardGpu particle_record(StepRoot root, ParticleGpu particle) {
    float width = particle_draw_extent(root, particle);
    float height = width;
    vec3 direction = vec3(0.0);
    if (root.stretched != 0u) {
        float speed = length(particle.velocity);
        height += speed * root.shift_stretch.w;
        if (speed > 0.0) direction = particle.velocity / speed;
    }
    float frame = root.flipbook_columns != 0u ? flipbook_frame(root, particle) : 0.0;
    return BillboardGpu(
        vec4(particle.position - root.origin_restitution.xyz, width),
        vec4(direction, height),
        particle_color(root, particle),
        particle.rotation,
        root.facing,
        frame,
        0u
    );
}

// Mirrors LifetimeTable.sample in lifetime.c3 over the trail width table.
float trail_width_scale(StepRoot root, float life) {
    float position = life * float(PARTICLE_TABLE_ENTRIES - 1u);
    uint first = min(uint(position), PARTICLE_TABLE_ENTRIES - 2u);
    float fraction = position - float(first);
    return root.width_over_trail[first] * (1.0 - fraction) + root.width_over_trail[first + 1u] * fraction;
}

// Mirrors LifetimeColorTable.sample in lifetime.c3 over the trail colour table.
vec4 trail_color_scale(StepRoot root, float life) {
    float position = life * float(PARTICLE_TABLE_ENTRIES - 1u);
    uint first = min(uint(position), PARTICLE_TABLE_ENTRIES - 2u);
    float fraction = position - float(first);
    return root.color_over_trail[first] * (1.0 - fraction) + root.color_over_trail[first + 1u] * fraction;
}

// Starts a new strip without drawing: the unused points of a particle and the record that ends the batch.
RibbonPointGpu trail_break() {
    return RibbonPointGpu(vec4(0.0), vec4(0.0), 0.0, RIBBON_POINT_BREAK, 0u, 0u);
}

// Mirrors trail_point in trail.c3, relative to the frame origin.
RibbonPointGpu trail_record(StepRoot root, vec4 color, vec3 position, float point_age, float v, uint flags) {
    float life = clamp(point_age / root.trail_lifetime, 0.0, 1.0);
    return RibbonPointGpu(
        vec4(position - root.origin_restitution.xyz, root.trail_width * trail_width_scale(root, life)),
        color * trail_color_scale(root, life),
        v,
        flags,
        0u,
        0u
    );
}

// Mirrors publish_trails in trail.c3 for one particle: its head, its stored points newest first, and a break for each
// unused point. The count word then holds max_points + 1 records per live particle.
void write_trail(StepRoot root, ParticleGpu particle, uint index, uint rank) {
    uint size = root.trail_max_points;
    uint base = index * size;
    TrailHeaderGpu header = TrailHeaders(root.trail_headers_alt).values[index];
    TrailPoints points = TrailPoints(root.trail_points_alt);
    TrailDistances distances = TrailDistances(root.trail_distances_alt);
    RibbonRecords records = RibbonRecords(root.ribbon_records);
    bool tiled = root.trail_tiled != 0u;
    vec4 color = particle_color(root, particle);

    float head_distance = 0.0;
    if (header.count != 0u) {
        uint newest = base + particle_trail_slot(header, size, 0u);
        head_distance = distances.values[newest] + length(particle.position - points.values[newest].xyz);
    }
    uint first = rank * (size + 1u);
    records.values[first] = trail_record(
        root,
        color,
        particle.position,
        0.0,
        tiled ? -head_distance / root.trail_tile_length : 0.0,
        RIBBON_POINT_BREAK
    );
    for (uint stored = 0u; stored < size; stored++) {
        if (stored >= header.count) {
            records.values[first + 1u + stored] = trail_break();
            continue;
        }

        uint slot = base + particle_trail_slot(header, size, stored);
        vec4 point = points.values[slot];
        float point_age = particle.age - point.w;
        records.values[first + 1u + stored] = trail_record(
            root,
            color,
            point.xyz,
            point_age,
            tiled ? -distances.values[slot] / root.trail_tile_length : point_age / root.trail_lifetime,
            0u
        );
    }
}

// Packs the live particles and their trails back to the home buffer, writes the drawn particles as records and the
// trails as strips, and publishes the counts.
void main() {
    StepRoot root = StepRoot(DispatchRoot(pc.root_gpu).parameters);
    ParticleControl control = ParticleControl(root.control);
    uint index = gl_GlobalInvocationID.x;
    if (index < control.pool_count) {
        ParticleGpu particle = ParticleStates(root.state_alt).values[index];
        uvec4 flags = ParticleScan(root.scan).values[index];
        uvec2 base = ParticleTotals(root.totals).values[index / PARTICLE_GROUP];
        if (flags.x != 0u) {
            uint rank = flags.z + base.x;
            ParticleStates(root.state_home).values[rank] = particle;
            if (root.trail_max_points != 0u) {
                particle_copy_trail(root, false, index, rank);
                write_trail(root, particle, index, rank);
            }
        }
        if (flags.y != 0u) ParticleRecords(root.records).values[flags.w + base.y] = particle_record(root, particle);
    }
    if (index == 0u) {
        control.alive = control.live_total;
        ParticleCountWord(root.count).value = control.drawn_total;
        ParticleCounters(root.counters).value = uvec4(control.live_total, control.dropped_low, control.dropped_high, 0u);
        if (root.trail_max_points != 0u) {
            uint points = control.live_total * (root.trail_max_points + 1u);
            ParticleCountWord(root.ribbon_count).value = points;
            RibbonRecords(root.ribbon_records).values[points] = trail_break();
        }
    }
}
