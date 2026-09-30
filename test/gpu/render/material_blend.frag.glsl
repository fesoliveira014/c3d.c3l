#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "material_alpha.glsl"
#include "fog.glsl"

layout(location = 0) in vec3 v_world_pos;
layout(location = 5) in vec4 v_color;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer MaterialBlendParams {
    vec4 color;
};

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    vec4 color = MaterialBlendParams(material.parameters).color * v_color;
    out_color = material_output(
        apply_material_fog(frame, v_world_pos, color.rgb, material.flags),
        color.a,
        material.flags
    );
}
