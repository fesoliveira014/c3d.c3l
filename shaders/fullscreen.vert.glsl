#version 460
#include "generated/shader_abi.glsl"

layout(location = 0) out vec2 v_uv;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    vec2 corner = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
    // Screen-space uv: (0, 0) is the top-left texel of a render target.
    v_uv = vec2(corner.x, 1.0 - corner.y);
}
