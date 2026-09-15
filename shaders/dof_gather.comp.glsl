#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "dof.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Near layer: radius from the dilated tile coverage; every tap counts.
vec4 gather_near(DofRoot root, uvec2 texel, vec2 uv) {
    float coverage = load_storage_texture(root.tile_texture, ivec2(texel / POST_TILE_SIZE)).r;
    float radius = coverage * root.max_coc;
    if (radius < 0.5) return sample_texture_2d(root.near_texture, root.sampler_index, uv);

    vec4 sum = vec4(0.0);
    for (uint tap = 0u; tap < DOF_TAP_COUNT; tap++) {
        vec2 offset = dof_disc_tap(tap) * radius * root.half_texel;
        sum += sample_texture_2d(root.near_texture, root.sampler_index, uv + offset);
    }
    return sum / float(DOF_TAP_COUNT);
}

// Far layer: radius from the texel's own coverage; a tap counts when its circle reaches the center.
vec4 gather_far(DofRoot root, vec2 uv) {
    vec4 center = sample_texture_2d(root.far_texture, root.sampler_index, uv);
    float radius = center.a * root.max_coc;
    if (radius < 0.5) return center;

    vec4 sum = center;
    float weight_sum = 1.0;
    for (uint tap = 0u; tap < DOF_TAP_COUNT; tap++) {
        vec2 disc = dof_disc_tap(tap);
        float distance = length(disc) * radius;
        vec4 tap_layer = sample_texture_2d(root.far_texture, root.sampler_index, uv + disc * radius * root.half_texel);
        float weight = clamp(1.0 + tap_layer.a * root.max_coc - distance, 0.0, 1.0);
        sum += tap_layer * weight;
        weight_sum += weight;
    }
    return sum / weight_sum;
}

void main() {
    DofRoot root = DofRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;

    vec2 uv = (vec2(texel) + 0.5) * root.half_texel;
    vec4 blurred = root.pass == DOF_PASS_GATHER_NEAR ? gather_near(root, texel, uv) : gather_far(root, uv);
    store_storage_texture(root.output_texture, ivec2(texel), blurred);
}
