#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "custom_material.glsl"
#include "blend_output.glsl"
#include "scene_snapshot.glsl"

layout(location = 0) in vec3 v_world_pos;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer WeightedStageParams {
    vec4 color;
};

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    vec4 color = WeightedStageParams(material.parameters).color;
#ifdef DEPTH_READ
    color.a *= clamp(scene_depth_gap(frame, gl_FragCoord), 0.0, 1.0);
#endif
    write_blend_output(frame, material_output(color.rgb, color.a, material.flags), v_world_pos);
}
