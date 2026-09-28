#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "buffer_reference.glsl"
#include "descriptor_heap.glsl"
#include "texture_fetch.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ProbeReadbackRoot {
    uint64_t output_address;
    uint     atlas;
    uint     width;
    uint     height;
    uint     padding;
};

GPU_DECLARE_WRITEONLY_ARRAY_REF(ProbeReadbackOutput, vec4);

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    ProbeReadbackRoot root = ProbeReadbackRoot(dispatch.parameters);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;
    uint index = texel.y * root.width + texel.x;
    ProbeReadbackOutput(root.output_address).values[index] = fetch_texture_2d(root.atlas, ivec2(texel));
}
