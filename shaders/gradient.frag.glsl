#version 460
#include "generated/shader_abi.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    out_color = vec4(v_uv.x, v_uv.y, 0.25, 1.0);
}
