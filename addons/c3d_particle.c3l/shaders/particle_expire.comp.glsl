#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "particle/particle_step.glsl"

layout(local_size_x = 256) in; // mirrored as GROUP_SIZE in gpu/system.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Ages the live particles and flags the ones that survive. The first step of a system also clears its control block.
void main() {
    StepRoot root = StepRoot(DispatchRoot(pc.root_gpu).parameters);
    ParticleControl control = ParticleControl(root.control);
    uint index = gl_GlobalInvocationID.x;
    bool reset = root.reset != 0u;
    if (reset && index == 0u) {
        control.alive = 0u;
        control.pool_count = 0u;
        control.live_total = 0u;
        control.drawn_total = 0u;
        control.dropped_low = 0u;
        control.dropped_high = 0u;
        control.spawn_low = 0u;
        control.spawn_high = 0u;
    }
    if (index >= root.capacity) return;

    uint live = 0u;
    if (!reset && index < control.alive) {
        ParticleStates states = ParticleStates(root.state_home);
        float age = states.values[index].age + root.seconds;
        states.values[index].age = age;
        live = age < states.values[index].lifetime ? 1u : 0u;
    }
    ParticleScan(root.scan).values[index] = uvec4(live, 0u, 0u, 0u);
}
