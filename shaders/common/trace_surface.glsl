#ifndef C3D_TRACE_SURFACE_GLSL
#define C3D_TRACE_SURFACE_GLSL

#include "descriptor_heap.glsl"
#include "vertex_pull.glsl"
#include "material_uv.glsl"

struct SceneHit {
    uint instance;
    uint primitive;
    vec2 barycentrics;
    float t;
};

vec2 hit_uv(uint64_t stream, uvec3 corners, vec3 weights) {
    if (stream == 0ul) return vec2(0.0);
    return pull_vec2(stream, corners.x) * weights.x
        + pull_vec2(stream, corners.y) * weights.y
        + pull_vec2(stream, corners.z) * weights.z;
}

vec4 sample_hit_map(TextureMapGpu map, uint map_flags, vec2 uv0, vec2 uv1) {
    vec2 uv = map_uv(map, map_flags, MATERIAL_MAP_BASE_COLOR, uv0, uv1);
    return sample_texture_2d(map.texture_index, map.sampler_index, uv);
}

// Coverage sources match the raster masked caster in depth_only.frag.glsl, sampled at the base level.
bool trace_surface_passes(TraceInstanceGpu instance, SceneHit hit) {
    GeometryRoot geometry = GeometryRoot(instance.geometry);
    uvec3 corners = pull_triangle(geometry, hit.primitive);
    vec3 weights = vec3(1.0 - hit.barycentrics.x - hit.barycentrics.y, hit.barycentrics);
    vec2 uv0 = hit_uv(geometry.uv0, corners, weights);
    vec2 uv1 = hit_uv(geometry.uv1, corners, weights);

    float alpha = 1.0;
    float cutoff = 0.0;
    switch (instance.material_kind) {
        case MATERIAL_KIND_STANDARD:
        case MATERIAL_KIND_PHYSICAL:
            StandardMaterialGpu standard = StandardMaterialRoot(instance.material).material;
            alpha = standard.base_color.a;
            cutoff = standard.alpha_cutoff;
            if ((standard.map_flags & MATERIAL_MAP_BASE_COLOR) != 0u) {
                alpha *= sample_hit_map(standard.base_color_map, standard.map_flags, uv0, uv1).a;
            }
            break;
        case MATERIAL_KIND_TOON:
            ToonMaterialGpu toon = ToonMaterialGpu(instance.material);
            alpha = toon.color.a;
            cutoff = toon.alpha_cutoff;
            if ((toon.map_flags & MATERIAL_MAP_BASE_COLOR) != 0u) {
                alpha *= sample_hit_map(toon.map, toon.map_flags, uv0, uv1).a;
            }
            break;
        case MATERIAL_KIND_CUSTOM:
            CustomMaterialGpu custom = CustomMaterialGpu(instance.material);
            if (!custom_slot_present(custom, 0u)) return true;
            TextureMapGpu slot = custom.slots[0];
            return sample_texture_2d(slot.texture_index, slot.sampler_index, custom_map_uv(custom, 0u, uv0, uv1)).a
                >= custom.alpha_cutoff;
        case MATERIAL_KIND_BASIC:
            BasicMaterialGpu basic = BasicMaterialGpu(instance.material);
            alpha = basic.color.a;
            cutoff = basic.alpha_cutoff;
            if ((basic.map_flags & MATERIAL_MAP_BASE_COLOR) != 0u) {
                alpha *= sample_hit_map(basic.map, basic.map_flags, uv0, uv1).a;
            }
            break;
        default:
            return true;
    }
    if ((geometry.flags & GEOMETRY_HAS_COLORS) != 0u) {
        alpha *= pull_vec4(geometry.colors, corners.x).a * weights.x
            + pull_vec4(geometry.colors, corners.y).a * weights.y
            + pull_vec4(geometry.colors, corners.z).a * weights.z;
    }
    return alpha >= cutoff;
}

#endif
