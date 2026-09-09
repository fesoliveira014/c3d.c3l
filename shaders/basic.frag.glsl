#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

// mirrored from MaterialFlags.alpha_mask in render/material.c3
const uint MATERIAL_ALPHA_MASK = 1u;

layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;

layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    BasicMaterialGpu material = BasicMaterialGpu(draw.material);
    vec4 color = material.color;
    if (material.map_present != 0u) {
        vec2 selected_uv = material.map_uv_set == 0u ? v_uv0 : v_uv1;
        vec3 uv = vec3(selected_uv, 1.0);
        vec2 transformed = vec2(dot(material.map_uv_row0.xyz, uv), dot(material.map_uv_row1.xyz, uv));
        color *= sample_texture_2d_implicit(material.map_texture, material.map_sampler, transformed);
    }

    if ((material.flags & MATERIAL_ALPHA_MASK) != 0u && color.a < material.alpha_cutoff) discard;
    out_color = color;
}
