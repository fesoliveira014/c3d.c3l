#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "sheen.glsl"
#include "environment_sampling.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

void main() {
    BrdfLutRoot root = BrdfLutRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.size || texel.y >= root.size) return;

    vec2 coordinates = (vec2(texel) + 0.5) / float(root.size);
    float normal_view = coordinates.x;
    float roughness = max(coordinates.y, MIN_PERCEPTUAL_ROUGHNESS);
    vec3 view_direction = vec3(
        sqrt(max(1.0 - normal_view * normal_view, 0.0)),
        0.0,
        normal_view
    );
    float albedo = 0.0;

    for (uint index = 0u; index < SHEEN_LUT_SAMPLES; index++) {
        float sample_u = (float(index) + 0.5) / float(SHEEN_LUT_SAMPLES);
        float phi = 2.0 * PI * environment_radical_inverse(index);
        float radial = sqrt(sample_u);
        vec3 light_direction = vec3(
            radial * cos(phi),
            radial * sin(phi),
            sqrt(1.0 - sample_u)
        );
        vec3 half_direction = normalize(view_direction + light_direction);
        float normal_half = clamp(half_direction.z, 0.0, 1.0);
        albedo += PI * sheen_distribution(normal_half, roughness)
            * sheen_visibility(normal_view, light_direction.z, roughness);
    }
    albedo = clamp(albedo / float(SHEEN_LUT_SAMPLES), 0.0, 1.0);
    store_storage_texture(root.output_texture, ivec2(texel), vec4(albedo, 0.0, 0.0, 0.0));
}
