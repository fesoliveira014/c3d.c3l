#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "shadows.glsl"
#include "fog.glsl"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Henyey-Greenstein: the share of the sun's light scattered through an angle, per steradian.
float fog_phase(float cos_angle, float anisotropy) {
    float squared = anisotropy * anisotropy;
    float denominator = 1.0 + squared - 2.0 * anisotropy * cos_angle;
    return (1.0 - squared) / (4.0 * PI * denominator * sqrt(denominator));
}

// One froxel: the fog's optical depth over its slice and the light it scatters toward the camera per unit of it.
void main() {
    FogVolumeRoot root = FogVolumeRoot(pc.root_gpu);
    uvec3 froxel = gl_GlobalInvocationID;
    if (froxel.x >= root.width || froxel.y >= root.height) return;

    FrameRoot frame = FrameRoot(root.frame);
    SkyFogGpu sky = SkyFogGpu(frame.sky_fog);
    vec2 uv = (vec2(froxel.xy) + 0.5) / vec2(root.width, root.height);
    vec3 origin;
    vec3 direction;
    fog_pixel_ray(frame, uv, origin, direction);
    float near = fog_slice_distance(sky, froxel.z);
    float far = fog_slice_distance(sky, froxel.z + 1u);
    float start = clamp(fog_clip_start(frame, origin, direction), near, far);
    float optical_depth = height_fog_optical_depth(sky, origin + direction * start, direction, far - start);

    vec3 radiance = fog_ambient_color(frame, sky, direction);
    if (root.sun_light != 0u) {
        LightGpu sun = LightArray(frame.lights).values[root.sun_light - 1u];
        vec3 position = origin + direction * (0.5 * (start + far));
        float view_depth = -(frame.view * vec4(position, 1.0)).z;
        // A froxel has no surface: a zero normal keeps ShadowGpu.normal_bias out of the sample point.
        float visibility = shadow_visibility(frame, sun, position, vec3(0.0), view_depth);
        float phase = fog_phase(-dot(direction, sun.direction_cos_outer.xyz), sky.fog_anisotropy);
        radiance += sky.fog_albedo_density.rgb * phase * sun.color_intensity.rgb * sun.color_intensity.w * visibility;
    }
    store_storage_texture_3d(root.volume, ivec3(froxel), vec4(radiance, optical_depth));
}
