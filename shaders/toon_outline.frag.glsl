#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "blend_output.glsl"
#include "material_maps.glsl"

layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;
layout(location = 5) in vec4 v_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

// The hull of a Toon mesh: the material's outline colour, cut out by the same coverage as the surface.
void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    ToonMaterialGpu material = ToonMaterialGpu(draw.material);

    if ((material.flags & MATERIAL_ALPHA_MASK) != 0u) {
        material_mip_bias = frame.mip_bias;
        float alpha = material.color.a * v_color.a;
        if ((material.map_flags & MATERIAL_MAP_BASE_COLOR) != 0u) {
            alpha *= sample_map(material.map, material.map_flags, MATERIAL_MAP_BASE_COLOR, v_uv0, v_uv1).a;
        }
        if (alpha < material.alpha_cutoff) discard;
    }

    vec3 radiance = pre_exposed(frame, material.outline_color_width.rgb);
    write_blend_output(frame, material_output(radiance, 1.0, material.flags), vec3(0.0));
}
