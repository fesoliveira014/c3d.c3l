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
    if (root.roughness == 0.0) {
        vec4 radiance = sample_texture_cube_lod(
            root.source_cube,
            root.sampler_index,
            direction,
            0.0
        );
        store_storage_texture(root.output_texture, ivec2(texel), vec4(radiance.rgb, 1.0));
        return;
    }

    vec3 accumulated = vec3(0.0);
    float accumulated_weight = 0.0;
    for (uint index = 0u; index < ENVIRONMENT_PREFILTER_SAMPLES; index++) {
        vec3 half_direction = environment_sample_ggx(
            index,
            ENVIRONMENT_PREFILTER_SAMPLES,
            root.roughness,
            direction
        );
        vec3 light_direction = reflect(-direction, half_direction);
        float normal_light = dot(direction, light_direction);
        if (normal_light <= 0.0) continue;

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
