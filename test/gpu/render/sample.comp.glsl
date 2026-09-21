#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer SampleRoot {
    uint64_t output_address;
    uint64_t padding;
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer SampleOutput {
    uint pixel;
};

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    SampleRoot root = SampleRoot(dispatch.parameters);
    DispatchTextureGpu texture = DispatchTexturesGpu(dispatch.textures).slots[0];
    vec4 color = sample_texture_2d(texture.texture_index, texture.sampler_index, vec2(0.5));
    SampleOutput(root.output_address).pixel = packUnorm4x8(clamp(color, 0.0, 1.0));
}
