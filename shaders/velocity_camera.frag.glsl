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
// The depth was rasterized jittered; the clip mapping removes that jitter.
void main() {
    VelocityRoot root = VelocityRoot(pc.fragment_root_gpu);
    float depth = sample_texture_2d(root.depth_texture, root.sampler_index, v_uv).r;
    if (depth == 0.0 && root.orthographic != 0u) {
        out_velocity = vec4(0.0);
        return;
    }
    vec2 ndc = (v_uv * 2.0 - 1.0) * vec2(1.0, -1.0);
    vec4 previous = root.clip_to_previous * vec4(ndc, depth, 1.0);
    if (depth == 0.0) {
        // Subtract homogeneous near-point weight so finite-far backgrounds remain directions.
        vec4 near_point = root.clip_to_previous * vec4(ndc, 1.0, 1.0);
        previous -= near_point * root.background_near_ratio;
    }
    vec2 previous_uv = (previous.xy / previous.w) * vec2(0.5, -0.5) + 0.5;
    // A direction keeps -m22 as its depth under a finite far plane; the stored depth of no geometry is 0.
    float previous_depth = depth > 0.0 ? previous.z / previous.w : 0.0;
    out_velocity = vec4(v_uv - root.jitter_uv - previous_uv, previous_depth, 0.0);
}
