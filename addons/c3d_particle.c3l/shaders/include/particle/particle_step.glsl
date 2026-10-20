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
const uint PARTICLE_SCAN_BLOCKS = 0u; // mirrored by ScanMode in gpu/system.c3
const uint PARTICLE_SCAN_TOTALS = 1u;
const uint PARTICLE_FLIPBOOK_FPS = 1u; // bits of StepRoot.flipbook_flags; mirrored in gpu/system.c3
const uint PARTICLE_FLIPBOOK_RANDOM_START = 2u;
const uint PARTICLE_FLIPBOOK_BLEND = 4u;
const float PARTICLE_FULL_TURN = 6.2831855;

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
    uint _pad0;
    uint _pad1;
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
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer ParticleStates {
    ParticleGpu values[];
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

// Admitted particles of this step; the free slots after the survivors bound it.
uint particle_emitted(StepRoot root, ParticleControl control) {
    return min(root.requested, root.capacity - control.live_total);
}

#endif
