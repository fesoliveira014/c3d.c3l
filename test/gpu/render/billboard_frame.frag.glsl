#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "custom_material.glsl"
#include "material_alpha.glsl"

layout(location = 8) in vec3 v_billboard;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    out_color = material_output(vec3(v_billboard.z), 1.0, material.flags);
}
