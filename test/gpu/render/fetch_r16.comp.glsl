#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer FetchRoot {
    uint64_t output_address;
    ivec2 texel;
};

layout(buffer_reference, std430, buffer_reference_align = 4) buffer FetchOutput {
    uint value;
};

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    FetchRoot root = FetchRoot(dispatch.parameters);
    DispatchTextureGpu texture = DispatchTexturesGpu(dispatch.textures).slots[0];
    FetchOutput(root.output_address).value = gpu_fetch_uint(texture.texture_index, root.texel, 0);
}
