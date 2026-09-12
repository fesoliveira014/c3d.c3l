#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "brdf.glsl"
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
    float alpha = roughness * roughness;
    float alpha_squared = alpha * alpha;
    vec3 normal = vec3(0.0, 0.0, 1.0);
    vec3 view_direction = vec3(sqrt(max(1.0 - normal_view * normal_view, 0.0)), 0.0, normal_view);
    vec2 response = vec2(0.0);

    for (uint index = 0u; index < ENVIRONMENT_BRDF_SAMPLES; index++) {
        vec3 half_direction = environment_sample_ggx(
            index,
            ENVIRONMENT_BRDF_SAMPLES,
            roughness,
            normal
        );
        vec3 light_direction = reflect(-view_direction, half_direction);
        float normal_light = light_direction.z;
        if (normal_light <= 0.0) continue;

        float normal_half = max(half_direction.z, 0.0);
        float view_half = max(dot(view_direction, half_direction), 0.0);
        float weight = 4.0
            * visibility_smith(normal_view, normal_light, alpha_squared)
            * normal_light * view_half / normal_half;
        float complement = 1.0 - view_half;
        float complement_squared = complement * complement;
        float fresnel = complement_squared * complement_squared * complement;
        response += vec2(1.0 - fresnel, fresnel) * weight;
    }
    response /= float(ENVIRONMENT_BRDF_SAMPLES);
    store_storage_texture(root.output_texture, ivec2(texel), vec4(response, 0.0, 1.0));
}
