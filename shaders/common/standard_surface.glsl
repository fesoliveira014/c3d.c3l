#ifndef C3D_STANDARD_SURFACE_GLSL
#define C3D_STANDARD_SURFACE_GLSL

#include "descriptor_heap.glsl"
#include "material_maps.glsl"
#include "normal_mapping.glsl"

struct StandardMaterialSample {
    vec4 base_color;
    float metallic;
    float roughness;
    float occlusion;
    vec3 emissive;
    vec3 normal;
    vec3 offset_normal;
    vec3 view_direction;
};

vec3 sample_material_normal(
    TextureMapGpu map,
    uint map_flags,
    uint map_bit,
    float scale,
    GeometryRoot geometry,
    vec3 world_position,
    vec3 vertex_normal,
    vec4 tangent,
    vec2 uv0,
    vec2 uv1
) {
    vec2 uv = map_uv(map, map_flags, map_bit, uv0, uv1);
    vec3 mapped = decode_normal(
        sample_texture_2d_implicit(map.texture_index, map.sampler_index, uv).rgb,
        scale
    );
    if ((geometry.flags & GEOMETRY_HAS_TANGENTS) != 0u) {
        return tangent_normal(vertex_normal, tangent, mapped);
    }
    return derivative_normal(
        vertex_normal,
        mapped,
        dFdx(world_position),
        dFdy(world_position),
        dFdx(uv),
        dFdy(uv)
    );
}

StandardMaterialSample sample_standard_material(
    StandardMaterialGpu material,
    GeometryRoot geometry,
    vec3 world_position,
    vec3 vertex_normal,
    vec4 tangent,
    vec2 uv0,
    vec2 uv1,
    vec3 view_direction,
    bool back_face
) {
    StandardMaterialSample material_sample;
    material_sample.base_color = material.base_color;
    material_sample.metallic = material.metallic;
    material_sample.roughness = material.roughness;
    material_sample.occlusion = 1.0;
    material_sample.emissive = material.emissive_strength.rgb * material.emissive_strength.w;

    if ((material.map_flags & MATERIAL_MAP_BASE_COLOR) != 0u) {
        material_sample.base_color *= sample_map(
            material.base_color_map,
            material.map_flags,
            MATERIAL_MAP_BASE_COLOR,
            uv0,
            uv1
        );
    }
    if ((material.map_flags & MATERIAL_MAP_METALLIC_ROUGHNESS) != 0u) {
        vec4 factors = sample_map(
            material.metallic_roughness_map,
            material.map_flags,
            MATERIAL_MAP_METALLIC_ROUGHNESS,
            uv0,
            uv1
        );
        material_sample.metallic = clamp(material_sample.metallic * factors.b, 0.0, 1.0);
        material_sample.roughness = clamp(material_sample.roughness * factors.g, 0.0, 1.0);
    }
    if ((material.map_flags & MATERIAL_MAP_OCCLUSION) != 0u) {
        float sampled = sample_map(
            material.occlusion_map,
            material.map_flags,
            MATERIAL_MAP_OCCLUSION,
            uv0,
            uv1
        ).r;
        material_sample.occlusion = mix(
            1.0,
            clamp(sampled, 0.0, 1.0),
            material.occlusion_strength
        );
    }
    if ((material.map_flags & MATERIAL_MAP_EMISSIVE) != 0u) {
        material_sample.emissive *= sample_map(
            material.emissive_map,
            material.map_flags,
            MATERIAL_MAP_EMISSIVE,
            uv0,
            uv1
        ).rgb;
    }

    vec3 normal = normalize(vertex_normal);
    material_sample.offset_normal = normal;
    if ((material.map_flags & MATERIAL_MAP_NORMAL) != 0u && material.normal_scale != 0.0) {
        normal = sample_material_normal(
            material.normal_map,
            material.map_flags,
            MATERIAL_MAP_NORMAL,
            material.normal_scale,
            geometry,
            world_position,
            normal,
            tangent,
            uv0,
            uv1
        );
    }
    if ((material.flags & MATERIAL_DOUBLE_SIDED) != 0u && back_face) {
        normal = -normal;
        material_sample.offset_normal = -material_sample.offset_normal;
    }
    material_sample.normal = normal;
    material_sample.view_direction = view_direction;
    return material_sample;
}

#endif
