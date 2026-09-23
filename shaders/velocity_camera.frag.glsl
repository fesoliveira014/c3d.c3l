#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_velocity;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

// Camera motion of every pixel from stored depth; no geometry (depth 0) reprojects as a direction,
// which has no finite image under an orthographic projection, so that background stays still.
// The depth was rasterized jittered: the inverse is jittered and the current position unjittered.
void main() {
    VelocityRoot root = VelocityRoot(pc.fragment_root_gpu);
    float depth = sample_texture_2d(root.depth_texture, root.sampler_index, v_uv).r;
    if (depth == 0.0 && root.orthographic != 0u) {
        out_velocity = vec4(0.0);
        return;
    }
    vec2 ndc = (v_uv * 2.0 - 1.0) * vec2(1.0, -1.0);
    vec4 world = root.inv_view_proj * vec4(ndc, depth, 1.0);
    vec4 previous = depth > 0.0
        ? root.prev_view_proj * vec4(world.xyz / world.w, 1.0)
        : root.prev_view_proj * vec4(world.xyz, 0.0);
    vec2 previous_uv = (previous.xy / previous.w) * vec2(0.5, -0.5) + 0.5;
    out_velocity = vec4(v_uv - root.jitter_uv - previous_uv, previous.z / previous.w, 0.0);
}
