#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "ibl.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

vec3 sky_unproject(FrameRoot frame, vec2 ndc, float depth) {
    vec4 homogeneous = frame.inv_view_proj * vec4(ndc, depth, 1.0);
    return homogeneous.xyz / homogeneous.w;
}

void main() {
    SkyRoot root = SkyRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(root.frame);
    vec2 ndc = vec2(v_uv.x * 2.0 - 1.0, 1.0 - v_uv.y * 2.0);
    vec3 direction;
    if (frame.proj[3][3] != 0.0) {
        direction = sky_unproject(frame, ndc, 0.25)
            - sky_unproject(frame, ndc, 0.75);
    } else {
        direction = sky_unproject(frame, ndc, 0.5) - frame.camera_position.xyz;
    }
    out_color = vec4(sky_radiance(root, normalize(direction)), 1.0);
}
