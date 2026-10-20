#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "trace_pose.glsl"
#include "landscape/water_waves.glsl"
#include "landscape/water_simulation.glsl"
#include "landscape/water_spectral.glsl"

// The drawn surface at the frame's time: the vertex stage's displacement of each rest vertex.
void main() {
    TraceCustomPoseRoot root = TraceCustomPoseRoot(pc.root_gpu);
    uint index;
    if (!trace_pose_index(index)) return;

    CustomMaterialGpu material = CustomMaterialGpu(root.material);
    WaterParams params = WaterParams(material.parameters);
    TracePoseVertex vertex = trace_pose_vertex(index);
    WaterSurfacePoint point;
    if ((params.flags & WATER_SIMULATED) != 0u) {
        uint grid_texture = material.slots[WATER_SIMULATION_SLOT].texture_index;
        point = water_simulated_point(params, grid_texture, index, vertex.position.xz);
    } else if ((params.flags & WATER_SPECTRAL) != 0u) {
        point = water_spectral_point(material, params, vertex.position.xz);
    } else {
        point = water_surface_point(params, vertex.position.xz, root.time);
    }

    // Raster writes w = 1.0 for the tangent, whatever the rest geometry carries.
    trace_pose_write(index, point.position, point.normal, vec4(point.tangent, 1.0));
}
