#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "material_maps.glsl"

layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    if ((draw.flags & DRAW_ALPHA_MASK) == 0u) return;
    BasicMaterialGpu material = BasicMaterialGpu(draw.material);
    float alpha = material.color.a;
    if ((material.map_flags & MATERIAL_MAP_BASE_COLOR) != 0u) {
        alpha *= sample_map(material.map, material.map_flags, MATERIAL_MAP_BASE_COLOR, v_uv0, v_uv1).a;
    }
    if (alpha < material.alpha_cutoff) discard;
}
