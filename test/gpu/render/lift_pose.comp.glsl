#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "trace_pose.glsl"

const float LIFT = 0.5; // mirrored as POSE_LIFT in test_custom_trace_pose.c3

void main() {
    uint index;
    if (!trace_pose_index(index)) return;

    TracePoseVertex vertex = trace_pose_vertex(index);
    trace_pose_write(index, vertex.position + vec3(0.0, LIFT, 0.0), vertex.normal, vertex.tangent);
}
