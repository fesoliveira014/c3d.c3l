#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "probe_classification.glsl"

layout(location = 3) in vec2 v_uv0;
layout(location = 5) in vec4 v_color;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    vec2 offset = v_uv0 * 2.0 - 1.0;
    if (dot(offset, offset) > 1.0) discard;

    FrameRoot frame = FrameRoot(DrawRoot(pc.fragment_root_gpu).frame);
    uint state = PROBE_CLASS_PROVISIONAL;
    if (frame.probe_volumes != 0ul) {
        ProbeVolumeSetGpu set = ProbeVolumeSetGpu(frame.probe_volumes);
        // This example owns one volume; colors carry its grid coordinates, not a state copy.
        state = probe_classification(set.volumes[0], uvec3(round(v_color.xyz)));
    }
    vec3 color = state == PROBE_CLASS_EXCLUDED ? vec3(1.0, 0.12, 0.08)
        : state == PROBE_CLASS_ELIGIBLE ? vec3(0.12, 1.0, 0.25) : vec3(0.6);
    out_color = vec4(color, 1.0);
}
