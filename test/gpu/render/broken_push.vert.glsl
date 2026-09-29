#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(location = 6) out vec4 v_clip_pos;
layout(location = 7) out vec4 v_prev_clip_pos;

// The first root member is not a 64-bit address, so the backend rejects the stage.
layout(push_constant) uniform Push {
    uvec2 vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    // Reading the block keeps it in the reflected interface; an unread push block is not checked.
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    gl_Position = draw.model * vec4(0.0, 0.0, 0.0, 1.0);
    v_clip_pos = gl_Position;
    v_prev_clip_pos = gl_Position;
}
