#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "dof.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// One half-resolution texel from its 2x2 full-resolution block: premultiplied near and far layers.
void main() {
    DofRoot root = DofRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;

    vec3 near_color = vec3(0.0);
    vec3 far_color = vec3(0.0);
    float near_coverage = 0.0;
    float far_coverage = 0.0;
    for (uint corner = 0u; corner < 4u; corner++) {
        vec2 offset = vec2(float(corner & 1u), float(corner >> 1u));
        vec2 uv = (vec2(texel) * 2.0 + offset + 0.5) * root.full_texel;
        vec3 color = sample_texture_2d(root.color_texture, root.sampler_index, uv).rgb;
        float depth = sample_texture_2d(root.depth_texture, root.sampler_index, uv).r;
        float coc = dof_signed_coc(dof_linear_depth(depth, root), root);
        float near_weight = max(-coc, 0.0) / root.max_coc;
        float far_weight = max(coc, 0.0) / root.max_coc;
        near_color += color * near_weight;
        far_color += color * far_weight;
        near_coverage += near_weight;
        far_coverage += far_weight;
    }
    store_storage_texture(root.near_texture, ivec2(texel), vec4(near_color, near_coverage) * 0.25);
    store_storage_texture(root.far_texture, ivec2(texel), vec4(far_color, far_coverage) * 0.25);
}
