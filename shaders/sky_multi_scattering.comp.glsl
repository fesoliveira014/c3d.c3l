#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "atmosphere.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const uint DIRECTION_ROWS = 8u; // SKY_MULTI_SCATTERING_DIRECTIONS is its square

// Hillaire 2020: second-order light from every direction, summed over all orders as a geometric series.
void main() {
    SkyTableRoot root = SkyTableRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;

    SkyFogGpu sky = SkyFogGpu(root.sky_fog);
    vec2 uv = (vec2(texel) + 0.5) / vec2(root.width, root.height);
    float cos_sun = sky_uv_to_unit(uv.x, float(root.width)) * 2.0 - 1.0;
    float altitude = sky_uv_to_unit(uv.y, float(root.height)) * (sky.top_radius - sky.planet_radius);
    vec3 sun_direction = vec3(sqrt(max(1.0 - cos_sun * cos_sun, 0.0)), cos_sun, 0.0);

    vec3 second_order = vec3(0.0);
    vec3 transfer = vec3(0.0);
    for (uint index = 0u; index < SKY_MULTI_SCATTERING_DIRECTIONS; index++) {
        float row = (float(index / DIRECTION_ROWS) + 0.5) / float(DIRECTION_ROWS);
        float column = (float(index % DIRECTION_ROWS) + 0.5) / float(DIRECTION_ROWS);
        float azimuth = 2.0 * PI * row;
        float cos_polar = 1.0 - 2.0 * column;
        float sin_polar = sqrt(max(1.0 - cos_polar * cos_polar, 0.0));
        vec3 direction = vec3(cos(azimuth) * sin_polar, cos_polar, sin(azimuth) * sin_polar);
        SkyScattering scattering = integrate_sky_scattering(
            sky,
            altitude,
            direction,
            sun_direction,
            -1.0,
            SKY_MULTI_SCATTERING_STEPS,
            true,
            true
        );
        second_order += scattering.luminance;
        transfer += scattering.multi_scattering;
    }
    second_order /= float(SKY_MULTI_SCATTERING_DIRECTIONS);
    transfer /= float(SKY_MULTI_SCATTERING_DIRECTIONS);
    store_storage_texture(root.output_texture, ivec2(texel), vec4(second_order / (vec3(1.0) - transfer), 1.0));
}
