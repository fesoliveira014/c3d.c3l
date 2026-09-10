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
    if ((material.map_flags & MATERIAL_MAP_BASE_COLOR) != 0u) {
        TextureMapGpu map = material.map;
        bool uv1 = (material.map_flags & (MATERIAL_MAP_BASE_COLOR << MATERIAL_MAP_UV1_SHIFT)) != 0u;
        vec2 uv = uv1 ? v_uv1 : v_uv0;
        vec2 transformed = vec2(dot(map.uv_linear.xy, uv), dot(map.uv_linear.zw, uv)) + map.uv_offset;
        color *= sample_texture_2d_implicit(map.texture_index, map.sampler_index, transformed);
    }

    if ((material.flags & MATERIAL_ALPHA_MASK) != 0u && color.a < material.alpha_cutoff) discard;
    out_color = color;
}
