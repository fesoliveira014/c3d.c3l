#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "constants.glsl"
#include "vertex_pull.glsl"
#include "custom_material.glsl"
#include "standard_surface.glsl"
#include "gbuffer_output.glsl"

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer PulseParams {
    vec4 color;
    vec4 motion;
};

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    PulseParams params = PulseParams(material.parameters);

    vec4 base_color = params.color;
    if (custom_slot_present(material, 0u)) base_color *= sample_custom_map(material, 0u, v_uv0, v_uv1);
    if ((material.flags & MATERIAL_ALPHA_MASK) != 0u && base_color.a < material.alpha_cutoff) discard;

    vec3 normal = normalize(v_normal);
    if ((material.flags & MATERIAL_DOUBLE_SIDED) != 0u && !gl_FrontFacing) normal = -normal;

    StandardMaterialSample material_sample;
    material_sample.base_color = base_color;
    material_sample.metallic = 0.0;
    material_sample.roughness = 1.0;
    material_sample.occlusion = 1.0;
    material_sample.emissive = vec3(0.0);
    material_sample.normal = normal;
    material_sample.offset_normal = normal;
    material_sample.view_direction = vec3(0.0);
    write_gbuffer(material_sample, 0.0, draw);
}
