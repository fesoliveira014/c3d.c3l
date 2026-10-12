#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in; // mirrored as CLOUD_NOISE_GROUP_SIZE

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const uint CLOUD_FIRST_CELLS = 4u;     // lattice cells across the volume at the first octave; each octave doubles it
const uint CLOUD_PERLIN_OCTAVES = 3u;
const float CLOUD_PERLIN_RANGE = 0.75; // maps the fbm, whose spread is about 0.25, onto most of [0, 1]

// Jarzynski and Olano 2020, three uniform words from one lattice cell.
uvec3 pcg3d(uvec3 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    return v;
}

vec3 cloud_cell_random(ivec3 cell, uint seed) {
    return vec3(pcg3d(uvec3(cell) + uvec3(seed, seed * 7u, seed * 13u)) >> 8u) * (1.0 / 16777216.0);
}

// Gradient noise in about [-0.87, 0.87] that repeats every `cells` cells.
float cloud_perlin(vec3 position, uint cells, uint seed) {
    vec3 scaled = position * float(cells);
    ivec3 base = ivec3(floor(scaled));
    vec3 local = scaled - vec3(base);
    vec3 fade = local * local * local * (local * (local * 6.0 - 15.0) + 10.0);
    float value = 0.0;
    for (int corner = 0; corner < 8; corner++) {
        ivec3 offset = ivec3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1);
        vec3 gradient = normalize(cloud_cell_random((base + offset) % ivec3(cells), seed) * 2.0 - 1.0);
        vec3 weights = mix(vec3(1.0) - fade, fade, vec3(offset));
        value += weights.x * weights.y * weights.z * dot(gradient, local - vec3(offset));
    }
    return value;
}

// Distance in cells to the nearest feature point of a lattice that repeats every `cells` cells.
float cloud_worley(vec3 position, uint cells, uint seed) {
    vec3 scaled = position * float(cells);
    ivec3 base = ivec3(floor(scaled));
    vec3 local = scaled - vec3(base);
    float nearest = 4.0;
    for (int z = -1; z <= 1; z++) {
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                ivec3 offset = ivec3(x, y, z);
                ivec3 wrapped = (base + offset + ivec3(cells)) % ivec3(cells);
                vec3 gap = vec3(offset) + cloud_cell_random(wrapped, seed) - local;
                nearest = min(nearest, dot(gap, gap));
            }
        }
    }
    return sqrt(nearest);
}

// R: Perlin noise lifted by the first Worley octave; G, B, A: Worley octaves at 1, 2 and 4 times its frequency.
void main() {
    CloudNoiseRoot root = CloudNoiseRoot(pc.root_gpu);
    ivec3 voxel = ivec3(gl_GlobalInvocationID);
    vec3 position = (vec3(voxel) + 0.5) / float(root.size);

    float perlin = 0.0;
    float amplitude = 0.5;
    float amplitude_sum = 0.0;
    for (uint octave = 0u; octave < CLOUD_PERLIN_OCTAVES; octave++) {
        perlin += amplitude * cloud_perlin(position, CLOUD_FIRST_CELLS << octave, octave);
        amplitude_sum += amplitude;
        amplitude *= 0.5;
    }
    float perlin_unit = clamp(0.5 + CLOUD_PERLIN_RANGE * perlin / amplitude_sum, 0.0, 1.0);

    float worley_low = 1.0 - min(cloud_worley(position, CLOUD_FIRST_CELLS, 1u), 1.0);
    float worley_mid = 1.0 - min(cloud_worley(position, CLOUD_FIRST_CELLS * 2u, 2u), 1.0);
    float worley_high = 1.0 - min(cloud_worley(position, CLOUD_FIRST_CELLS * 4u, 3u), 1.0);
    float perlin_worley = worley_low + perlin_unit * (1.0 - worley_low);
    store_storage_texture_3d(root.output_texture, voxel, vec4(perlin_worley, worley_low, worley_mid, worley_high));
}
