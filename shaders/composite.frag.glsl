#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    CompositeRoot root = CompositeRoot(pc.fragment_root_gpu);
    out_color = sample_texture_2d(root.source_texture, root.source_sampler, v_uv);
}
