#ifndef C3D_DECALS_GLSL
#define C3D_DECALS_GLSL

#include "buffer_reference.glsl"
#include "clusters.glsl"
#include "material_maps.glsl"
#include "normal_mapping.glsl"
#include "standard_surface.glsl"

GPU_DECLARE_READONLY_ARRAY_REF(DecalArray, DecalGpu);

struct DecalList {
    uint count;
    uint first;
    bool clustered;
};

DecalList select_decals(FrameRoot frame, vec3 world_position, float view_depth) {
    DecalList all_decals = DecalList(frame.decal_count, 0u, false);
    if ((frame.flags & FRAME_LIGHTS_CLUSTERED) == 0u || frame.clusters == 0ul) return all_decals;

    ClusterGpu clusters = ClusterGpu(frame.clusters);
    uint cell;
    if (!cluster_cell_of(
        clusters,
        world_position,
        view_depth,
        cell
    )) return all_decals;

    ClusterRange range = ClusterRanges(clusters.decal_ranges).values[cell];
    if (range.overflow != 0u) return all_decals;

    return DecalList(range.count, cell * MAX_CLUSTER_DECALS, true);
}

uint selected_decal_index(FrameRoot frame, DecalList list, uint index) {
    if (!list.clustered) return index;

    ClusterGpu clusters = ClusterGpu(frame.clusters);
    return ClusterIndices(clusters.decal_indices).values[list.first + index];
}

// mirrored as decal_angle_weight in render/decal.c3
float decal_angle_weight(float facing_cosine, float fade_cosine, float inverse_band) {
    if (inverse_band == 0.0) return facing_cosine >= 1.0 ? 1.0 : 0.0;
    return clamp((facing_cosine - fade_cosine) * inverse_band, 0.0, 1.0);
}

vec4 decal_sample_map(
    TextureMapGpu map,
    vec2 uv,
    vec2 uv_dx,
    vec2 uv_dy
) {
    vec2 transformed_uv = vec2(dot(map.uv_linear.xy, uv), dot(map.uv_linear.zw, uv)) + map.uv_offset;
    vec2 transformed_dx = vec2(dot(map.uv_linear.xy, uv_dx), dot(map.uv_linear.zw, uv_dx));
    vec2 transformed_dy = vec2(dot(map.uv_linear.xy, uv_dy), dot(map.uv_linear.zw, uv_dy));
    return textureGrad(
        sampler2D(
            gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(map.texture_index))],
            gpu_sampler_heap[nonuniformEXT(GPU_HEAP_SLOT(map.sampler_index))]),
        transformed_uv,
        transformed_dx,
        transformed_dy);
}

void apply_decals(
    FrameRoot frame,
    DrawRoot draw,
    uint material_flags,
    vec3 world_position,
    float view_depth,
    vec3 position_dx,
    vec3 position_dy,
    inout StandardMaterialSample material_sample
) {
    if ((material_flags & MATERIAL_ALPHA_BLEND) != 0u || frame.decal_count == 0u) return;

    DecalList decals = select_decals(frame, world_position, view_depth);
    float gradient_scale = exp2(frame.mip_bias);
    for (uint index = 0u; index < decals.count; index++) {
        DecalGpu decal = DecalArray(frame.decals).values[selected_decal_index(frame, decals, index)];
        if ((draw.layers & decal.receiver_layers) == 0u) continue;

        vec4 position = vec4(world_position, 1.0);
        vec3 local = vec3(
            dot(decal.world_to_local_0, position),
            dot(decal.world_to_local_1, position),
            dot(decal.world_to_local_2, position));
        if (any(greaterThan(abs(local), vec3(DECAL_HALF_EXTENT)))) continue;

        float angle_weight = decal_angle_weight(
            dot(material_sample.offset_normal, decal.projection_fade.xyz),
            decal.fade_cosine,
            decal.projection_fade.w);
        if (angle_weight == 0.0) continue;

        vec2 uv = vec2(local.x + DECAL_HALF_EXTENT, DECAL_HALF_EXTENT - local.y);
        vec2 uv_dx = vec2(
            dot(decal.world_to_local_0.xyz, position_dx),
            -dot(decal.world_to_local_1.xyz, position_dx)) * gradient_scale;
        vec2 uv_dy = vec2(
            dot(decal.world_to_local_0.xyz, position_dy),
            -dot(decal.world_to_local_1.xyz, position_dy)) * gradient_scale;

        StandardMaterialGpu material = StandardMaterialRoot(decal.material).material;
        vec4 base_color = material.base_color;
        if ((material.map_flags & MATERIAL_MAP_BASE_COLOR) != 0u) {
            base_color *= decal_sample_map(
                material.base_color_map,
                uv,
                uv_dx,
                uv_dy);
        }
        float metallic = material.metallic;
        float roughness = material.roughness;
        if ((material.map_flags & MATERIAL_MAP_METALLIC_ROUGHNESS) != 0u) {
            vec4 factors = decal_sample_map(
                material.metallic_roughness_map,
                uv,
                uv_dx,
                uv_dy);
            metallic = clamp(metallic * factors.b, 0.0, 1.0);
            roughness = clamp(roughness * factors.g, 0.0, 1.0);
        }

        vec4 opacity = decal.weights * (base_color.a * angle_weight);
        material_sample.base_color.rgb = mix(material_sample.base_color.rgb, base_color.rgb, opacity.x);
        material_sample.roughness = mix(material_sample.roughness, roughness, opacity.z);
        material_sample.metallic = mix(material_sample.metallic, metallic, opacity.w);
        if (opacity.y > 0.0 && (material.map_flags & MATERIAL_MAP_NORMAL) != 0u
            && material.normal_scale != 0.0) {
            vec3 mapped = decode_normal(
                decal_sample_map(
                    material.normal_map,
                    uv,
                    uv_dx,
                    uv_dy).rgb,
                material.normal_scale,
                (material.map_flags & MATERIAL_MAP_NORMAL_RG) != 0u);
            vec3 direction;
            vec3 bitangent;
            if (!surface_tangent_frame(material_sample.normal, decal.tangent, direction, bitangent)) continue;

            vec3 normal = tangent_normal(material_sample.normal, vec4(direction, decal.tangent.w), mapped);
            vec3 blended = mix(material_sample.normal, normal, opacity.y);
            float length_squared = dot(blended, blended);
            if (length_squared > 0.0) material_sample.normal = blended * inversesqrt(length_squared);
        }
    }
}

#endif
