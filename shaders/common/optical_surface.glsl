#ifndef C3D_OPTICAL_SURFACE_GLSL
#define C3D_OPTICAL_SURFACE_GLSL

#include "descriptor_heap.glsl"
#include "texture_fetch.glsl"
#include "material_uv.glsl"
#include "brdf.glsl"

struct OpticalSurface {
    vec4 base_coverage;
    vec3 normal;
    float metallic;
    float transmission;
    float thickness;
    float ior;
    vec3 specular_color;
    float specular_weight;
    vec3 attenuation_color;
    float attenuation_distance;
    uint flags;
};

vec4 optical_map(TextureMapGpu map, uint flags, uint bit, vec2 uv0, vec2 uv1) {
    return sample_texture_2d_lod(map.texture_index, map.sampler_index, map_uv(map, flags, bit, uv0, uv1), 0.0);
}

// Raster and hit adapters supply the same mapped base, metallic and light-facing normal.
OpticalSurface optical_surface(
    PhysicalMaterialGpu material,
    vec4 base,
    float metallic,
    vec3 normal,
    vec2 uv0,
    vec2 uv1
) {
    OpticalSurface surface;
    surface.base_coverage = base;
    surface.normal = normal;
    surface.metallic = metallic;
    surface.transmission = material.transmission;
    surface.thickness = material.thickness;
    surface.ior = material.ior;
    surface.specular_color = material.specular_color_weight.rgb;
    surface.specular_weight = material.specular_color_weight.w;
    surface.attenuation_color = material.attenuation_color_distance.rgb;
    surface.attenuation_distance = material.attenuation_color_distance.w;
    surface.flags = material.standard.flags;

    if ((material.extension_map_flags & PHYSICAL_EXTENSION_MAP_TRANSMISSION) != 0u) {
        surface.transmission = clamp(surface.transmission * optical_map(
            material.transmission_map, material.extension_map_flags, PHYSICAL_EXTENSION_MAP_TRANSMISSION, uv0, uv1
        ).r, 0.0, 1.0);
    }
    if ((material.extension_map_flags & PHYSICAL_EXTENSION_MAP_THICKNESS) != 0u) {
        surface.thickness = max(surface.thickness * optical_map(
            material.thickness_map, material.extension_map_flags, PHYSICAL_EXTENSION_MAP_THICKNESS, uv0, uv1
        ).g, 0.0);
    }
    if (surface.specular_weight > 0.0) {
        if ((material.extension_map_flags & PHYSICAL_EXTENSION_MAP_SPECULAR) != 0u) {
            surface.specular_weight = clamp(surface.specular_weight * optical_map(
                material.specular_map, material.extension_map_flags, PHYSICAL_EXTENSION_MAP_SPECULAR, uv0, uv1
            ).a, 0.0, 1.0);
        }
        if ((material.extension_map_flags & PHYSICAL_EXTENSION_MAP_SPECULAR_COLOR) != 0u) {
            surface.specular_color *= optical_map(
                material.specular_color_map, material.extension_map_flags, PHYSICAL_EXTENSION_MAP_SPECULAR_COLOR, uv0, uv1
            ).rgb;
        }
    }

    return surface;
}

vec3 optical_surface_throughput(OpticalSurface surface, vec3 to_light, vec3 model_scale) {
    float cosine = clamp(dot(surface.normal, to_light), 0.0, 1.0);
    float ratio = (surface.ior - 1.0) / (surface.ior + 1.0);
    vec3 reflectance = min(vec3(ratio * ratio) * surface.specular_color, vec3(1.0)) * surface.specular_weight;
    vec3 fresnel = fresnel_schlick(reflectance, vec3(surface.specular_weight), cosine);
    vec3 refracted = refract(-to_light, surface.normal, 1.0 / surface.ior);
    vec3 ray = normalize(refracted) * surface.thickness * model_scale;
    vec3 attenuation = surface.attenuation_distance == 0.0 || surface.thickness == 0.0
        ? vec3(1.0)
        : pow(surface.attenuation_color, vec3(length(ray) / surface.attenuation_distance));
    vec3 transmitted = surface.transmission * (1.0 - surface.metallic) * surface.base_coverage.rgb
        * (1.0 - fresnel) * attenuation;
    float coverage = (surface.flags & MATERIAL_ALPHA_BLEND) != 0u ? surface.base_coverage.a : 1.0;

    // Limit only the completed per-face result; HDR inputs can have an in-range product.
    return clamp(vec3(1.0 - coverage) + coverage * transmitted, vec3(0.0), vec3(1.0));
}

#endif
