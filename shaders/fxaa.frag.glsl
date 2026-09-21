#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "fxaa.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    FxaaRoot root = FxaaRoot(pc.fragment_root_gpu);
    out_color = vec4(fxaa_color(root, v_uv).rgb, 1.0);
}
