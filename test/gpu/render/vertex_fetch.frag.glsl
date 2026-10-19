#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "custom_material.glsl"
#include "pre_exposure.glsl"

layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);

    out_color = material_output(pre_exposed(frame, vec3(1.0)), 1.0, material.flags);
}
