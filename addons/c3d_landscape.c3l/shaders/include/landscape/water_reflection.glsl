#ifndef LANDSCAPE_WATER_REFLECTION_GLSL
#define LANDSCAPE_WATER_REFLECTION_GLSL

#include "descriptor_heap.glsl"
#include "texture_fetch.glsl"
#include "gbuffer.glsl"
#include "material_uv.glsl"
#include "scene_snapshot.glsl"
#include "landscape/water_waves.glsl"

const uint WATER_REFLECTION_SLOT = 0u; // mirrored as REFLECTION_SLOT in water/material.c3
const uint WATER_MARCH_STEPS = 24u; // a depth fetch each per pixel the mirror misses; fewer leave gaps in thin objects
const float WATER_MARCH_REACH = 4.0; // ray length over the pixel's view distance; longer spreads the same steps thinner
const float WATER_MARCH_THICKNESS = 2.0; // steps behind a snapshot surface that still count as a hit
const float WATER_PLANAR_OFFSET_LIMIT = 0.05; // largest screen-uv shift of the planar sample; more smears the mirror

// The three lines of trace_miss_radiance (ibl.glsl), which is not a public part: the lighting environment's
// specular cube at mip 0, else the frame's ambient.
vec3 water_miss_radiance(FrameRoot frame, vec3 direction) {
    if (frame.environment == 0ul) return frame.ambient.rgb;
    EnvironmentGpu environment = EnvironmentGpu(frame.environment);
    vec3 rotated = vec3(
        dot(environment.rotation.row0.xyz, direction),
        dot(environment.rotation.row1.xyz, direction),
        dot(environment.rotation.row2.xyz, direction)
    );
    return sample_texture_cube_lod(environment.specular_cube, environment.sampler_index, rotated, 0.0).rgb
        * environment.intensity;
}

bool water_inside_frame(vec2 uv) {
    return all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)));
}

// Per pixel: the offset sample must stay inside the mirror's frame. Explicit lod: the branch is not uniform.
bool water_planar(CustomMaterialGpu material, vec2 screen_uv, vec2 screen_tilt, float distortion, out vec3 radiance) {
    vec2 offset = clamp(screen_tilt * distortion, vec2(-WATER_PLANAR_OFFSET_LIMIT), vec2(WATER_PLANAR_OFFSET_LIMIT));
    vec2 uv = screen_uv + offset;
    if (!water_inside_frame(uv)) return false;
    TextureMapGpu map = material.slots[WATER_REFLECTION_SLOT];
    radiance = sample_texture_2d_lod(map.texture_index, map.sampler_index, uv, 0.0).rgb;
    return true;
}

// The snapshot holds opaque, masked and sky only, from this view: blends, off-screen geometry and anything behind
// the camera are never hit. Explicit-lod reads only: hits differ per pixel.
bool water_march(FrameRoot frame, vec3 origin, vec3 direction, out vec3 radiance) {
    float reach = WATER_MARCH_REACH * -(frame.view * vec4(origin, 1.0)).z;
    for (uint march_step = 1u; march_step <= WATER_MARCH_STEPS; march_step++) {
        // Quadratic spacing: fine steps near the surface, where contact reflections need them.
        float share = float(march_step) / float(WATER_MARCH_STEPS);
        float step_length = reach * (2.0 * share - 1.0 / float(WATER_MARCH_STEPS)) / float(WATER_MARCH_STEPS);
        vec3 point = origin + direction * (reach * share * share);
        vec4 clip = frame.view_proj * vec4(point, 1.0);
        if (clip.w <= 0.0) return false;
        vec2 uv = vec2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
        if (!water_inside_frame(uv)) return false;
        float depth = scene_depth_at(frame, uv);
        float behind = -(frame.view * vec4(point, 1.0)).z - view_distance(frame, depth);
        if (depth > 0.0 && behind > 0.0 && behind < WATER_MARCH_THICKNESS * step_length) {
            radiance = sample_texture_2d_lod(frame.scene_color, frame.scene_sampler, uv, 0.0).rgb;
            return true;
        }
    }
    return false;
}

// Planar where the slot is present (uniform per draw) and the sample stays in frame (per pixel); else the march
// where the material enables it (uniform) and it hits (per pixel); else the environment or ambient.
vec3 water_reflection(
    FrameRoot frame,
    CustomMaterialGpu material,
    WaterParams params,
    vec3 position,
    vec3 reflected,
    vec2 screen_uv,
    vec2 screen_tilt
) {
    vec3 radiance;
    if (custom_slot_present(material, WATER_REFLECTION_SLOT)
        && water_planar(material, screen_uv, screen_tilt, params.reflection_distortion, radiance)) {
        return radiance;
    }
    if ((params.flags & WATER_MARCH) != 0u && water_march(frame, position, reflected, radiance)) return radiance;
    return water_miss_radiance(frame, reflected);
}

#endif
