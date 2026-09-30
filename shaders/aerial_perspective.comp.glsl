#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "fog.glsl"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 4) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// One froxel: in-scattering and opacity from the camera to its slice, slices squared toward the camera.
void main() {
    SkyTableRoot root = SkyTableRoot(pc.root_gpu);
    uvec3 texel = gl_GlobalInvocationID;
    if (any(greaterThanEqual(texel, uvec3(AERIAL_PERSPECTIVE_SIZE)))) return;

    SkyFogGpu sky = SkyFogGpu(root.sky_fog);
    FrameRoot frame = FrameRoot(root.frame);
    vec2 uv = (vec2(texel.xy) + 0.5) / float(AERIAL_PERSPECTIVE_SIZE);
    vec3 origin;
    vec3 direction;
    fog_pixel_ray(frame, uv, origin, direction);
    float slice = (float(texel.z) + 0.5) / float(AERIAL_PERSPECTIVE_SIZE);
    float distance = slice * slice * sky.aerial_perspective_distance;
    SkyScattering scattering = integrate_sky_scattering(
        sky,
        sky.camera_altitude,
        direction,
        sky.sun_direction_cos_radius.xyz,
        distance,
        (texel.z + 1u) * AERIAL_PERSPECTIVE_STEPS_PER_SLICE,
        false,
        false
    );
    float opacity = 1.0 - dot(scattering.transmittance, vec3(1.0 / 3.0));
    store_storage_texture_3d(root.output_texture, ivec3(texel), vec4(scattering.luminance, opacity));
}
