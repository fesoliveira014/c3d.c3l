#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 64) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer LineRoot {
    uint64_t output_address;
    vec2 uv_start;
    vec2 uv_step;
    uint count;
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer LineOutput {
    float luminance[];
};

void main() {
    uint index = gl_GlobalInvocationID.x;
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    LineRoot root = LineRoot(dispatch.parameters);
    if (index >= root.count) return;
    DispatchTextureGpu texture = DispatchTexturesGpu(dispatch.textures).slots[0];
    vec2 uv = root.uv_start + root.uv_step * float(index);
    vec4 color = sample_texture_2d(texture.texture_index, texture.sampler_index, uv);
    LineOutput(root.output_address).luminance[index] = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
}
