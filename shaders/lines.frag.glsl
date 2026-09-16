#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(location = 0) in vec4 v_color;
layout(location = 0) out vec4 out_color;

void main() {
    DebugLinesRoot root = DebugLinesRoot(pc.fragment_root_gpu);
    out_color = vec4(v_color.rgb, v_color.a * root.alpha);
}
