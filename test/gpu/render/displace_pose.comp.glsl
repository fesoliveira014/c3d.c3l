#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "trace_pose.glsl"
#include "test/displace.glsl"

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer DisplaceParams {
    vec4 color;
    vec4 motion;
};

void main() {
    uint index;
    if (!trace_pose_index(index)) return;

    TraceCustomPoseRoot root = TraceCustomPoseRoot(pc.root_gpu);

    DisplaceParams params = DisplaceParams(CustomMaterialGpu(root.material).parameters);
#ifdef INSTANCED
    float instance_x = trace_pose_instance().model[3].x;
#else
    float instance_x = 0.0;
#endif

    TracePoseVertex vertex = trace_pose_vertex(index);
    vec3 position = displace_position(vertex.position, root.time, params.motion, instance_x);
    trace_pose_write(index, position, vertex.normal, vertex.tangent);
}
