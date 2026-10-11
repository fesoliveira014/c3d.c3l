#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "atmosphere.glsl"
#include "fog.glsl"

const uint TRACE_SEGMENT_STEPS = 64u; // Approved finite world-connection midpoint count.
const uint TRACE_SEGMENT_ROWS = 8u; // Mirrored as TRACE_SEGMENT_ROWS in test_trace_segment.c3.

layout(local_size_x = 1) in;
layout(push_constant) uniform Push { uint64_t root_gpu; } pc;

struct SegmentInput {
    uint64_t frame;
    uint64_t sky;
    vec4 origin_length;
    vec4 direction;
    vec4 radiance;
    vec4 emission;
};

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer SegmentInputs {
    SegmentInput values[];
};

layout(buffer_reference, std430, buffer_reference_align = 16) writeonly buffer SegmentOutputs {
    vec4 values[];
};

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer SegmentRoot {
    uint64_t inputs;
    uint64_t outputs;
    uint output_image;
    uint count;
    uint padding0;
    uint padding1;
};

void main() {
    SegmentRoot root = SegmentRoot(pc.root_gpu);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.count) return;

    SegmentInput input_value = SegmentInputs(root.inputs).values[index];
    FrameRoot frame = FrameRoot(input_value.frame);
    SkyFogGpu sky = SkyFogGpu(input_value.sky);
    vec3 origin = input_value.origin_length.xyz;
    vec3 direction = input_value.direction.xyz;
    float distance = input_value.origin_length.w;
    FogTerms atmosphere = fog_none();
    FogTerms height;
    if (input_value.direction.w == 2.0) {
        FogTerms near_terms = FogTerms(vec3(1e-6), vec3(0.5, 0.4, 0.3));
        FogTerms far_terms = FogTerms(vec3(1e-7), vec3(0.25, 0.2, 0.15));
        atmosphere = fog_between(near_terms, far_terms);
        height = fog_none();
    } else if (distance < 0.0) {
        height = height_fog_to_infinity(frame, sky, origin, direction);
    } else {
        height = height_fog_segment(frame, sky, origin, direction, 0.0, distance);
        if ((sky.flags & SKY_FOG_ATMOSPHERE) != 0u && distance > 0.0) {
            SkyScattering scattering = integrate_sky_scattering(
                sky,
                max(origin.y, 0.0),
                direction,
                sky.sun_direction_cos_radius.xyz,
                distance,
                TRACE_SEGMENT_STEPS,
                false,
                false
            );
            atmosphere.transmittance = scattering.transmittance;
            atmosphere.inscatter = scattering.luminance * sky.sun_illuminance.rgb;
        }
    }

    FogTerms combined = fog_compose(height, atmosphere);
    vec3 observed = combined.transmittance * input_value.radiance.rgb + combined.inscatter;
    vec3 additive = combined.transmittance * input_value.emission.rgb;
    SegmentOutputs output_value = SegmentOutputs(root.outputs);
    uint base = index * TRACE_SEGMENT_ROWS;
    output_value.values[base + 0u] = vec4(atmosphere.transmittance, 1.0);
    output_value.values[base + 1u] = vec4(atmosphere.inscatter, 1.0);
    output_value.values[base + 2u] = vec4(height.transmittance, 1.0);
    output_value.values[base + 3u] = vec4(height.inscatter, 1.0);
    output_value.values[base + 4u] = vec4(combined.transmittance, 1.0);
    output_value.values[base + 5u] = vec4(combined.inscatter, 1.0);
    output_value.values[base + 6u] = vec4(observed, 1.0);
    output_value.values[base + 7u] = vec4(additive, 1.0);
    store_storage_texture(root.output_image, ivec2(index, 0), vec4(observed, 1.0));
}
