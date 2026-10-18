#ifndef LANDSCAPE_TERRAIN_SURFACE_GLSL
#define LANDSCAPE_TERRAIN_SURFACE_GLSL

#include "custom_material.glsl"
#include "lights.glsl"
#include "standard_surface.glsl"
#include "landscape/terrain_normal.glsl"

const uint TERRAIN_PLANES = 3u;
// The projection planes X, Y and Z: terrain axes of the u and v of uv = local.zy, local.xz and local.xy.
const vec3[TERRAIN_PLANES] TERRAIN_PLANE_U = vec3[](vec3(0.0, 0.0, 1.0), vec3(1.0, 0.0, 0.0), vec3(1.0, 0.0, 0.0));
const vec3[TERRAIN_PLANES] TERRAIN_PLANE_V = vec3[](vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, 1.0), vec3(0.0, 1.0, 0.0));
const float TERRAIN_FRAME_MIN_LENGTH_SQUARED = 1e-12; // floor of the projected u axis when the normal lies along it

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

void terrain_accumulate(inout StandardMaterialSample blend, StandardMaterialSample layer_sample, float weight) {
    blend.base_color += weight * layer_sample.base_color;
    blend.metallic += weight * layer_sample.metallic;
    blend.roughness += weight * layer_sample.roughness;
    blend.occlusion += weight * layer_sample.occlusion;
    blend.emissive += weight * layer_sample.emissive;
    blend.normal += weight * layer_sample.normal;
}

// The plane's u axis projected onto the surface; the sign puts the bitangent along v, as derivative frames do.
vec4 terrain_plane_tangent(mat3 model_linear, vec3 normal, uint plane) {
    vec3 direction = model_linear * TERRAIN_PLANE_U[plane];
    direction -= normal * dot(normal, direction);
    direction *= inversesqrt(max(dot(direction, direction), TERRAIN_FRAME_MIN_LENGTH_SQUARED));
    float handedness = dot(cross(normal, direction), model_linear * TERRAIN_PLANE_V[plane]) < 0.0 ? -1.0 : 1.0;
    return vec4(direction, handedness);
}

// Every layer on all three planes, in uniform control flow: the gradients of the projected uvs are explicit.
void terrain_accumulate_triplanar(
    inout StandardMaterialSample blend,
    CustomMaterialGpu material,
    DrawRoot draw,
    TerrainParams params,
    vec3 world_position,
    vec2 uv0,
    vec3 local_normal,
    vec3 normal,
    vec4 layer_weights,
    vec3 view_direction
) {
    mat3 model_linear = mat3(draw.model);
    vec3 local_position = inverse(model_linear) * (world_position - draw.model[3].xyz);
    vec3 local = vec3(uv0.x, local_position.y, uv0.y);
    vec2[TERRAIN_PLANES] plane_uv = vec2[](local.zy, local.xz, local.xy);
    vec3 plane_weights = pow(abs(local_normal), vec3(params.triplanar_sharpness));
    plane_weights /= plane_weights.x + plane_weights.y + plane_weights.z;

    for (uint plane = 0u; plane < TERRAIN_PLANES; plane++) {
        vec2 uv = plane_uv[plane];
        MaterialUvGrad plane_grad = MaterialUvGrad(uv, dFdx(uv), dFdy(uv));
        vec4 tangent = terrain_plane_tangent(model_linear, normal, plane);
        for (uint layer = 0u; layer < params.layer_count; layer++) {
            StandardMaterialSample layer_sample = sample_standard_material_grad(
                custom_reference(material, layer),
                normal,
                tangent,
                plane_grad,
                view_direction,
                false
            );
            terrain_accumulate(blend, layer_sample, layer_weights[layer] * plane_weights[plane]);
        }
    }
}

// Layers are sampled in uniform control flow: the top projection takes implicit derivatives, the other explicit ones.
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
    vec3 local_normal = terrain_local_normal(
        material.slots[TERRAIN_HEIGHT_SLOT].texture_index,
        material.slots[TERRAIN_BORDER_SLOT].texture_index,
        params,
        texel_position
    );
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
    if (params.slope_projection == TERRAIN_PROJECTION_TRIPLANAR) {
        terrain_accumulate_triplanar(
            blend,
            material,
            draw,
            params,
            world_position,
            uv0,
            local_normal,
            normal,
            weights,
            view_direction
        );
    } else {
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
            terrain_accumulate(blend, layer_sample, weights[layer]);
        }
    }
    blend.normal = normalize(blend.normal);
    blend.offset_normal = normal;
    blend.view_direction = view_direction;
    return blend;
}

#endif
