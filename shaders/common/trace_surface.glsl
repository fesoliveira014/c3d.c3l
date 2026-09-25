#ifndef C3D_TRACE_SURFACE_GLSL
#define C3D_TRACE_SURFACE_GLSL

#include "descriptor_heap.glsl"
#include "buffer_reference.glsl"
#include "vertex_pull.glsl"
#include "material_uv.glsl"
#include "texture_fetch.glsl"
#include "normal_mapping.glsl"

const float TRACE_SURFACE_OFFSET = 0.02; // world units along the normal; hides self-intersection at the cost of contact detail
const float TRACE_MIN_COSINE = 1e-3; // grazing hits keep a finite cone footprint
const float TRACE_MIN_AREA = 1e-12; // degenerate triangles and UV sets keep the level of detail finite
const vec3 TRACE_CUSTOM_ALBEDO = vec3(0.5); // custom shader code cannot run at a hit; a neutral grey stands in

GPU_DECLARE_READONLY_ARRAY_REF(TraceInstanceArray, TraceInstanceGpu);

struct SceneHit {
    uint instance;
    uint primitive;
    vec2 barycentrics;
    float t;
};

struct TraceSurface {
    vec3 position;
    vec3 normal;
    vec3 geometric_normal;
    vec3 albedo;
    vec3 emissive;
    float metallic;
    float roughness;
    uint material_kind;
    uint64_t material;
    bool back_face;
};

// The footprint of a hit's triangle under a ray cone, as ray_cone_lod in scene_trace.c3.
struct TraceFootprint {
    float uv0_area;
    float uv1_area;
    float world_area;
    float cone_width;
    float cosine;
};

TraceInstanceGpu trace_instance(SceneTraceRoot scene, uint row) {
    return TraceInstanceArray(scene.instances).values[row];
}

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

// Mirrored as ray_cone_lod in scene_trace.c3.
float ray_cone_lod(float texel_area, float world_area, float cone_width, float cosine) {
    return 0.5 * log2(texel_area / world_area) + log2(cone_width / cosine);
}

float triangle_uv_area(vec2 first, vec2 second, vec2 third) {
    vec2 edge_a = second - first;
    vec2 edge_b = third - first;
    return 0.5 * abs(edge_a.x * edge_b.y - edge_a.y * edge_b.x);
}

vec4 sample_hit_map_lod(
    TextureMapGpu map,
    uint map_flags,
    uint map_bit,
    vec2 uv0,
    vec2 uv1,
    TraceFootprint footprint
) {
    bool second_set = (map_flags & (map_bit << MATERIAL_MAP_UV1_SHIFT)) != 0u;
    float uv_area = second_set ? footprint.uv1_area : footprint.uv0_area;
    float uv_scale = abs(map.uv_linear.x * map.uv_linear.w - map.uv_linear.y * map.uv_linear.z);
    vec2 extent = vec2(texture_extent(map.texture_index));
    float texel_area = max(uv_area * uv_scale * extent.x * extent.y, TRACE_MIN_AREA);
    float lod = ray_cone_lod(texel_area, footprint.world_area, footprint.cone_width, footprint.cosine);
    vec2 uv = map_uv(map, map_flags, map_bit, uv0, uv1);
    return sample_texture_2d_lod(map.texture_index, map.sampler_index, uv, lod);
}

vec3 transform_point(TraceInstanceGpu instance, vec3 point) {
    vec4 homogeneous = vec4(point, 1.0);
    return vec3(
        dot(instance.local_to_world_0, homogeneous),
        dot(instance.local_to_world_1, homogeneous),
        dot(instance.local_to_world_2, homogeneous)
    );
}

// The transposed inverse keeps normals outward under mirrored and non-uniform transforms.
vec3 transform_normal(TraceInstanceGpu instance, vec3 normal) {
    return normalize(
        normal.x * instance.world_to_local_0.xyz
        + normal.y * instance.world_to_local_1.xyz
        + normal.z * instance.world_to_local_2.xyz
    );
}

vec4 hit_tangent(TraceInstanceGpu instance, GeometryRoot geometry, uvec3 corners, vec3 weights) {
    vec4 tangent = pull_vec4(geometry.tangents, corners.x) * weights.x
        + pull_vec4(geometry.tangents, corners.y) * weights.y
        + pull_vec4(geometry.tangents, corners.z) * weights.z;
    mat3 linear = mat3(instance.local_to_world_0.xyz, instance.local_to_world_1.xyz, instance.local_to_world_2.xyz);
    float orientation = determinant(linear) < 0.0 ? -1.0 : 1.0;
    return vec4(tangent.xyz * linear, tangent.w * orientation);
}

vec2 corner_map_uv(TextureMapGpu map, uint map_flags, GeometryRoot geometry, uvec3 corners, vec3 corner) {
    return map_uv(
        map,
        map_flags,
        MATERIAL_MAP_NORMAL,
        hit_uv(geometry.uv0, corners, corner),
        hit_uv(geometry.uv1, corners, corner)
    );
}

// Without a tangent stream, the triangle's edges stand in for the screen derivatives raster uses.
vec3 hit_mapped_normal(
    TraceInstanceGpu instance,
    GeometryRoot geometry,
    StandardMaterialGpu standard,
    uvec3 corners,
    vec3 weights,
    vec3 normal,
    vec3 world_edge_1,
    vec3 world_edge_2,
    vec2 uv0,
    vec2 uv1,
    TraceFootprint footprint
) {
    vec3 mapped = decode_normal(
        sample_hit_map_lod(standard.normal_map, standard.map_flags, MATERIAL_MAP_NORMAL, uv0, uv1, footprint).rgb,
        standard.normal_scale
    );
    if ((geometry.flags & GEOMETRY_HAS_TANGENTS) != 0u) {
        return tangent_normal(normal, hit_tangent(instance, geometry, corners, weights), mapped);
    }
    vec2 corner_uv_0 = corner_map_uv(standard.normal_map, standard.map_flags, geometry, corners, vec3(1.0, 0.0, 0.0));
    vec2 corner_uv_1 = corner_map_uv(standard.normal_map, standard.map_flags, geometry, corners, vec3(0.0, 1.0, 0.0));
    vec2 corner_uv_2 = corner_map_uv(standard.normal_map, standard.map_flags, geometry, corners, vec3(0.0, 0.0, 1.0));
    return derivative_normal(
        normal,
        mapped,
        world_edge_1,
        world_edge_2,
        corner_uv_1 - corner_uv_0,
        corner_uv_2 - corner_uv_0
    );
}

// cone_width is the cone's width at the hit in world units; maps sample at its ray-cone level of detail.
TraceSurface surface_from_hit(SceneTraceRoot scene, SceneHit hit, vec3 ray_direction, float cone_width) {
    TraceInstanceGpu instance = trace_instance(scene, hit.instance);
    GeometryRoot geometry = GeometryRoot(instance.geometry);
    uvec3 corners = pull_triangle(geometry, hit.primitive);
    vec3 weights = vec3(1.0 - hit.barycentrics.x - hit.barycentrics.y, hit.barycentrics);

    TraceSurface surface;
    surface.material_kind = instance.material_kind;
    surface.material = instance.material;
    surface.metallic = 0.0;
    surface.roughness = 1.0;
    surface.emissive = vec3(0.0);

    vec3 corner_0 = pull_vec3(geometry.positions, corners.x);
    vec3 corner_1 = pull_vec3(geometry.positions, corners.y);
    vec3 corner_2 = pull_vec3(geometry.positions, corners.z);
    vec3 world_0 = transform_point(instance, corner_0);
    vec3 world_1 = transform_point(instance, corner_1);
    vec3 world_2 = transform_point(instance, corner_2);
    surface.position = world_0 * weights.x + world_1 * weights.y + world_2 * weights.z;
    surface.geometric_normal = transform_normal(instance, cross(corner_1 - corner_0, corner_2 - corner_0));
    surface.normal = surface.geometric_normal;
    if ((geometry.flags & GEOMETRY_HAS_NORMALS) != 0u) {
        vec3 vertex_normal = pull_vec3(geometry.normals, corners.x) * weights.x
            + pull_vec3(geometry.normals, corners.y) * weights.y
            + pull_vec3(geometry.normals, corners.z) * weights.z;
        surface.normal = transform_normal(instance, vertex_normal);
    }

    bool facing_back = dot(surface.geometric_normal, ray_direction) > 0.0;
    surface.back_face = facing_back && (instance.flags & TRACE_INSTANCE_DOUBLE_SIDED) == 0u;
    if (surface.back_face) {
        surface.albedo = vec3(0.0);
        return surface;
    }

    vec2 uv0 = hit_uv(geometry.uv0, corners, weights);
    vec2 uv1 = hit_uv(geometry.uv1, corners, weights);
    TraceFootprint footprint;
    footprint.uv0_area = geometry.uv0 == 0ul ? 0.0 : triangle_uv_area(
        pull_vec2(geometry.uv0, corners.x),
        pull_vec2(geometry.uv0, corners.y),
        pull_vec2(geometry.uv0, corners.z)
    );
    footprint.uv1_area = geometry.uv1 == 0ul ? 0.0 : triangle_uv_area(
        pull_vec2(geometry.uv1, corners.x),
        pull_vec2(geometry.uv1, corners.y),
        pull_vec2(geometry.uv1, corners.z)
    );
    footprint.world_area = max(0.5 * length(cross(world_1 - world_0, world_2 - world_0)), TRACE_MIN_AREA);
    footprint.cone_width = cone_width;
    footprint.cosine = max(abs(dot(surface.geometric_normal, ray_direction)), TRACE_MIN_COSINE);

    vec4 base = vec4(1.0);
    switch (instance.material_kind) {
        case MATERIAL_KIND_STANDARD:
        case MATERIAL_KIND_PHYSICAL:
            StandardMaterialGpu standard = StandardMaterialRoot(instance.material).material;
            base = standard.base_color;
            surface.metallic = standard.metallic;
            surface.roughness = standard.roughness;
            surface.emissive = standard.emissive_strength.rgb * standard.emissive_strength.w;
            if ((standard.map_flags & MATERIAL_MAP_BASE_COLOR) != 0u) {
                base *= sample_hit_map_lod(
                    standard.base_color_map,
                    standard.map_flags,
                    MATERIAL_MAP_BASE_COLOR,
                    uv0,
                    uv1,
                    footprint
                );
            }
            if ((standard.map_flags & MATERIAL_MAP_METALLIC_ROUGHNESS) != 0u) {
                vec4 factors = sample_hit_map_lod(
                    standard.metallic_roughness_map,
                    standard.map_flags,
                    MATERIAL_MAP_METALLIC_ROUGHNESS,
                    uv0,
                    uv1,
                    footprint
                );
                surface.metallic = clamp(surface.metallic * factors.b, 0.0, 1.0);
                surface.roughness = clamp(surface.roughness * factors.g, 0.0, 1.0);
            }
            if ((standard.map_flags & MATERIAL_MAP_EMISSIVE) != 0u) {
                surface.emissive *= sample_hit_map_lod(
                    standard.emissive_map,
                    standard.map_flags,
                    MATERIAL_MAP_EMISSIVE,
                    uv0,
                    uv1,
                    footprint
                ).rgb;
            }
            if ((standard.map_flags & MATERIAL_MAP_NORMAL) != 0u && standard.normal_scale != 0.0) {
                surface.normal = hit_mapped_normal(
                    instance,
                    geometry,
                    standard,
                    corners,
                    weights,
                    surface.normal,
                    world_1 - world_0,
                    world_2 - world_0,
                    uv0,
                    uv1,
                    footprint
                );
            }
            break;
        case MATERIAL_KIND_TOON:
            ToonMaterialGpu toon = ToonMaterialGpu(instance.material);
            base = toon.color;
            if ((toon.map_flags & MATERIAL_MAP_BASE_COLOR) != 0u) {
                base *= sample_hit_map_lod(toon.map, toon.map_flags, MATERIAL_MAP_BASE_COLOR, uv0, uv1, footprint);
            }
            break;
        case MATERIAL_KIND_BASIC:
            BasicMaterialGpu basic = BasicMaterialGpu(instance.material);
            base = basic.color;
            if ((basic.map_flags & MATERIAL_MAP_BASE_COLOR) != 0u) {
                base *= sample_hit_map_lod(basic.map, basic.map_flags, MATERIAL_MAP_BASE_COLOR, uv0, uv1, footprint);
            }
            break;
        default:
            base = vec4(TRACE_CUSTOM_ALBEDO, 1.0);
            break;
    }
    if ((geometry.flags & GEOMETRY_HAS_COLORS) != 0u) {
        base *= pull_vec4(geometry.colors, corners.x) * weights.x
            + pull_vec4(geometry.colors, corners.y) * weights.y
            + pull_vec4(geometry.colors, corners.z) * weights.z;
    }
    surface.albedo = base.rgb;
    // Raster maps the normal before flipping a double-sided back face; the same order here.
    if (facing_back) {
        surface.geometric_normal = -surface.geometric_normal;
        surface.normal = -surface.normal;
    }
    return surface;
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
