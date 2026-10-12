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

// In-scatter of the froxel's volumetric lights other than the sun, by the sun's phase.
vec3 additional_light_scattering(
    FrameRoot frame,
    SkyFogGpu sky,
    uint sun_light,
    vec3 position,
    vec3 direction,
    float view_depth
) {
    LightList lights = select_lights(frame, position, view_depth);
    vec3 scattered = vec3(0.0);
    for (uint slot = 0u; slot < lights.count; slot++) {
        uint index = selected_light_index(frame, lights, slot);
        if (index + 1u == sun_light) continue;

        LightGpu light = LightArray(frame.lights).values[index];
        if ((light.flags & LIGHT_VOLUMETRIC) == 0u) continue;

        LightSample light_sample = sample_light(light, position);
        if (light_sample.radiance == vec3(0.0)) continue;

        float visibility = 1.0;
        // A froxel has no surface: a zero normal keeps ShadowGpu normal biases out of the sample point.
        if (light_casts_shadow(light)) visibility = shadow_visibility(frame, light, position, vec3(0.0), view_depth);
        float phase = fog_phase(dot(direction, light_sample.direction), sky.fog_anisotropy);
        scattered += phase * light_sample.radiance * visibility;
    }
    return sky.fog_albedo_density.rgb * scattered;
}

// The previous frame's in-scatter at a world position, in this frame's exposure; w is 0 outside the previous volume.
vec4 fog_history(FogVolumeRoot root, SkyFogGpu sky, vec3 position) {
    vec4 clip = root.previous_view_proj * vec4(position, 1.0);
    if (clip.w <= 0.0) return vec4(0.0);

    vec2 ndc = clip.xy / clip.w;
    vec2 uv = vec2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    float slices = float(root.slices);
    float slice = sqrt(length(position - root.previous_camera_position.xyz) / sky.fog_max_distance) * slices;
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0))) || slice >= slices) return vec4(0.0);

    vec3 history = sample_texture_3d(root.history, sky.lut_sampler, vec3(uv, slice / slices)).rgb;
    return vec4(history * root.pre_exposure_ratio, 1.0);
}

// The light a froxel scatters toward the camera at its sample depth, and the fog's optical depth over its slice.
vec3 slice_inscatter(
    FogVolumeRoot root,
    FrameRoot frame,
    SkyFogGpu sky,
    bool temporal,
    vec3 origin,
    vec3 direction,
    uint slice,
    out float optical_depth
) {
    float near = fog_slice_distance(sky, slice);
    float far = fog_slice_distance(sky, slice + 1u);
    float start = clamp(fog_clip_start(frame, origin, direction), near, far);
    optical_depth = height_fog_optical_depth(sky, origin + direction * start, direction, far - start);

    float sample_distance = temporal ? mix(start, far, root.jitter) : 0.5 * (start + far);
    vec3 position = origin + direction * sample_distance;
    float view_depth = -(frame.view * vec4(position, 1.0)).z;
    vec3 radiance = fog_ambient_color(frame, sky, direction);
    if (root.sun_light != 0u) {
        LightGpu sun = LightArray(frame.lights).values[root.sun_light - 1u];
        // A froxel has no surface: a zero normal keeps ShadowGpu.normal_bias out of the sample point.
        float visibility = shadow_visibility(frame, sun, position, vec3(0.0), view_depth);
        float phase = fog_phase(-dot(direction, sun.direction_cos_outer.xyz), sky.fog_anisotropy);
        radiance += sky.fog_albedo_density.rgb * phase * sun.color_intensity.rgb * sun.color_intensity.w * visibility;
    }
    return radiance + additional_light_scattering(frame, sky, root.sun_light, position, direction, view_depth);
}

// One column over a chunk of slices. With history, each froxel's reprojected history is clamped to the range of
// its own in-scatter and its depth neighbours', then blended; the slices just outside the chunk are read, not written.
void main() {
    FogVolumeRoot root = FogVolumeRoot(pc.root_gpu);
    uvec2 column = gl_GlobalInvocationID.xy;
    if (column.x >= root.width || column.y >= root.height) return;

    FrameRoot frame = FrameRoot(root.frame);
    SkyFogGpu sky = SkyFogGpu(frame.sky_fog);
    // An orthographic view has no camera position to measure the previous distance from.
    bool temporal = (root.flags & FOG_VOLUME_JITTER) != 0u && frame.proj[3][3] == 0.0;
    bool reproject = temporal && (root.flags & FOG_VOLUME_HISTORY) != 0u;
    vec2 uv = (vec2(column) + 0.5) / vec2(root.width, root.height);
    vec3 origin;
    vec3 direction;
    fog_pixel_ray(frame, uv, origin, direction);

    uint first = gl_GlobalInvocationID.z * root.slice_chunk;
    uint end = first + root.slice_chunk;
    float optical_depth;
    vec3 radiance = slice_inscatter(root, frame, sky, temporal, origin, direction, first, optical_depth);
    vec3 below = radiance;
    if (reproject && first > 0u) {
        float unused;
        below = slice_inscatter(root, frame, sky, temporal, origin, direction, first - 1u, unused);
    }
    for (uint slice = first; slice < end; slice++) {
        vec3 above = radiance;
        float above_depth = optical_depth;
        if (slice + 1u < end || (reproject && slice + 1u < root.slices)) {
            above = slice_inscatter(root, frame, sky, temporal, origin, direction, slice + 1u, above_depth);
        }

        vec3 scattered = radiance;
        if (reproject) {
            // The grid centre, not the jittered sample, so a still camera reads the texel it wrote.
            float share = (float(slice) + 0.5) / float(root.slices);
            vec4 history = fog_history(root, sky, origin + direction * (share * share * sky.fog_max_distance));
            vec3 clamped = clamp(history.rgb, min(below, min(radiance, above)), max(below, max(radiance, above)));
            scattered = mix(radiance, clamped, FOG_HISTORY_WEIGHT * history.a);
        }
        store_storage_texture_3d(root.scattering, ivec3(column, slice), vec4(scattered, optical_depth));

        below = radiance;
        radiance = above;
        optical_depth = above_depth;
    }
}
