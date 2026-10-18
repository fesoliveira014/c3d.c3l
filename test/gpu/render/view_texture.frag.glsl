#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "custom_material.glsl"
#include "pre_exposure.glsl"

layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

// mirrored as VIEW_TEXTURE_ABSENT_COLOR in test_view_textures.c3
const vec3 ABSENT_COLOR = vec3(0.0, 0.0, 1.0);

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);

    vec3 color = ABSENT_COLOR;
    if (custom_slot_present(frame, material, 0u)) color = sample_custom_map(frame, material, 0u, v_uv0, v_uv1).rgb;

    out_color = material_output(pre_exposed(frame, color), 1.0, material.flags);
}
