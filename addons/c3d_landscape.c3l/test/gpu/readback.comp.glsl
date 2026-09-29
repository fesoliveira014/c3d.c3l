#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 1) in;

const uint READBACK_POINTS = 2u; // mirrored as READBACK_POINTS in terrain_acceptance.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ReadbackRoot {
    uint64_t output_address;
    vec2 uvs[READBACK_POINTS];
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer ReadbackOutput {
    uint pixels[READBACK_POINTS];
};

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    ReadbackRoot root = ReadbackRoot(dispatch.parameters);
    DispatchTextureGpu texture = DispatchTexturesGpu(dispatch.textures).slots[0];
    for (uint point = 0u; point < READBACK_POINTS; point++) {
        vec4 color = sample_texture_2d(texture.texture_index, texture.sampler_index, root.uvs[point]);
        ReadbackOutput(root.output_address).pixels[point] = packUnorm4x8(clamp(color, 0.0, 1.0));
    }
}
