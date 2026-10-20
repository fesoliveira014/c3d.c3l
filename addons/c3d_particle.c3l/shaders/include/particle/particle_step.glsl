#ifndef PARTICLE_STEP_GLSL
#define PARTICLE_STEP_GLSL

#include "particle/particle_random.glsl"

const uint PARTICLE_GROUP = 256u; // mirrored as GROUP_SIZE in gpu/system.c3
const uint PARTICLE_TABLE_ENTRIES = 8u; // mirrored as LIFETIME_TABLE_ENTRIES in particle.c3
const uint PARTICLE_SHAPE_POINT = 0u; // mirrored by EmitterShape in particle.c3
const uint PARTICLE_SHAPE_SPHERE = 1u;
const uint PARTICLE_SHAPE_BOX = 2u;
const uint PARTICLE_SHAPE_CONE = 3u;
const uint PARTICLE_RESPONSE_BOUNCE = 1u; // mirrored by CollisionResponse in particle.c3
const uint PARTICLE_RESPONSE_STICK = 2u;
const uint PARTICLE_RESPONSE_DIE = 3u;
const uint PARTICLE_TRIGGER_DEATH = 0u; // mirrored by ParticleTrigger in particle.c3
const uint PARTICLE_TRIGGER_IMPACT = 1u;
const uint PARTICLE_TRIGGER_BIRTH = 2u;
const uint PARTICLE_EVENT_BYTES = 48u; // mirrored as EVENT_BYTES in gpu/system.c3
const uint PARTICLE_SCAN_BLOCKS = 0u; // mirrored by ScanMode in gpu/system.c3
const uint PARTICLE_SCAN_TOTALS = 1u;
const uint PARTICLE_FLIPBOOK_FPS = 1u; // bits of StepRoot.flipbook_flags; mirrored in gpu/system.c3
const uint PARTICLE_FLIPBOOK_RANDOM_START = 2u;
const uint PARTICLE_FLIPBOOK_BLEND = 4u;
const float PARTICLE_FULL_TURN = 6.2831855; // mirrored as FULL_TURN in step.c3

// One live particle; mirrored as PARTICLE_STATE_BYTES in gpu/system.c3.
struct ParticleGpu {
    vec3 position;
    float age;
    vec3 velocity;
    float lifetime;
    float size;
    float rotation;
    float spin;
    uint seed;
    uvec2 spawn; // low word, then high word of the spawn ordinal
    uint fresh; // nonzero from delivery until the next step raises the child's BIRTH event
    uint _pad0;
};

// Mirrors StepRoot in gpu/system.c3.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer StepRoot {
    uint64_t control;
    uint64_t state_home;
    uint64_t state_alt;
    uint64_t scan;
    uint64_t totals;
    uint64_t records;
    uint64_t count;
    uint64_t counters;
    uint capacity;
    uint requested;
    uint reset;
    uint mode;
    float seconds;
    float drag;
    uint seed;
    uint shape;
    vec4 acceleration_radius; // xyz: gravity step; w: sphere or cone radius
    vec4 wind_cone; // xyz: wind; w: cone angle
    vec4 shift_stretch; // xyz: queued origin shift; w: stretch
    vec4 origin_restitution; // xyz: frame origin; w: restitution
    vec4 half_extents_friction; // xyz: box half extents; w: friction
    vec4 emitter_row0;
    vec4 emitter_row1;
    vec4 emitter_row2;
    vec4 lifetime_speed; // lifetime min, max; speed min, max
    vec4 size_rotation; // size min, max; rotation min, max
    vec4 spin_ground; // spin min, max; ground height; collision radius scale
    vec4 turbulence_offset; // xyz: tile offset; w: tile length
    uint response;
    uint collides;
    uint octaves;
    uint period;
    float turbulence_strength;
    float turbulence_frequency;
    uint stretched;
    uint facing;
    uint flipbook_columns;
    uint flipbook_frames;
    uint flipbook_flags;
    uint _pad0;
    float flipbook_fps;
    uint _pad1;
    uint _pad2;
    uint _pad3;
    vec4 color_min;
    vec4 color_max;
    float size_over_life[8];
    vec4 color_over_life[8];
    uint64_t trail_headers_home; // the addresses are unused while trail_max_points is zero
    uint64_t trail_headers_alt;
    uint64_t trail_points_home;
    uint64_t trail_points_alt;
    uint64_t trail_distances_home;
    uint64_t trail_distances_alt;
    uint64_t ribbon_records;
    uint64_t ribbon_count;
    uint trail_max_points; // stored points per particle; zero disables the trail
    float trail_interval;
    float trail_lifetime;
    float trail_width;
    float trail_tile_length;
    uint trail_tiled;
    uint _pad4;
    uint _pad5;
    float width_over_trail[8];
    vec4 color_over_trail[8];
    uint64_t events; // both halves; unused while event_capacity is zero
    uint64_t source_control; // the system that delivers: its control block and event halves
    uint64_t source_events;
    uint event_capacity; // events one step of this system can keep
    uint source_event_capacity;
    uvec4 event_accept; // by trigger: the sub-emitters that react, one bit each
    uint delivery_sub; // the sub-emitter that delivers
    uint delivery_count;
    float delivery_inherit; // share of the event velocity added to each child
    float impact_speed;
    uint delivery_valid; // zero when the target cannot take children, so the events are only counted
    uint mesh; // nonzero when the records are InstanceGpu
    uint64_t mirror; // host mirror of a traced mesh system; zero without one
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer ParticleControl {
    uint alive; // particles in the home buffer
    uint pool_count; // survivors and admitted particles in the alternate buffer
    uint live_total; // scan total of the live flags
    uint drawn_total; // scan total of the drawn flags
    uint dropped_low;
    uint dropped_high;
    uint spawn_low; // next spawn ordinal
    uint spawn_high;
    uint step; // steps taken; the step in flight appends events to half step & 1
    uint delivered; // children delivered since the last step, after the alive particles of the home buffer
    uint event_counts[2]; // events appended to each half; they pass event_capacity until the step publishes
    uint dropped_events_low;
    uint dropped_events_high;
    uint skipped_events_low;
    uint skipped_events_high;
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer ParticleStates {
    ParticleGpu values[];
};

// An occurrence that sub-emitters react to; mirrored as EVENT_BYTES in gpu/system.c3.
struct ParticleEventGpu {
    vec3 position;
    uint seed; // of the particle that raised it
    vec3 velocity;
    uint key; // particle_event_key
    uint accepted; // bit s is set when sub-emitter s reacts
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer ParticleEvents {
    ParticleEventGpu values[];
};

// One particle's trail cursor; mirrored as TRAIL_HEADER_BYTES in gpu/system.c3.
struct TrailHeaderGpu {
    uint head; // slot the next point is written to
    uint count; // stored points, the newest just before head
    float clock; // seconds since the last stored point
    float path_length; // distance along the stored points at the newest
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer TrailHeaders {
    TrailHeaderGpu values[];
};

// xyz: position of a stored point, w: the particle's age when it was stored.
// Mirrored as TRAIL_POINT_BYTES in gpu/system.c3.
layout(buffer_reference, std430, buffer_reference_align = 16) buffer TrailPoints {
    vec4 values[];
};

// One float per stored point; mirrored as TRAIL_DISTANCE_BYTES in gpu/system.c3.
layout(buffer_reference, std430, buffer_reference_align = 4) buffer TrailDistances {
    float values[];
};

// x: live flag, y: drawn flag, z: live rank, w: drawn rank
layout(buffer_reference, std430, buffer_reference_align = 16) buffer ParticleScan {
    uvec4 values[];
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer ParticleTotals {
    uvec2 values[];
};

float particle_size_scale(StepRoot root, float life) {
    float position = life * float(PARTICLE_TABLE_ENTRIES - 1u);
    uint first = min(uint(position), PARTICLE_TABLE_ENTRIES - 2u);
    float fraction = position - float(first);
    return root.size_over_life[first] * (1.0 - fraction) + root.size_over_life[first + 1u] * fraction;
}

vec4 particle_color_scale(StepRoot root, float life) {
    float position = life * float(PARTICLE_TABLE_ENTRIES - 1u);
    uint first = min(uint(position), PARTICLE_TABLE_ENTRIES - 2u);
    float fraction = position - float(first);
    return root.color_over_life[first] * (1.0 - fraction) + root.color_over_life[first + 1u] * fraction;
}

// Mirrors draw_extent in update.c3.
float particle_draw_extent(StepRoot root, ParticleGpu particle) {
    return particle.size * particle_size_scale(root, particle.age / particle.lifetime);
}

// Mirrors trail_slot in trail.c3.
uint particle_trail_slot(TrailHeaderGpu header, uint size, uint newest_rank) {
    return (header.head + size - 1u - newest_rank) % size;
}

// Mirrors copy_trail in trail.c3 between the two halves; only the stored points move.
void particle_copy_trail(StepRoot root, bool to_alternate, uint source, uint target) {
    TrailHeaders from_headers = TrailHeaders(to_alternate ? root.trail_headers_home : root.trail_headers_alt);
    TrailPoints from_points = TrailPoints(to_alternate ? root.trail_points_home : root.trail_points_alt);
    TrailDistances from_distances = TrailDistances(to_alternate ? root.trail_distances_home : root.trail_distances_alt);
    TrailHeaders to_headers = TrailHeaders(to_alternate ? root.trail_headers_alt : root.trail_headers_home);
    TrailPoints to_points = TrailPoints(to_alternate ? root.trail_points_alt : root.trail_points_home);
    TrailDistances to_distances = TrailDistances(to_alternate ? root.trail_distances_alt : root.trail_distances_home);

    TrailHeaderGpu header = from_headers.values[source];
    to_headers.values[target] = header;
    uint size = root.trail_max_points;
    for (uint rank = 0u; rank < header.count; rank++) {
        uint slot = particle_trail_slot(header, size, rank);
        to_points.values[target * size + slot] = from_points.values[source * size + slot];
        to_distances.values[target * size + slot] = from_distances.values[source * size + slot];
    }
}

// Particles the step starts with: the survivors of the last step and the children delivered since.
uint particle_pool_size(ParticleControl control) {
    return control.alive + control.delivered;
}

ParticleEvents particle_events(StepRoot root, uint half_index) {
    return ParticleEvents(root.events + uint64_t(half_index) * uint64_t(root.event_capacity) * PARTICLE_EVENT_BYTES);
}

// Keeps one event for the sub-emitters that react to the trigger. An event past the capacity is counted when the
// step publishes.
void particle_raise_event(StepRoot root, ParticleControl control, ParticleGpu particle, uint trigger) {
    uint accepted = root.event_accept[trigger];
    if (accepted == 0u) return;

    uint half_index = control.step & 1u;
    uint slot = atomicAdd(control.event_counts[half_index], 1u);
    if (slot >= root.event_capacity) return;

    particle_events(root, half_index).values[slot] = ParticleEventGpu(
        particle.position,
        particle.seed,
        particle.velocity,
        particle_event_key(particle.spawn, control.step, trigger),
        accepted,
        0u,
        0u,
        0u
    );
}

// Admitted particles of this step; the free slots after the survivors bound it.
uint particle_emitted(StepRoot root, ParticleControl control) {
    return min(root.requested, root.capacity - control.live_total);
}

#endif
