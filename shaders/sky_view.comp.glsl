#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "atmosphere.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

void main() {
    SkyTableRoot root = SkyTableRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;

    SkyFogGpu sky = SkyFogGpu(root.sky_fog);
    vec2 uv = (vec2(texel) + 0.5) / vec2(root.width, root.height);
    float cos_zenith;
    float cos_azimuth;
    sky_view_parameters(sky, uv, cos_zenith, cos_azimuth);
    float sin_zenith = sqrt(max(1.0 - cos_zenith * cos_zenith, 0.0));
    vec3 direction = vec3(
        sin_zenith * cos_azimuth,
        cos_zenith,
        sin_zenith * sqrt(max(1.0 - cos_azimuth * cos_azimuth, 0.0))
    );
    float cos_sun = sky.sun_direction_cos_radius.y;
    vec3 sun_direction = vec3(sqrt(max(1.0 - cos_sun * cos_sun, 0.0)), cos_sun, 0.0);
    SkyScattering scattering = integrate_sky_scattering(
        sky,
        sky.camera_altitude,
        direction,
        sun_direction,
        -1.0,
        SKY_SCATTERING_STEPS,
        true,
        false
    );
    store_storage_texture(root.output_texture, ivec2(texel), vec4(scattering.luminance, 1.0));
}
