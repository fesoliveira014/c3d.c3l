#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(location = 6) in vec4 v_clip_pos;
layout(location = 7) in vec4 v_prev_clip_pos;
layout(location = 0) out vec2 out_velocity;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

// Screen displacement in framebuffer UV: current minus previous, top-left origin.
void main() {
    vec2 current = v_clip_pos.xy / v_clip_pos.w;
    vec2 previous = v_prev_clip_pos.xy / v_prev_clip_pos.w;
    out_velocity = (current - previous) * vec2(0.5, -0.5);
}
