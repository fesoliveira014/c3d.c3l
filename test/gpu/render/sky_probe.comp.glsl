#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "buffer_reference.glsl"
#include "atmosphere.glsl"

layout(local_size_x = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const uint SKY_PROBE_CASES = 8u; // mirrored as SKY_PROBE_CASES in test_sky.c3

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer SkyProbeRoot {
    uint64_t output_address;
    uint64_t sky_fog;
    vec4     cases[SKY_PROBE_CASES];
};

GPU_DECLARE_WRITEONLY_ARRAY_REF(SkyProbeOutput, vec4);

// Each case is (altitude, cosine of the zenith angle); the result is the transmittance table's reading.
void main() {
    DispatchRoot dispatch = DispatchRoot(pc.root_gpu);
    SkyProbeRoot root = SkyProbeRoot(dispatch.parameters);
    SkyFogGpu sky = SkyFogGpu(root.sky_fog);
    SkyProbeOutput results = SkyProbeOutput(root.output_address);
    for (uint index = 0u; index < SKY_PROBE_CASES; index++) {
        vec4 test_case = root.cases[index];
        results.values[index] = vec4(sky_transmittance(sky, test_case.x, test_case.y), 1.0);
    }
}
