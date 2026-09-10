#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "vertex_pull.glsl"
#include "normal_mapping.glsl"
#include "brdf.glsl"
#include "lights.glsl"

const uint MATERIAL_ALPHA_MASK = 1u; // mirrored as MaterialFlags.alpha_mask
const uint MATERIAL_DOUBLE_SIDED = 2u; // mirrored as MaterialFlags.double_sided

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec4 v_tangent;
layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

vec2 map_uv(uint uv_set, vec4 row0, vec4 row1) {
    vec3 uv = vec3(uv_set == 0u ? v_uv0 : v_uv1, 1.0);
    return vec2(dot(row0.xyz, uv), dot(row1.xyz, uv));
}

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    StandardMaterialGpu material = StandardMaterialGpu(draw.material);
    vec4 base_color = material.base_color;
    float metallic = material.metallic;
    float roughness = material.roughness;
    float occlusion = 1.0;
    vec3 emissive = material.emissive_strength.rgb * material.emissive_strength.w;

    if (material.base_color_present != 0u) {
        base_color *= sample_texture_2d_implicit(
            material.base_color_texture,
            material.base_color_sampler,
            map_uv(material.base_color_uv_set, material.base_color_uv_row0, material.base_color_uv_row1)
        );
    }
    if (material.metallic_roughness_present != 0u) {
        vec4 factors = sample_texture_2d_implicit(
            material.metallic_roughness_texture,
            material.metallic_roughness_sampler,
            map_uv(
                material.metallic_roughness_uv_set,
                material.metallic_roughness_uv_row0,
                material.metallic_roughness_uv_row1
            )
        );
        metallic = clamp(metallic * factors.b, 0.0, 1.0);
        roughness = clamp(roughness * factors.g, 0.0, 1.0);
    }
    if (material.occlusion_present != 0u) {
        float sampled = sample_texture_2d_implicit(
            material.occlusion_texture,
            material.occlusion_sampler,
            map_uv(material.occlusion_uv_set, material.occlusion_uv_row0, material.occlusion_uv_row1)
        ).r;
        occlusion = mix(1.0, clamp(sampled, 0.0, 1.0), material.occlusion_strength);
    }
    if (material.emissive_present != 0u) {
        emissive *= sample_texture_2d_implicit(
            material.emissive_texture,
            material.emissive_sampler,
            map_uv(material.emissive_uv_set, material.emissive_uv_row0, material.emissive_uv_row1)
        ).rgb;
    }

    vec3 normal = normalize(v_normal);
    if (material.normal_present != 0u && material.normal_scale != 0.0) {
        vec2 uv = map_uv(material.normal_uv_set, material.normal_uv_row0, material.normal_uv_row1);
        vec3 mapped = decode_normal(
            sample_texture_2d_implicit(material.normal_texture, material.normal_sampler, uv).rgb,
            material.normal_scale
        );
        GeometryRoot geometry = GeometryRoot(draw.geometry);
        if ((geometry.flags & GEOMETRY_HAS_TANGENTS) != 0u) {
            normal = tangent_normal(normal, v_tangent, mapped);
        } else {
            normal = derivative_normal(
                normal,
                mapped,
                dFdx(v_world_pos),
                dFdy(v_world_pos),
                dFdx(uv),
                dFdy(uv)
            );
        }
    }
    if ((material.flags & MATERIAL_DOUBLE_SIDED) != 0u && !gl_FrontFacing) normal = -normal;

    // Derivatives and implicit-LOD samples must retain helper lanes across cutouts.
    if ((material.flags & MATERIAL_ALPHA_MASK) != 0u && base_color.a < material.alpha_cutoff) discard;

    StandardSurface surface = prepare_standard_surface(
        base_color.rgb,
        metallic,
        roughness,
        normal,
        standard_view_direction(frame, v_world_pos)
    );
    vec3 color = frame.ambient.rgb * base_color.rgb * (1.0 - metallic) * occlusion + emissive;
    for (uint index = 0u; index < frame.light_count; index++) {
        LightGpu light = LightArray(frame.lights).values[index];
        if ((draw.layers & light.layers) == 0u) continue;
        color += evaluate_standard_light(light, v_world_pos, surface);
    }
    out_color = vec4(color, base_color.a);
}
