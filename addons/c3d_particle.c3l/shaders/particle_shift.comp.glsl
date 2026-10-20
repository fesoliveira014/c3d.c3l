#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "particle/particle_step.glsl"

layout(local_size_x = 256) in; // mirrored as GROUP_SIZE in gpu/system.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Moves the live particles by the origin shift that queued since the last step.
void main() {
    StepRoot root = StepRoot(DispatchRoot(pc.root_gpu).parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index >= ParticleControl(root.control).alive) return;

    ParticleStates states = ParticleStates(root.state_home);
    states.values[index].position -= root.shift_stretch.xyz;
}
