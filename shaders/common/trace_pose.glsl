#ifndef C3D_TRACE_POSE_GLSL
#define C3D_TRACE_POSE_GLSL

#include "trace_pose_streams.glsl"

layout(local_size_x = TRACE_POSE_GROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

GPU_DECLARE_READONLY_ARRAY_REF(TracePoseInstanceArray, InstanceGpu);

// Rest vertex i of the row's geometry, with the streams pull_mesh_vertex reads.
TracePoseVertex trace_pose_vertex(uint index) {
    TraceCustomPoseRoot root = TraceCustomPoseRoot(pc.root_gpu);
    return pull_trace_pose_vertex(GeometryRoot(root.source), index);
}

// Posed vertex i. The streams the rest geometry lacks are not written. The tangent is stored as given: pass the rest tangent's w.
void trace_pose_write(uint index, vec3 position, vec3 normal, vec4 tangent) {
    TraceCustomPoseRoot root = TraceCustomPoseRoot(pc.root_gpu);
    write_trace_pose(GeometryRoot(root.source), GeometryRoot(root.posed), index, position, normal, tangent);
}

// The record an instanced vertex stage reads through instance_source; undefined for a single mesh.
InstanceGpu trace_pose_instance() {
    TraceCustomPoseRoot root = TraceCustomPoseRoot(pc.root_gpu);
    return TracePoseInstanceArray(root.instance).values[0];
}

#endif
