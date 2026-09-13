#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "brdf.glsl"
#include "cube_direction.glsl"
#include "environment_sampling.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

void main() {
    EnvironmentPrefilterRoot root = EnvironmentPrefilterRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.size || texel.y >= root.size) return;

    vec2 uv = (vec2(texel) + 0.5) / float(root.size);
    vec3 direction = environment_cube_direction(root.face, uv);
    vec3 reference = abs(direction.z) < 0.999
        ? vec3(0.0, 0.0, 1.0)
        : vec3(1.0, 0.0, 0.0);
    vec3 tangent = normalize(cross(reference, direction));
    vec3 bitangent = cross(direction, tangent);
    float perceptual = max(root.roughness, MIN_PERCEPTUAL_ROUGHNESS);
    float alpha = perceptual * perceptual;
    float exponent = alpha / (2.0 * alpha + 1.0);
    vec3 accumulated = vec3(0.0);
    float accumulated_weight = 0.0;

    for (uint index = 0u; index < SHEEN_PREFILTER_SAMPLES; index++) {
        float sample_u = (float(index) + 0.5) / float(SHEEN_PREFILTER_SAMPLES);
        float phi = 2.0 * PI * environment_radical_inverse(index);
        float sine = sqrt(0.5) * pow(sample_u, exponent);
        float cosine = sqrt(1.0 - sine * sine);
        vec3 tangent_half = vec3(cos(phi) * sine, sin(phi) * sine, cosine);
        vec3 half_direction = normalize(
            tangent * tangent_half.x
            + bitangent * tangent_half.y
            + direction * tangent_half.z
        );
        vec3 light_direction = reflect(-direction, half_direction);
        float normal_light = dot(direction, light_direction);
        accumulated += sample_texture_cube_lod(
            root.source_cube,
            root.sampler_index,
            light_direction,
            0.0
        ).rgb * normal_light;
        accumulated_weight += normal_light;
    }
    store_storage_texture(
        root.output_texture,
        ivec2(texel),
        vec4(accumulated / accumulated_weight, 1.0)
    );
}
