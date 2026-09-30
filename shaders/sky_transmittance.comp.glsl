#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "atmosphere.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// The same midpoint march as atmosphere_transmittance in atmosphere.c3.
void main() {
    SkyTableRoot root = SkyTableRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;

    SkyFogGpu sky = SkyFogGpu(root.sky_fog);
    vec2 uv = (vec2(texel) + 0.5) / vec2(root.width, root.height);
    float altitude;
    float cos_zenith;
    transmittance_parameters(sky, uv, altitude, cos_zenith);
    float step = atmosphere_distance_to_top(sky, altitude, cos_zenith) / float(SKY_TRANSMITTANCE_STEPS);
    vec3 optical_depth = vec3(0.0);
    for (uint index = 0u; index < SKY_TRANSMITTANCE_STEPS; index++) {
        float along = (float(index) + 0.5) * step;
        float sample_altitude = atmosphere_altitude_along(sky, altitude, cos_zenith, along);
        optical_depth += atmosphere_medium(sky, sample_altitude).extinction * step;
    }
    store_storage_texture(root.output_texture, ivec2(texel), vec4(exp(-optical_depth), 1.0));
}
