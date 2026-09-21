#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "vertex_pull.glsl"
#include "standard_surface.glsl"
#include "brdf.glsl"
#include "lights.glsl"
#include "material_maps.glsl"
#include "gbuffer_output.glsl"

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec4 v_tangent;
layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;
layout(location = 5) in vec4 v_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    PhysicalMaterialGpu material = PhysicalMaterialGpu(draw.material);
    StandardMaterialSample material_sample = sample_standard_material(
        material.standard,
        GeometryRoot(draw.geometry),
        v_world_pos,
        v_normal,
        v_tangent,
        v_uv0,
        v_uv1,
        standard_view_direction(frame, v_world_pos),
        !gl_FrontFacing
    );

    float specular_weight = material.specular_color_weight.w;
    if (specular_weight > 0.0 && (material.extension_map_flags & PHYSICAL_EXTENSION_MAP_SPECULAR) != 0u) {
        specular_weight = clamp(specular_weight * sample_map(
            material.specular_map,
            material.extension_map_flags,
            PHYSICAL_EXTENSION_MAP_SPECULAR,
            v_uv0,
            v_uv1
        ).a, 0.0, 1.0);
    }

    material_sample.base_color *= v_color;
    // Derivatives and implicit-LOD samples must retain helper lanes across cutouts.
    if ((material.standard.flags & MATERIAL_ALPHA_MASK) != 0u
        && material_sample.base_color.a < material.standard.alpha_cutoff) discard;

    write_gbuffer(material_sample, specular_weight, draw);
}
