module c3d::landscape;

import std::math;

const float UNIT_SCALE @private = 1.0f / 16777216.0f; // the top 24 bits of a hash, which a float holds exactly

// Jarzynski and Olano 2020, the permutation of noise.glsl's pcg_hash.
fn uint pcg_hash(uint value) @private {
    uint state = value * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// Two independent standard normal values for a seed and a key, by Box-Muller from two hashed uniforms.
fn float[<2>] gaussian_pair(uint seed, uint key) @private {
    uint first = pcg_hash(pcg_hash(seed) ^ key);
    float radius_unit = ((float)(first >> 8) + 1) * UNIT_SCALE; // (0, 1]: the logarithm stays finite
    float angle_unit = (float)(pcg_hash(first) >> 8) * UNIT_SCALE;
    float radius = math::sqrt(-2 * math::ln(radius_unit));
    float angle = 2 * (float)math::PI * angle_unit;
    return { radius * math::cos(angle), radius * math::sin(angle) };
}
