#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "dof.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

vec3 unpremultiply(vec4 layer) {
    return layer.rgb / max(layer.a, DOF_COVERAGE_EPSILON);
}

void main() {
    DofRoot root = DofRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;

    vec2 uv = (vec2(texel) + 0.5) * root.full_texel;
    vec4 sharp = root.in_place != 0u
        ? load_storage_texture(root.output_texture, ivec2(texel))
        : sample_texture_2d(root.color_texture, root.sampler_index, uv);
    float depth = sample_texture_2d(root.depth_texture, root.sampler_index, uv).r;
    float coc = dof_signed_coc(dof_linear_depth(depth, root), root);
    float far_blend = max(coc, 0.0) / root.max_coc;

    vec4 far = sample_texture_2d(root.far_texture, root.sampler_index, uv);
    vec4 near = sample_texture_2d(root.near_texture, root.sampler_index, uv);
    vec3 color = mix(sharp.rgb, unpremultiply(far), far_blend * min(far.a * root.max_coc, 1.0));
    color = mix(color, unpremultiply(near), min(near.a * root.max_coc, 1.0));
    store_storage_texture(root.output_texture, ivec2(texel), vec4(color, sharp.a));
}
