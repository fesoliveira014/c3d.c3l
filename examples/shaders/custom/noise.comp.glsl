#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer NoiseRoot {
    float time;
    uint size;
    float cells;
    float _pad0;
};

float hash(vec2 cell) {
    return fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 point) {
    vec2 cell = floor(point);
    vec2 offset = fract(point);
    vec2 blend = offset * offset * (3.0 - 2.0 * offset);
    float bottom = mix(hash(cell), hash(cell + vec2(1.0, 0.0)), blend.x);
    float top = mix(hash(cell + vec2(0.0, 1.0)), hash(cell + vec2(1.0, 1.0)), blend.x);
    return mix(bottom, top, blend.y);
}

void main() {
    DispatchRoot root = DispatchRoot(pc.root_gpu);
    DispatchTexturesGpu textures = DispatchTexturesGpu(root.textures);
    NoiseRoot noise = NoiseRoot(root.parameters);
    uvec2 coord = gl_GlobalInvocationID.xy;
    if (coord.x >= noise.size || coord.y >= noise.size) return;

    vec2 uv = (vec2(coord) + 0.5) / float(noise.size);
    vec2 drift = vec2(noise.time * 0.15, noise.time * 0.07);
    float coarse = value_noise(uv * noise.cells + drift);
    float fine = value_noise(uv * noise.cells * 4.0 - drift * 2.0);
    float value = 0.65 * coarse + 0.35 * fine;
    vec3 color = mix(vec3(0.10, 0.25, 0.55), vec3(0.95, 0.85, 0.55), value);
    store_storage_texture(textures.slots[0].texture_index, ivec2(coord), vec4(color, 1.0));
}
