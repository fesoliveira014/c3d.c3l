#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "particle/particle_step.glsl"

layout(local_size_x = 256) in; // mirrored as GROUP_SIZE in gpu/system.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Ages the live particles and flags the ones that survive, raising the BIRTH events of delivered children and the
// DEATH events of the expired. The first step of a system also clears its control block.
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
        control.step = 0u;
        control.delivered = 0u;
        control.event_counts[0] = 0u;
        control.event_counts[1] = 0u;
        control.dropped_events_low = 0u;
        control.dropped_events_high = 0u;
        control.skipped_events_low = 0u;
        control.skipped_events_high = 0u;
        control.evicted_low = 0u;
        control.evicted_high = 0u;
    }
    if (index >= root.capacity) return;

    uint live = 0u;
    if (!reset && index < particle_pool_size(control)) {
        ParticleStates states = ParticleStates(root.state_home);
        ParticleGpu particle = states.values[index];
        if (particle.fresh != 0u) {
            particle_raise_event(root, control, particle, PARTICLE_TRIGGER_BIRTH);
            states.values[index].fresh = 0u;
        }
        float age = particle.age + root.seconds;
        states.values[index].age = age;
        live = age < particle.lifetime ? 1u : 0u;
        if (live == 0u) particle_raise_event(root, control, particle, PARTICLE_TRIGGER_DEATH);
    }
    ParticleScan(root.scan).values[index] = uvec4(live, 0u, 0u, 0u);
}
