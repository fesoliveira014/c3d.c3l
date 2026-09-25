#ifndef C3D_HIT_SHADING_GLSL
#define C3D_HIT_SHADING_GLSL

#if !defined(SCENE_TRACE_RAY_QUERY) || !defined(RT_SHADOWS)
#error "define SCENE_TRACE_RAY_QUERY and RT_SHADOWS before including hit_shading.glsl"
#endif

#include "constants.glsl"
#include "brdf.glsl"
#include "lights.glsl"
#include "ibl.glsl"
#include "toon.glsl"
#include "scene_trace.glsl"
#include "shadows.glsl"

// Radiance along a ray that leaves the scene: the lighting environment, not the background cube.
vec3 trace_miss_radiance(FrameRoot frame, vec3 direction) {
    if (frame.environment == 0ul) return frame.ambient.rgb;
    EnvironmentGpu environment = EnvironmentGpu(frame.environment);
    return sample_texture_cube_lod(
        environment.specular_cube,
        environment.sampler_index,
        environment_rotate(environment.rotation, direction),
        0.0
    ).rgb * environment.intensity;
}

// Raster atlas layers are fitted to the camera, so every shadowing light traces at a hit.
float hit_light_visibility(FrameRoot frame, LightGpu light, TraceSurface surface) {
    if (!light_casts_shadow(light)) return 1.0;
    return ray_shadow_visibility(frame, light, surface.position, surface.geometric_normal);
}

vec3 hit_environment_diffuse(FrameRoot frame, vec3 albedo, vec3 normal) {
    if (frame.environment == 0ul) return vec3(0.0);
    EnvironmentGpu environment = EnvironmentGpu(frame.environment);
    vec3 irradiance = environment_irradiance(environment.sh, environment_rotate(environment.rotation, normal));
    return albedo / PI * irradiance * environment.intensity;
}

vec3 shade_standard_hit(FrameRoot frame, TraceSurface surface, vec3 view_direction) {
    StandardSurface standard = prepare_standard_surface(
        surface.albedo,
        surface.metallic,
        surface.roughness,
        surface.normal,
        view_direction
    );
    vec3 color = surface.emissive + frame.ambient.rgb * surface.albedo * (1.0 - surface.metallic);
    for (uint index = 0u; index < frame.light_count; index++) {
        LightGpu light = LightArray(frame.lights).values[index];
        LightSample light_sample = sample_light(light, surface.position);
        if (dot(surface.normal, light_sample.direction) <= 0.0 || light_sample.radiance == vec3(0.0)) continue;
        color += evaluate_standard_brdf(standard, light_sample.direction) * light_sample.radiance
            * hit_light_visibility(frame, light, surface);
    }
    if (frame.environment != 0ul) {
        EnvironmentGpu environment = EnvironmentGpu(frame.environment);
        color += evaluate_environment(environment, standard, surface.roughness, 1.0, 1.0);
    }
    return color;
}

vec3 shade_toon_hit(FrameRoot frame, TraceSurface surface, vec3 view_direction) {
    ToonMaterialGpu material = ToonMaterialGpu(surface.material);
    vec3 color = frame.ambient.rgb * surface.albedo + hit_environment_diffuse(frame, surface.albedo, surface.normal);
    for (uint index = 0u; index < frame.light_count; index++) {
        LightGpu light = LightArray(frame.lights).values[index];
        LightSample light_sample = sample_light(light, surface.position);
        float normal_light = dot(surface.normal, light_sample.direction);
        if (normal_light <= 0.0 || light_sample.radiance == vec3(0.0)) continue;
        color += surface.albedo / PI * toon_response(material, normal_light) * light_sample.radiance
            * hit_light_visibility(frame, light, surface);
    }
    return color + toon_rim(material, surface.normal, view_direction);
}

vec3 shade_lambert_hit(FrameRoot frame, TraceSurface surface) {
    vec3 color = frame.ambient.rgb * surface.albedo + hit_environment_diffuse(frame, surface.albedo, surface.normal);
    for (uint index = 0u; index < frame.light_count; index++) {
        LightGpu light = LightArray(frame.lights).values[index];
        LightSample light_sample = sample_light(light, surface.position);
        float normal_light = dot(surface.normal, light_sample.direction);
        if (normal_light <= 0.0 || light_sample.radiance == vec3(0.0)) continue;
        color += surface.albedo / PI * normal_light * light_sample.radiance
            * hit_light_visibility(frame, light, surface);
    }
    return color;
}

// Light layers are not applied: trace rows carry none.
vec3 shade_hit(FrameRoot frame, TraceSurface surface, vec3 view_direction) {
    if (surface.back_face) return vec3(0.0);
    switch (surface.material_kind) {
        case MATERIAL_KIND_BASIC:
            return surface.albedo;
        case MATERIAL_KIND_STANDARD:
        case MATERIAL_KIND_PHYSICAL:
            return shade_standard_hit(frame, surface, view_direction);
        case MATERIAL_KIND_TOON:
            return shade_toon_hit(frame, surface, view_direction);
        default:
            return shade_lambert_hit(frame, surface);
    }
}

#endif
