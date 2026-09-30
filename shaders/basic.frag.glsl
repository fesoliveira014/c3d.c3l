#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "material_alpha.glsl"
#include "material_maps.glsl"
#include "fog.glsl"

layout(location = 0) in vec3 v_world_pos;
layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;
layout(location = 5) in vec4 v_color;

layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    material_mip_bias = frame.mip_bias;
    BasicMaterialGpu material = BasicMaterialGpu(draw.material);
    vec4 color = material.color;
    if ((material.map_flags & MATERIAL_MAP_BASE_COLOR) != 0u) {
        color *= sample_map(material.map, material.map_flags, MATERIAL_MAP_BASE_COLOR, v_uv0, v_uv1);
    }
    color *= v_color;

    if ((material.flags & MATERIAL_ALPHA_MASK) != 0u && color.a < material.alpha_cutoff) discard;
    vec3 fogged = (material.flags & MATERIAL_ALPHA_BLEND) != 0u ? apply_fog(frame, v_world_pos, color.rgb) : color.rgb;
    out_color = material_output(fogged, color.a, material.flags);
}
