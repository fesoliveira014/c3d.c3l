#ifndef C3D_HIT_MATERIAL_GLSL
#define C3D_HIT_MATERIAL_GLSL

#include "trace_surface.glsl"
#include "physical.glsl"

vec4 sample_physical_hit_map(TextureMapGpu map, uint flags, uint bit, TraceMaterialContext context) {
    return sample_hit_map_lod(map, flags, bit, context.uv0, context.uv1, context.footprint);
}

vec2 hit_material_corner_uv(
    TextureMapGpu map,
    uint flags,
    uint bit,
    TraceMaterialContext context,
    vec3 corner
) {
    GeometryRoot geometry = GeometryRoot(context.geometry);
    return map_uv(
        map,
        flags,
        bit,
        hit_uv(geometry.uv0, context.corners, corner),
        hit_uv(geometry.uv1, context.corners, corner)
    );
}

vec4 hit_material_derivative_tangent(TextureMapGpu map, uint flags, uint bit, TraceMaterialContext context) {
    vec2 first = hit_material_corner_uv(map, flags, bit, context, vec3(1.0, 0.0, 0.0));
    vec2 second = hit_material_corner_uv(map, flags, bit, context, vec3(0.0, 1.0, 0.0));
    vec2 third = hit_material_corner_uv(map, flags, bit, context, vec3(0.0, 0.0, 1.0));

    return derivative_tangent(
        normalize(context.vertex_normal),
        context.world_edge_1,
        context.world_edge_2,
        second - first,
        third - first
    );
}

vec3 hit_material_normal(
    TextureMapGpu map,
    uint flags,
    uint bit,
    uint encoding_bit,
    float scale,
    TraceMaterialContext context
) {
    vec3 mapped = decode_normal(
        sample_physical_hit_map(map, flags, bit, context).rgb,
        scale,
        (flags & encoding_bit) != 0u
    );
    GeometryRoot geometry = GeometryRoot(context.geometry);
    if ((geometry.flags & GEOMETRY_HAS_TANGENTS) != 0u) {
        return tangent_normal(context.vertex_normal, context.tangent, mapped);
    }

    vec2 first = hit_material_corner_uv(map, flags, bit, context, vec3(1.0, 0.0, 0.0));
    vec2 second = hit_material_corner_uv(map, flags, bit, context, vec3(0.0, 1.0, 0.0));
    vec2 third = hit_material_corner_uv(map, flags, bit, context, vec3(0.0, 0.0, 1.0));
    return derivative_normal(
        normalize(context.vertex_normal),
        mapped,
        context.world_edge_1,
        context.world_edge_2,
        second - first,
        third - first
    );
}

PhysicalSurface prepare_physical_hit_surface(
    TraceSurface hit,
    vec3 view_direction,
    uint sheen_lut,
    uint sheen_sampler
) {
    PhysicalMaterialGpu material = PhysicalMaterialGpu(hit.material);
    TraceMaterialContext context = hit.context;
    float clearcoat = material.clearcoat;
    float coat_roughness = material.clearcoat_roughness;
    vec3 coat_normal = normalize(context.vertex_normal);
    if (clearcoat > 0.0) {
        if ((material.map_flags & PHYSICAL_MAP_CLEARCOAT) != 0u) {
            clearcoat = clamp(clearcoat * sample_physical_hit_map(
                material.clearcoat_map,
                material.map_flags,
                PHYSICAL_MAP_CLEARCOAT,
                context
            ).r, 0.0, 1.0);
        }
        if ((material.map_flags & PHYSICAL_MAP_CLEARCOAT_ROUGHNESS) != 0u) {
            coat_roughness = clamp(coat_roughness * sample_physical_hit_map(
                material.clearcoat_roughness_map,
                material.map_flags,
                PHYSICAL_MAP_CLEARCOAT_ROUGHNESS,
                context
            ).g, 0.0, 1.0);
        }
        if ((material.map_flags & PHYSICAL_MAP_CLEARCOAT_NORMAL) != 0u && material.clearcoat_normal_scale != 0.0) {
            coat_normal = hit_material_normal(
                material.clearcoat_normal_map,
                material.map_flags,
                PHYSICAL_MAP_CLEARCOAT_NORMAL,
                PHYSICAL_MAP_CLEARCOAT_NORMAL_RG,
                material.clearcoat_normal_scale,
                context
            );
        }
    }
    if (context.facing_back) coat_normal = -coat_normal;

    vec3 sheen_color = material.sheen_color_roughness.rgb;
    float sheen_roughness = material.sheen_color_roughness.a;
    if (any(greaterThan(sheen_color, vec3(0.0)))) {
        if ((material.map_flags & PHYSICAL_MAP_SHEEN_COLOR) != 0u) {
            sheen_color = clamp(sheen_color * sample_physical_hit_map(
                material.sheen_color_map,
                material.map_flags,
                PHYSICAL_MAP_SHEEN_COLOR,
                context
            ).rgb, 0.0, 1.0);
        }
        if ((material.map_flags & PHYSICAL_MAP_SHEEN_ROUGHNESS) != 0u) {
            sheen_roughness = clamp(sheen_roughness * sample_physical_hit_map(
                material.sheen_roughness_map,
                material.map_flags,
                PHYSICAL_MAP_SHEEN_ROUGHNESS,
                context
            ).a, 0.0, 1.0);
        }
    }

    vec3 specular_color = material.specular_color_weight.rgb;
    float specular_weight = material.specular_color_weight.w;
    if (specular_weight > 0.0) {
        if ((material.extension_map_flags & PHYSICAL_EXTENSION_MAP_SPECULAR) != 0u) {
            specular_weight = clamp(specular_weight * sample_physical_hit_map(
                material.specular_map,
                material.extension_map_flags,
                PHYSICAL_EXTENSION_MAP_SPECULAR,
                context
            ).a, 0.0, 1.0);
        }
        if ((material.extension_map_flags & PHYSICAL_EXTENSION_MAP_SPECULAR_COLOR) != 0u) {
            specular_color *= sample_physical_hit_map(
                material.specular_color_map,
                material.extension_map_flags,
                PHYSICAL_EXTENSION_MAP_SPECULAR_COLOR,
                context
            ).rgb;
        }
    }

    PhysicalSurface surface;
    vec3 dielectric_reflectance = min(dielectric_normal_reflectance(material.ior) * specular_color, vec3(1.0))
        * specular_weight;
    surface.standard = prepare_surface(
        hit.albedo,
        hit.metallic,
        hit.roughness,
        hit.normal,
        view_direction,
        dielectric_reflectance,
        vec3(specular_weight)
    );
    float anisotropy = material.anisotropy;
    if (anisotropy > 0.0) {
        vec2 direction = vec2(cos(material.anisotropy_rotation), sin(material.anisotropy_rotation));
        vec4 tangent = context.tangent;
        GeometryRoot geometry = GeometryRoot(context.geometry);
        if ((material.extension_map_flags & PHYSICAL_EXTENSION_MAP_ANISOTROPY) != 0u) {
            vec3 sampled = sample_physical_hit_map(
                material.anisotropy_map,
                material.extension_map_flags,
                PHYSICAL_EXTENSION_MAP_ANISOTROPY,
                context
            ).rgb;
            direction = mat2(direction.x, direction.y, -direction.y, direction.x) * (sampled.rg * 2.0 - 1.0);
            anisotropy = clamp(anisotropy * sampled.b, 0.0, 1.0);
        }
        if ((geometry.flags & GEOMETRY_HAS_TANGENTS) == 0u) {
            if ((material.extension_map_flags & PHYSICAL_EXTENSION_MAP_ANISOTROPY) != 0u) {
                tangent = hit_material_derivative_tangent(
                    material.anisotropy_map,
                    material.extension_map_flags,
                    PHYSICAL_EXTENSION_MAP_ANISOTROPY,
                    context
                );
            } else {
                tangent = derivative_tangent(
                    normalize(context.vertex_normal),
                    context.world_edge_1,
                    context.world_edge_2,
                    hit_uv(geometry.uv0, context.corners, vec3(0.0, 1.0, 0.0))
                        - hit_uv(geometry.uv0, context.corners, vec3(1.0, 0.0, 0.0)),
                    hit_uv(geometry.uv0, context.corners, vec3(0.0, 0.0, 1.0))
                        - hit_uv(geometry.uv0, context.corners, vec3(1.0, 0.0, 0.0))
                );
            }
        }
        vec3 frame_tangent;
        vec3 frame_bitangent;
        if (surface_tangent_frame(normalize(context.vertex_normal), tangent, frame_tangent, frame_bitangent)) {
            vec3 axis = frame_tangent * direction.x + frame_bitangent * direction.y;
            axis -= surface.standard.normal * dot(surface.standard.normal, axis);
            float length_squared = dot(axis, axis);
            if (length_squared > 0.0) {
                axis *= inversesqrt(length_squared);
                apply_anisotropy(surface.standard, axis, cross(surface.standard.normal, axis), anisotropy);
            }
        }
    }

    surface.coat_normal = coat_normal;
    surface.coat_weight = clearcoat_view_weight(clearcoat, coat_normal, view_direction);
    surface.coat_roughness = coat_roughness;
    surface.sheen_color = sheen_color;
    surface.sheen_roughness = sheen_roughness;
    surface.sheen_strength = max(sheen_color.r, max(sheen_color.g, sheen_color.b));
    surface.sheen_view_albedo = surface.sheen_strength == 0.0
        ? 0.0 : sheen_albedo(sheen_lut, sheen_sampler, surface.standard.normal_view, sheen_roughness);

    surface.transmission = material.transmission;
    float thickness = material.thickness;
    if (surface.transmission > 0.0) {
        if ((material.extension_map_flags & PHYSICAL_EXTENSION_MAP_TRANSMISSION) != 0u) {
            surface.transmission = clamp(surface.transmission * sample_physical_hit_map(
                material.transmission_map,
                material.extension_map_flags,
                PHYSICAL_EXTENSION_MAP_TRANSMISSION,
                context
            ).r, 0.0, 1.0);
        }
        if ((material.extension_map_flags & PHYSICAL_EXTENSION_MAP_THICKNESS) != 0u) {
            thickness = max(thickness * sample_physical_hit_map(
                material.thickness_map,
                material.extension_map_flags,
                PHYSICAL_EXTENSION_MAP_THICKNESS,
                context
            ).g, 0.0);
        }
    }
    surface.ior = material.ior;
    surface.transmission_color = hit.albedo * (1.0 - hit.metallic);
    surface.attenuation_color = material.attenuation_color_distance.rgb;
    surface.attenuation_distance = material.attenuation_color_distance.w;
    surface.transmission_ray = vec3(0.0);
    if (surface.transmission > 0.0) {
        vec3 refracted = refract(-view_direction, hit.normal, 1.0 / surface.ior);
        surface.transmission_ray = normalize(refracted) * thickness * context.model_scale;
    }

    return surface;
}

vec3 physical_hit_transmitted_radiance(
    FrameRoot frame,
    ReflectionSelection reflections,
    TraceSurface hit,
    PhysicalSurface surface
) {
    if (surface.transmission == 0.0 || (frame.environment == 0ul && reflections.count == 0u)) return vec3(0.0);

    vec3 refracted = refract(-surface.standard.view_direction, hit.normal, 1.0 / surface.ior);
    float lod = max(hit.roughness, MIN_PERCEPTUAL_ROUGHNESS) * float(ENVIRONMENT_SPECULAR_MIPS - 1u);
    vec3 radiance = environment_lobe_radiance(frame, reflections, normalize(refracted), lod, ENVIRONMENT_GGX_CUBE);
    radiance = volume_attenuation(
        radiance,
        length(surface.transmission_ray),
        surface.attenuation_color,
        surface.attenuation_distance
    );
    vec3 fresnel = fresnel_schlick(
        surface.standard.reflectance,
        surface.standard.grazing_reflectance,
        surface.standard.normal_view
    );
    return (1.0 - fresnel) * radiance * surface.transmission_color;
}

#endif
