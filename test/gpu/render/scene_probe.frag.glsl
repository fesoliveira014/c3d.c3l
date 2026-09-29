#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "material_alpha.glsl"
#include "scene_snapshot.glsl"

const float GAP_RANGE = 2.0; // mirrored as SCENE_READ_GAP_RANGE in test_scene_reads.c3
const vec3 FLAT_COLOR = vec3(0.2, 0.4, 0.6); // mirrored as SCENE_READ_FLAT_COLOR in test_scene_reads.c3

layout(location = 0) out vec4 out_color;

// gpu.c3l rejects a wrong-typed root header member; an extra trailing member would be accepted.
layout(push_constant) uniform Push {
#ifdef BROKEN_PUSH
    uint vertex_root_gpu;
#else
    uint64_t vertex_root_gpu;
#endif
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
#if defined(PROBE_COLOR)
    vec3 color = scene_color_at(frame, scene_uv(frame, gl_FragCoord.xy));
#elif defined(PROBE_GAP)
    vec3 color = vec3(scene_depth_gap(frame, gl_FragCoord) / GAP_RANGE, 0.0, 0.0);
#else
    vec3 color = FLAT_COLOR;
#endif
    out_color = material_output(color, 1.0, material.flags);
}
