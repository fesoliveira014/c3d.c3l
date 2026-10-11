#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "custom_material.glsl"
#include "blend_output.glsl"
#include "fog.glsl"

layout(location = 0) in vec3 v_world_pos;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer GlowParams {
    vec4 color;
};

const float GLOW_PULSE_RATE = 2.0; // radians per second
const float GLOW_PULSE_DEPTH = 0.3; // fraction of the coverage the pulse removes at its dimmest

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    vec4 color = GlowParams(material.parameters).color;
    color.a *= 1.0 - GLOW_PULSE_DEPTH * (0.5 + 0.5 * sin(frame.jitter_time.z * GLOW_PULSE_RATE));
    vec3 fogged = apply_material_fog(frame, v_world_pos, color.rgb, material.flags);
    write_blend_output(frame, material_output(fogged, color.a, material.flags), v_world_pos);
}
