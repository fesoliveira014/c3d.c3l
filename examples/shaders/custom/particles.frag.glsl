#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "material_alpha.glsl"
#include "scene_snapshot.glsl"

layout(location = 3) in vec2 v_uv0;
layout(location = 5) in vec4 v_color;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ParticleParams {
    uint64_t particles;
    uint count;
    float size;
    float lifetime;
    float softness;
    uint _pad1;
    uint _pad2;
    vec4 color_young;
    vec4 color_old;
};

void main() {
    vec2 offset = v_uv0 * 2.0 - 1.0;
    float radius_squared = dot(offset, offset);
    if (radius_squared > 1.0) discard;
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    ParticleParams params = ParticleParams(material.parameters);

    float glow = 1.0 - radius_squared;
    float fade = params.softness > 0.0
        ? clamp(scene_depth_gap(frame, gl_FragCoord) / params.softness, 0.0, 1.0) : 1.0;
    out_color = material_output(v_color.rgb * (0.4 + 0.6 * glow), fade, material.flags);
}
