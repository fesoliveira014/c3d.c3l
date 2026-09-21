#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer FillRoot {
    vec4 color;
    uint size;
    uint padding0;
    uint padding1;
    uint padding2;
};

void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    FillRoot root = FillRoot(dispatch.parameters);
    uvec2 coord = gl_GlobalInvocationID.xy;
    if (coord.x >= root.size || coord.y >= root.size) return;
    DispatchTextureGpu texture = DispatchTexturesGpu(dispatch.textures).slots[0];
    store_storage_texture(texture.texture_index, ivec2(coord), root.color);
}
