#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "material_alpha.glsl"
#include "scene_snapshot.glsl"
#include "fog.glsl"

const vec3 READER_COLOR = vec3(0.9, 0.3, 0.1); // mirrored as READER_COLOR in test_sky.c3
const vec3 GLASS_COLOR = vec3(0.05, 0.1, 0.15); // mirrored as GLASS_COLOR in test_sky.c3
const float GLASS_HALF = 0.5; // mirrored as GLASS_HALF in test_sky.c3

layout(location = 0) in vec3 v_world_pos;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
#if defined(GLASS_CLEAR) || defined(GLASS_TINTED)
    vec2 uv = scene_uv(frame, gl_FragCoord.xy);
    vec3 behind = scene_color_at(frame, uv);
    float depth = scene_depth_at(frame, uv);
#if defined(GLASS_CLEAR)
    vec3 color = apply_fog_refracted(frame, v_world_pos, vec3(1.0), behind, depth, vec3(0.0));
#else
    vec3 color = apply_fog_refracted(frame, v_world_pos, vec3(GLASS_HALF), behind, depth, GLASS_COLOR);
#endif
#else
    vec3 color = READER_COLOR;
#endif
    out_color = material_output(color, 1.0, material.flags);
}
