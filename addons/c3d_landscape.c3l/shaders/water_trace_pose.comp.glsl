#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "trace_pose.glsl"
#include "landscape/water_waves.glsl"
#include "landscape/water_simulation.glsl"

// The drawn surface at the frame's time: the vertex stage's displacement of each rest vertex.
void main() {
    TraceCustomPoseRoot root = TraceCustomPoseRoot(pc.root_gpu);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.vertex_count) return;

    CustomMaterialGpu material = CustomMaterialGpu(root.material);
    WaterParams params = WaterParams(material.parameters);
    TracePoseVertex vertex = trace_pose_vertex(index);
    WaterSurfacePoint point = (params.flags & WATER_SIMULATED) != 0u
        ? water_simulated_point(params, material.slots[WATER_SIMULATION_SLOT].texture_index, index, vertex.position.xz)
        : water_surface_point(params, vertex.position.xz, root.time);

    // Raster writes w = 1.0 for the tangent, whatever the rest geometry carries.
    trace_pose_write(index, point.position, point.normal, vec4(point.tangent, 1.0));
}
