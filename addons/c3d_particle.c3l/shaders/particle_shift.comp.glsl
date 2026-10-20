#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "particle/particle_step.glsl"

layout(local_size_x = 256) in; // mirrored as GROUP_SIZE in gpu/system.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Moves the live particles and their stored trail points by the origin shift that queued since the last step.
void main() {
    StepRoot root = StepRoot(DispatchRoot(pc.root_gpu).parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index >= ParticleControl(root.control).alive) return;

    ParticleStates states = ParticleStates(root.state_home);
    states.values[index].position -= root.shift_stretch.xyz;
    if (root.trail_max_points == 0u) return;

    TrailHeaderGpu header = TrailHeaders(root.trail_headers_home).values[index];
    TrailPoints points = TrailPoints(root.trail_points_home);
    for (uint rank = 0u; rank < header.count; rank++) {
        uint slot = index * root.trail_max_points + particle_trail_slot(header, root.trail_max_points, rank);
        points.values[slot].xyz -= root.shift_stretch.xyz;
    }
}
