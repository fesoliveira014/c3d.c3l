#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(location = 6) in vec4 v_clip_pos;
layout(location = 7) in vec4 v_prev_clip_pos;
layout(location = 0) out vec4 out_velocity;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

// Screen displacement in framebuffer UV: current minus previous, top-left origin; z is the previous depth.
// An RG16 target keeps only the displacement.
void main() {
    vec2 current = v_clip_pos.xy / v_clip_pos.w;
    vec2 previous = v_prev_clip_pos.xy / v_prev_clip_pos.w;
    out_velocity = vec4((current - previous) * vec2(0.5, -0.5), v_prev_clip_pos.z / v_prev_clip_pos.w, 0.0);
}
