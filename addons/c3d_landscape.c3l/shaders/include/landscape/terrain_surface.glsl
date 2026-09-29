#ifndef LANDSCAPE_TERRAIN_SURFACE_GLSL
#define LANDSCAPE_TERRAIN_SURFACE_GLSL

#include "custom_material.glsl"
#include "lights.glsl"
#include "standard_surface.glsl"
#include "landscape/terrain_height.glsl"

// One-sided on the map's border, so a tile edge shades from its own texels only.
vec2 terrain_gradient(uint height_texture, TerrainParams params, ivec2 texel) {
    ivec2 last = ivec2(int(params.texels) - 1);
    ivec2 low = max(texel - 1, ivec2(0));
    ivec2 high = min(texel + 1, last);
    float rise_x = terrain_height(height_texture, params, ivec2(high.x, texel.y))
        - terrain_height(height_texture, params, ivec2(low.x, texel.y));
    float rise_z = terrain_height(height_texture, params, ivec2(texel.x, high.y))
        - terrain_height(height_texture, params, ivec2(texel.x, low.y));
    return vec2(rise_x / float(high.x - low.x), rise_z / float(high.y - low.y)) / params.cell_size;
}

// Integer heights have no filtered read: blend the four surrounding texels' gradients by hand.
vec3 terrain_local_normal(uint height_texture, TerrainParams params, vec2 texel_position) {
    ivec2 last = ivec2(int(params.texels) - 1);
    ivec2 base = min(ivec2(floor(texel_position)), last);
    ivec2 next = min(base + 1, last);
    vec2 weight = texel_position - vec2(base);
    vec2 near_row = mix(
        terrain_gradient(height_texture, params, base),
        terrain_gradient(height_texture, params, ivec2(next.x, base.y)),
        weight.x
    );
    vec2 far_row = mix(
        terrain_gradient(height_texture, params, ivec2(base.x, next.y)),
        terrain_gradient(height_texture, params, next),
        weight.x
    );
    vec2 gradient = mix(near_row, far_row, weight.y);
    return normalize(vec3(-gradient.x, 1.0, -gradient.y));
}

vec4 terrain_layer_weights(
    CustomMaterialGpu material,
    TerrainParams params,
    vec2 uv0,
    vec2 uv1,
    float mip_bias
) {
    vec4 weights = custom_slot_present(material, TERRAIN_CONTROL_SLOT)
        ? sample_custom_map(material, TERRAIN_CONTROL_SLOT, uv0, uv1, mip_bias)
        : vec4(1.0, 0.0, 0.0, 0.0);
    weights *= vec4(lessThan(uvec4(0u, 1u, 2u, 3u), uvec4(params.layer_count)));
    float total = weights.x + weights.y + weights.z + weights.w;
    return total > 0.0 ? weights / total : vec4(1.0, 0.0, 0.0, 0.0);
}

// Layers are sampled in uniform control flow: sample_standard_material takes implicit derivatives.
StandardMaterialSample terrain_surface(
    CustomMaterialGpu material,
    DrawRoot draw,
    FrameRoot frame,
    vec3 world_position,
    vec2 uv0,
    vec2 uv1
) {
    TerrainParams params = TerrainParams(material.parameters);
    vec2 texel_position = uv1 * float(params.texels - 1u);
    vec3 local_normal = terrain_local_normal(material.slots[TERRAIN_HEIGHT_SLOT].texture_index, params, texel_position);
    vec3 normal = normalize(mat3(draw.normal_0.xyz, draw.normal_1.xyz, draw.normal_2.xyz) * local_normal);
    vec4 weights = terrain_layer_weights(material, params, uv0, uv1, frame.mip_bias);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    vec3 view_direction = standard_view_direction(frame, world_position);

    StandardMaterialSample blend;
    blend.base_color = vec4(0.0);
    blend.metallic = 0.0;
    blend.roughness = 0.0;
    blend.occlusion = 0.0;
    blend.emissive = vec3(0.0);
    blend.normal = vec3(0.0);
    for (uint layer = 0u; layer < params.layer_count; layer++) {
        StandardMaterialSample layer_sample = sample_standard_material(
            custom_reference(material, layer),
            geometry,
            world_position,
            normal,
            vec4(0.0),
            uv0,
            uv1,
            view_direction,
            false
        );
        float weight = weights[layer];
        blend.base_color += weight * layer_sample.base_color;
        blend.metallic += weight * layer_sample.metallic;
        blend.roughness += weight * layer_sample.roughness;
        blend.occlusion += weight * layer_sample.occlusion;
        blend.emissive += weight * layer_sample.emissive;
        blend.normal += weight * layer_sample.normal;
    }
    blend.normal = normalize(blend.normal);
    blend.offset_normal = normal;
    blend.view_direction = view_direction;
    return blend;
}

#endif
