#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "probe_atlas.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

void main() {
    ProbeBorderRoot root = ProbeBorderRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;

    uvec2 local = texel % root.cell_edge;
    uvec2 source = probe_border_source(root.cell_edge, local);
    if (source == local) return;
    uvec2 cell_origin = texel - local;
    store_storage_texture(root.atlas, ivec2(texel), load_storage_texture(root.atlas, ivec2(cell_origin + source)));
}
