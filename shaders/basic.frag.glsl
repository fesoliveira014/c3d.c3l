#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    BasicMaterialGpu material = BasicMaterialGpu(draw.material);
    out_color = material.color;
}
