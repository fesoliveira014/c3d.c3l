#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "texture_fetch.glsl"
#include "weighted_blend.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    WeightedCompositeRoot root = WeightedCompositeRoot(pc.fragment_root_gpu);
    ivec2 texel = ivec2(gl_FragCoord.xy);
    out_color = weighted_composite_color(
        fetch_texture_2d(root.accum_texture, texel),
        fetch_texture_2d(root.revealage_texture, texel).r
    );
}
