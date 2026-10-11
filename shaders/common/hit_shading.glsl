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
#include "hit_material.glsl"

// Raster atlas layers are fitted to the camera, so every shadowing light traces at a hit.
float hit_light_visibility(FrameRoot frame, LightGpu light, TraceSurface surface) {
    if (!light_casts_shadow(light)) return 1.0;
    return ray_shadow_visibility(frame, light, surface.position, surface.geometric_normal);
}

vec3 hit_environment_diffuse(FrameRoot frame, vec3 albedo, TraceSurface surface, vec3 view_direction) {
    return albedo / PI * indirect_diffuse_irradiance(frame, surface.position, surface.normal, view_direction);
}

vec3 shade_standard_hit(FrameRoot frame, TraceSurface surface, vec3 view_direction) {
    StandardSurface standard = prepare_standard_surface(
        surface.albedo,
        surface.metallic,
        surface.roughness,
        surface.normal,
        view_direction
    );
    vec3 color = surface.emissive + frame.ambient.rgb * surface.albedo * (1.0 - surface.metallic) * surface.occlusion;
    for (uint index = 0u; index < frame.light_count; index++) {
        LightGpu light = LightArray(frame.lights).values[index];
        if ((surface.receiver_layers & light.layers) == 0u) continue;
        LightSample light_sample = sample_light(light, surface.position);
        if (dot(surface.normal, light_sample.direction) <= 0.0 || light_sample.radiance == vec3(0.0)) continue;
        color += evaluate_standard_brdf(standard, light_sample.direction) * light_sample.radiance
            * hit_light_visibility(frame, light, surface);
    }
    if (frame_has_indirect(frame)) {
        color += evaluate_environment(frame, surface.position, standard, surface.roughness, surface.occlusion, 1.0);
    }
    return color;
}

vec3 shade_physical_hit(FrameRoot frame, TraceSurface hit, vec3 view_direction) {
    PhysicalSurface surface = prepare_physical_hit_surface(hit, view_direction, frame.sheen_lut, frame.sheen_sampler);
    ReflectionSelection reflections = reflection_probe_select(frame, hit.position);
    vec3 transmitted = physical_hit_transmitted_radiance(frame, reflections, hit, surface);
    vec3 ambient = frame.ambient.rgb * hit.albedo * (1.0 - hit.metallic) * hit.occlusion;
    vec3 base_fill = (1.0 - surface.transmission) * ambient + surface.transmission * transmitted;
    vec3 color;
    if (surface.coat_weight == 0.0 && surface.sheen_strength == 0.0) {
        color = base_fill + hit.emissive;
    } else {
        color = (1.0 - surface.coat_weight) * (base_fill * physical_sheen_attenuation(surface) + hit.emissive);
    }

    if (frame_has_indirect(frame)) {
        color += evaluate_physical_environment(
            frame,
            reflections,
            hit.position,
            surface,
            hit.roughness,
            hit.occlusion,
            1.0
        );
    }

    for (uint index = 0u; index < frame.light_count; index++) {
        LightGpu light = LightArray(frame.lights).values[index];
        if ((hit.receiver_layers & light.layers) == 0u) continue;

        color += hit_light_visibility(frame, light, hit) * evaluate_physical_light(
            light,
            hit.position,
            surface,
            frame.sheen_lut,
            frame.sheen_sampler
        );
    }

    return color;
}

vec3 shade_toon_hit(FrameRoot frame, TraceSurface surface, vec3 view_direction) {
    ToonMaterialGpu material = ToonMaterialGpu(surface.material);
    vec3 color = frame.ambient.rgb * surface.albedo
        + hit_environment_diffuse(frame, surface.albedo, surface, view_direction);
    for (uint index = 0u; index < frame.light_count; index++) {
        LightGpu light = LightArray(frame.lights).values[index];
        if ((surface.receiver_layers & light.layers) == 0u) continue;
        LightSample light_sample = sample_light(light, surface.position);
        float normal_light = dot(surface.normal, light_sample.direction);
        if (normal_light <= 0.0 || light_sample.radiance == vec3(0.0)) continue;
        color += surface.albedo / PI * toon_response(material, normal_light) * light_sample.radiance
            * hit_light_visibility(frame, light, surface);
    }
    return color + toon_rim(material, surface.normal, view_direction);
}

vec3 shade_lambert_hit(FrameRoot frame, TraceSurface surface, vec3 view_direction) {
    vec3 color = frame.ambient.rgb * surface.albedo
        + hit_environment_diffuse(frame, surface.albedo, surface, view_direction);
    for (uint index = 0u; index < frame.light_count; index++) {
        LightGpu light = LightArray(frame.lights).values[index];
        if ((surface.receiver_layers & light.layers) == 0u) continue;
        LightSample light_sample = sample_light(light, surface.position);
        float normal_light = dot(surface.normal, light_sample.direction);
        if (normal_light <= 0.0 || light_sample.radiance == vec3(0.0)) continue;
        color += surface.albedo / PI * normal_light * light_sample.radiance
            * hit_light_visibility(frame, light, surface);
    }
    return color;
}

vec3 shade_hit(FrameRoot frame, TraceSurface surface, vec3 view_direction) {
    switch (surface.material_kind) {
        case MATERIAL_KIND_BASIC:
            return surface.albedo;
        case MATERIAL_KIND_STANDARD:
            return shade_standard_hit(frame, surface, view_direction);
        case MATERIAL_KIND_PHYSICAL:
            return shade_physical_hit(frame, surface, view_direction);
        case MATERIAL_KIND_TOON:
            return shade_toon_hit(frame, surface, view_direction);
        default:
            return shade_lambert_hit(frame, surface, view_direction);
    }
}

#endif
