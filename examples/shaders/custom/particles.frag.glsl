#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(location = 3) in vec2 v_uv0;
layout(location = 5) in vec4 v_color;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    vec2 offset = v_uv0 * 2.0 - 1.0;
    float radius_squared = dot(offset, offset);
    if (radius_squared > 1.0) discard;
    float glow = 1.0 - radius_squared;
    out_color = vec4(v_color.rgb * (0.4 + 0.6 * glow), 1.0);
}
