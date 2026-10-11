#version 460
#extension GL_EXT_buffer_reference : require
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "fog.glsl"

layout(local_size_x = 1) in;
layout(push_constant) uniform Push { uint64_t root; } pc;

struct FogInput {
    uint64_t frame;
    uint64_t sky;
    vec4 distances;
    vec4 aerial_color_extinction;
    vec4 radiance_coverage;
    vec4 emission;
    vec4 direction;
};
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer FogInputs {
    FogInput values[];
};
layout(buffer_reference, std430, buffer_reference_align = 16) buffer FogOutput {
    vec4 values[];
};
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer FogRoot {
    uint64_t input_address;
    uint64_t output_address;
    uint count;
    uint padding0;
    uint padding1;
    uint padding2;
};

FogTerms aerial_terms(FogInput input_value, float distance) {
    float attenuation = exp(-input_value.aerial_color_extinction.w * distance);
    return FogTerms(vec3(attenuation), input_value.aerial_color_extinction.rgb * (1.0 - attenuation));
}

FogTerms cumulative_terms(FogInput input_value, float distance) {
    float clip_start = input_value.distances.w;
    FogTerms height = height_fog_segment(
        FrameRoot(input_value.frame), SkyFogGpu(input_value.sky), vec3(0.0),
        input_value.direction.xyz, clip_start, distance
    );
    FogTerms aerial = clip_start > 0.0
        ? fog_between(aerial_terms(input_value, clip_start), aerial_terms(input_value, distance))
        : aerial_terms(input_value, distance);
    return fog_compose(height, aerial);
}

vec3 transfer(FogTerms terms, vec3 radiance) {
    return terms.transmittance * radiance + terms.inscatter;
}

void main() {
    FogRoot root = FogRoot(pc.root);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.count) return;

    FogInput input_value = FogInputs(root.input_address).values[index];
    float near_distance = input_value.distances.x;
    float middle_distance = input_value.distances.y;
    float far_distance = input_value.distances.z;
    FogTerms near_terms = cumulative_terms(input_value, near_distance);
    FogTerms middle_terms = cumulative_terms(input_value, middle_distance);
    FogTerms far_terms = cumulative_terms(input_value, far_distance);
    FogTerms connecting = fog_between(near_terms, far_terms);
    FogTerms first = fog_between(near_terms, middle_terms);
    FogTerms second = fog_between(middle_terms, far_terms);
    vec3 raw = input_value.radiance_coverage.rgb;
    vec3 direct = transfer(near_terms, transfer(connecting, raw));
    vec3 inserted = transfer(near_terms, transfer(first, transfer(second, raw)));
    float coverage = input_value.radiance_coverage.a;
    vec3 emission = input_value.emission.rgb;
    vec3 background = transfer(far_terms, raw);
    vec3 sorted_over = coverage * transfer(near_terms, emission) + (1.0 - coverage) * background;
    vec3 layered_over = transfer(near_terms,
        coverage * emission + (1.0 - coverage) * transfer(connecting, raw));
    vec3 sorted_additive = background + coverage * near_terms.transmittance * emission;
    vec3 layered_additive = transfer(near_terms,
        transfer(connecting, raw) + coverage * emission);

    FogTerms height_interval = height_fog_segment(
        FrameRoot(input_value.frame), SkyFogGpu(input_value.sky), vec3(0.0),
        input_value.direction.xyz, near_distance, far_distance
    );
    FogTerms aerial_interval = fog_between(
        aerial_terms(input_value, near_distance), aerial_terms(input_value, far_distance));
    FogTerms sorted_interval = fog_compose(height_interval, aerial_interval);
    FogTerms background_terms = height_fog_beyond(
        FrameRoot(input_value.frame), SkyFogGpu(input_value.sky), vec2(0.5), vec3(0.0),
        input_value.direction.xyz, near_distance
    );

    FogTerms emitted_connection = fog_between(near_terms, middle_terms);
    vec3 rear_surface = input_value.emission.rgb + 0.625 * transfer(second, raw);
    vec3 front_surface = 0.25 * input_value.emission.rgb + 0.75 * transfer(emitted_connection, rear_surface);
    vec3 two_sheets = transfer(near_terms, front_surface);
    vec3 coverage_zero = transfer(near_terms, mix(transfer(connecting, raw), emission, 0.0));

    uint base = index * 16u;
    FogOutput output_value = FogOutput(root.output_address);
    output_value.values[base + 0u] = vec4(near_terms.transmittance, 1.0);
    output_value.values[base + 1u] = vec4(near_terms.inscatter, 1.0);
    output_value.values[base + 2u] = vec4(far_terms.transmittance, 1.0);
    output_value.values[base + 3u] = vec4(far_terms.inscatter, 1.0);
    output_value.values[base + 4u] = vec4(direct, 1.0);
    output_value.values[base + 5u] = vec4(inserted, 1.0);
    output_value.values[base + 6u] = vec4(sorted_over, 1.0);
    output_value.values[base + 7u] = vec4(layered_over, 1.0);
    output_value.values[base + 8u] = vec4(sorted_additive, 1.0);
    output_value.values[base + 9u] = vec4(layered_additive, 1.0);
    output_value.values[base + 10u] = vec4(transfer(near_terms, transfer(sorted_interval, raw)), 1.0);
    output_value.values[base + 11u] = vec4(connecting.inscatter, 1.0);
    output_value.values[base + 12u] = vec4(transfer(background_terms, raw), 1.0);
    output_value.values[base + 13u] = vec4(middle_terms.transmittance, 1.0);
    output_value.values[base + 14u] = vec4(two_sheets, 1.0);
    output_value.values[base + 15u] = vec4(coverage_zero, 1.0);
}
