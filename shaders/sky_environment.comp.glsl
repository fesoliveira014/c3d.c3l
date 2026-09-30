#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "atmosphere.glsl"
#include "cube_direction.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// One face of the lighting cube: the sky from the observer altitude, coloured by the sun, without its disc.
void main() {
    SkyTableRoot root = SkyTableRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;

    SkyFogGpu sky = SkyFogGpu(root.sky_fog);
    vec2 uv = (vec2(texel) + 0.5) / float(root.width);
    vec3 direction = environment_cube_direction(root.face, uv);
    SkyScattering scattering = integrate_sky_scattering(
        sky,
        sky.camera_altitude,
        direction,
        sky.sun_direction_cos_radius.xyz,
        -1.0,
        SKY_SCATTERING_STEPS,
        true,
        false
    );
    store_storage_texture(root.output_texture, ivec2(texel), vec4(scattering.luminance * sky.sun_illuminance.rgb, 1.0));
}
