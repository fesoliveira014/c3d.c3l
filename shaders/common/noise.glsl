#ifndef C3D_NOISE_GLSL
#define C3D_NOISE_GLSL

// Jimenez 2014 interleaved gradient noise in [0, 1).
float interleaved_gradient_noise(vec2 pixel, uint frame) {
    vec2 offset = pixel + 5.588238 * float(frame);
    return fract(52.9829189 * fract(dot(offset, vec2(0.06711056, 0.00583715))));
}

// Jarzynski and Olano 2020, PCG output permutation.
uint pcg_hash(uint value) {
    uint state = value * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// Uniform in [0, 1) from the top 24 bits, which a float holds exactly.
float hash_unit(uint value) {
    return float(pcg_hash(value) >> 8u) * (1.0 / 16777216.0);
}

#endif
