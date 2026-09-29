#ifndef STANDARD_TWIN_GLSL
#define STANDARD_TWIN_GLSL

#include "custom_material.glsl"
#include "lights.glsl"
#include "normal_mapping.glsl"
#include "standard_surface.glsl"

// Mirrored by TwinParams in shading_paths.c3, rt_shadows.c3 and test_custom_shading.c3.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer TwinParams {
    vec4 base_color;
    vec4 metallic_roughness_occlusion;
    vec4 emissive;
};

// Standard's sample from slot 0 (base colour) and slot 1 (tangent-space normal). Vertex colour,
// normal-map scale, derivative normals and the other Standard maps stay in sample_standard_material.
StandardMaterialSample twin_surface(
    CustomMaterialGpu material,
    FrameRoot frame,
    vec3 world_position,
    vec3 vertex_normal,
    vec4 tangent,
    vec2 uv0,
    vec2 uv1,
    bool back_face
) {
    TwinParams params = TwinParams(material.parameters);
    StandardMaterialSample surface_sample;
    surface_sample.base_color = params.base_color;
    if (custom_slot_present(material, 0u)) {
        surface_sample.base_color *= sample_custom_map(material, 0u, uv0, uv1, frame.mip_bias);
    }
    surface_sample.metallic = params.metallic_roughness_occlusion.x;
    surface_sample.roughness = params.metallic_roughness_occlusion.y;
    surface_sample.occlusion = params.metallic_roughness_occlusion.z;
    surface_sample.emissive = params.emissive.rgb;

    vec3 normal = normalize(vertex_normal);
    surface_sample.offset_normal = normal;
    if (custom_slot_present(material, 1u)) {
        vec3 mapped = decode_normal(sample_custom_map(material, 1u, uv0, uv1, frame.mip_bias).rgb, 1.0);
        normal = tangent_normal(normal, tangent, mapped);
    }
    if ((material.flags & MATERIAL_DOUBLE_SIDED) != 0u && back_face) {
        normal = -normal;
        surface_sample.offset_normal = -surface_sample.offset_normal;
    }
    surface_sample.normal = normal;
    surface_sample.view_direction = standard_view_direction(frame, world_position);
    return surface_sample;
}

#endif
