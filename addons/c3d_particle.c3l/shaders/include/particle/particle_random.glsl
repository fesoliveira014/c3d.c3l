#ifndef PARTICLE_RANDOM_GLSL
#define PARTICLE_RANDOM_GLSL

// Ordinals of the draws one emitted particle takes; mirrored by ParticleDraw in step.c3.
const uint PARTICLE_DRAW_POSITION_A = 0u;
const uint PARTICLE_DRAW_POSITION_B = 1u;
const uint PARTICLE_DRAW_POSITION_C = 2u;
const uint PARTICLE_DRAW_DIRECTION_HEIGHT = 3u;
const uint PARTICLE_DRAW_DIRECTION_ANGLE = 4u;
const uint PARTICLE_DRAW_LIFETIME = 5u;
const uint PARTICLE_DRAW_SPEED = 6u;
const uint PARTICLE_DRAW_SIZE = 7u;
const uint PARTICLE_DRAW_ROTATION = 8u;
const uint PARTICLE_DRAW_SPIN = 9u;
const uint PARTICLE_DRAW_SEED = 10u;

const float PARTICLE_UNIT_SCALE = 1.0 / 16777216.0; // mirrored as RANDOM_UNIT_SCALE in step.c3

// Mirrors pcg_hash in step.c3.
uint particle_pcg_hash(uint value) {
    uint state = value * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// Mirrors spawn_hash in step.c3; ordinal holds the low word, then the high word.
uint particle_spawn_hash(uint stream, uvec2 ordinal, uint draw) {
    uint low = particle_pcg_hash(particle_pcg_hash(stream) + ordinal.x);
    uint high = particle_pcg_hash(low + ordinal.y);
    return particle_pcg_hash(high + draw);
}

// Mirrors child_seed in step.c3; the key is the event index of the CPU path and particle_event_key here.
uint particle_child_seed(uint parent_seed, uint key, uint sub_index) {
    return particle_pcg_hash(particle_pcg_hash(particle_pcg_hash(parent_seed) + key) + sub_index);
}

// Names one event of one particle: its spawn ordinal, the step that raised it and the trigger. The CPU path keys by
// event index instead, so the two paths give different children.
uint particle_event_key(uvec2 ordinal, uint step, uint trigger) {
    uint spawned = particle_pcg_hash(particle_pcg_hash(ordinal.x) + ordinal.y);
    return particle_pcg_hash(particle_pcg_hash(spawned + step) + trigger);
}

// Mirrors SpawnDraws.unit in step.c3.
float particle_unit(uint stream, uvec2 ordinal, uint draw) {
    return float(particle_spawn_hash(stream, ordinal, draw) >> 8u) * PARTICLE_UNIT_SCALE;
}

// Mirrors SpawnDraws.sample in step.c3, in float.
float particle_sample(uint stream, uvec2 ordinal, uint draw, vec2 range) {
    float fraction = particle_unit(stream, ordinal, draw);
    return range.x * (1.0 - fraction) + range.y * fraction;
}

#endif
