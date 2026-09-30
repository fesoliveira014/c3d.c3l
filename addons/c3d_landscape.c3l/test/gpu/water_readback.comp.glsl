#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "texture_fetch.glsl"

layout(local_size_x = 1) in;

const uint WATER_READBACK_POINTS = 64u; // mirrored as READBACK_POINTS in water_acceptance.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer WaterReadbackRoot {
    uint64_t output_address;
    uint point_count;
    uint _pad0;
    ivec2 pixels[WATER_READBACK_POINTS];
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer WaterReadbackOutput {
    vec4 texels[WATER_READBACK_POINTS];
};

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    WaterReadbackRoot root = WaterReadbackRoot(dispatch.parameters);
    DispatchTextureGpu texture = DispatchTexturesGpu(dispatch.textures).slots[0];
    WaterReadbackOutput destination = WaterReadbackOutput(root.output_address);
    for (uint point = 0u; point < root.point_count; point++) {
        destination.texels[point] = fetch_texture_2d(texture.texture_index, root.pixels[point]);
    }
}
