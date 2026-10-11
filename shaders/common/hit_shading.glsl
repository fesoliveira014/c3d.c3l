#ifndef C3D_HIT_SHADING_GLSL
#define C3D_HIT_SHADING_GLSL

#ifndef RT_SHADOWS
#error "define RT_SHADOWS before including hit_shading.glsl"
#endif

#include "constants.glsl"
#include "brdf.glsl"
#include "lights.glsl"
#include "ibl.glsl"
#include "toon.glsl"
#include "scene_trace.glsl"
#include "shadows.glsl"

struct HitLights {
    uint64_t address;
    uint count;
};

HitLights frame_hit_lights(FrameRoot frame) {
    return HitLights(frame.lights, frame.light_count);
}

// Raster atlas layers are fitted to the camera, so every shadowing light traces at a hit.
float hit_light_visibility(FrameRoot frame, LightGpu light, TraceSurface surface) {
    if (!light_casts_shadow(light)) return 1.0;
    return ray_shadow_visibility(frame, light, surface.position, surface.geometric_normal);
}

vec3 hit_environment_diffuse(FrameRoot frame, vec3 albedo, TraceSurface surface, vec3 view_direction) {
    return albedo / PI * indirect_diffuse_irradiance(frame, surface.position, surface.normal, view_direction);
}

vec3 hit_lambert_direct(FrameRoot frame, HitLights lights, TraceSurface surface, vec3 albedo) {
    vec3 radiance = vec3(0.0);
    for (uint index = 0u; index < lights.count; index++) {
        LightGpu light = LightArray(lights.address).values[index];
        if ((light.layers & surface.layers) == 0u) continue;

        LightSample light_sample = sample_light(light, surface.position);
        float normal_light = dot(surface.normal, light_sample.direction);
        if (normal_light <= 0.0 || light_sample.radiance == vec3(0.0)) continue;
        radiance += normal_light * light_sample.radiance * hit_light_visibility(frame, light, surface);
    }
    return radiance * albedo / PI;
}

vec3 hit_toon_direct(FrameRoot frame, HitLights lights, TraceSurface surface) {
    ToonMaterialGpu material = ToonMaterialGpu(surface.material);
    vec3 radiance = vec3(0.0);
    for (uint index = 0u; index < lights.count; index++) {
        LightGpu light = LightArray(lights.address).values[index];
        if ((light.layers & surface.layers) == 0u) continue;

        LightSample light_sample = sample_light(light, surface.position);
        float normal_light = dot(surface.normal, light_sample.direction);
        if (normal_light <= 0.0 || light_sample.radiance == vec3(0.0)) continue;
        radiance += toon_response(material, normal_light) * light_sample.radiance
            * hit_light_visibility(frame, light, surface);
    }
    return radiance * surface.albedo / PI;
}

vec3 shade_standard_hit(FrameRoot frame, HitLights lights, TraceSurface surface, vec3 view_direction) {
    StandardSurface standard = prepare_standard_surface(
        surface.albedo,
        surface.metallic,
        surface.roughness,
        surface.normal,
        view_direction
    );
    vec3 color = surface.emissive + frame.ambient.rgb * surface.albedo * (1.0 - surface.metallic);
    for (uint index = 0u; index < lights.count; index++) {
        LightGpu light = LightArray(lights.address).values[index];
        if ((light.layers & surface.layers) == 0u) continue;

        LightSample light_sample = sample_light(light, surface.position);
        if (dot(surface.normal, light_sample.direction) <= 0.0 || light_sample.radiance == vec3(0.0)) continue;
        color += evaluate_standard_brdf(standard, light_sample.direction) * light_sample.radiance
            * hit_light_visibility(frame, light, surface);
    }
    if (frame_has_indirect(frame)) {
        color += evaluate_environment(frame, surface.position, standard, surface.roughness, 1.0, 1.0);
    }
    return color;
}

vec3 shade_toon_hit(FrameRoot frame, HitLights lights, TraceSurface surface, vec3 view_direction) {
    ToonMaterialGpu material = ToonMaterialGpu(surface.material);
    return frame.ambient.rgb * surface.albedo
        + hit_environment_diffuse(frame, surface.albedo, surface, view_direction)
        + hit_toon_direct(frame, lights, surface)
        + toon_rim(material, surface.normal, view_direction);
}

vec3 shade_lambert_hit(FrameRoot frame, HitLights lights, TraceSurface surface, vec3 view_direction) {
    return frame.ambient.rgb * surface.albedo
        + hit_environment_diffuse(frame, surface.albedo, surface, view_direction)
        + hit_lambert_direct(frame, lights, surface, surface.albedo);
}

// Receiver layers gate each light; ambient and emissive are unmasked.
vec3 shade_hit(FrameRoot frame, HitLights lights, TraceSurface surface, vec3 view_direction) {
    switch (surface.material_kind) {
        case MATERIAL_KIND_BASIC:
            return surface.albedo;
        case MATERIAL_KIND_STANDARD:
        case MATERIAL_KIND_PHYSICAL:
            return shade_standard_hit(frame, lights, surface, view_direction);
        case MATERIAL_KIND_TOON:
            return shade_toon_hit(frame, lights, surface, view_direction);
        default:
            return shade_lambert_hit(frame, lights, surface, view_direction);
    }
}

// The diffuse terms of shade_hit for consumers that accumulate irradiance: no specular, ambient fill or rim.
vec3 shade_hit_diffuse(FrameRoot frame, HitLights lights, TraceSurface surface, vec3 view_direction) {
    switch (surface.material_kind) {
        case MATERIAL_KIND_BASIC:
            return surface.albedo;
        case MATERIAL_KIND_STANDARD:
        case MATERIAL_KIND_PHYSICAL:
            vec3 diffuse_albedo = surface.albedo * (1.0 - surface.metallic);
            return surface.emissive
                + hit_environment_diffuse(frame, diffuse_albedo, surface, view_direction)
                + hit_lambert_direct(frame, lights, surface, diffuse_albedo);
        case MATERIAL_KIND_TOON:
            return hit_environment_diffuse(frame, surface.albedo, surface, view_direction)
                + hit_toon_direct(frame, lights, surface);
        default:
            return hit_environment_diffuse(frame, surface.albedo, surface, view_direction)
                + hit_lambert_direct(frame, lights, surface, surface.albedo);
    }
}

#endif
