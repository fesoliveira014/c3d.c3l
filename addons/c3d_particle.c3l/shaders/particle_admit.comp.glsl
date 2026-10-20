#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "particle/particle_spawn.glsl"

layout(local_size_x = 256) in; // mirrored as GROUP_SIZE in gpu/system.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Packs the survivors and their trails to the front of the alternate buffer, then appends the admitted newborns in
// ordinal order. Under DROP_OLDEST the first survivors in the pool, the oldest, are left out and raise their
// eviction events.
void main() {
    StepRoot root = StepRoot(DispatchRoot(pc.root_gpu).parameters);
    ParticleControl control = ParticleControl(root.control);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.capacity) return;

    uint evicted = particle_evicted(root, control);
    ParticleStates home = ParticleStates(root.state_home);
    ParticleStates alternate = ParticleStates(root.state_alt);
    if (index < particle_pool_size(control)) {
        uvec4 flags = ParticleScan(root.scan).values[index];
        if (flags.x != 0u) {
            uint rank = flags.z + ParticleTotals(root.totals).values[index / PARTICLE_GROUP].x;
            if (rank < evicted) {
                particle_raise_eviction(root, control, home.values[index]);
            } else {
                uint slot = rank - evicted;
                alternate.values[slot] = home.values[index];
                if (root.trail_max_points != 0u) particle_copy_trail(root, true, index, slot);
            }
        }
    }
    if (index < particle_emitted(root, control)) {
        uvec2 ordinal;
        ordinal.x = uaddCarry(control.spawn_low, control.delivered + index, ordinal.y);
        ordinal.y += control.spawn_high;
        uint slot = control.live_total - evicted + index;
        vec3 origin = vec3(root.emitter_row0.w, root.emitter_row1.w, root.emitter_row2.w);
        ParticleGpu born = particle_spawn(root, root.seed, ordinal, origin);
        alternate.values[slot] = born;
        particle_raise_event(root, control, born, PARTICLE_TRIGGER_BIRTH);
        if (root.trail_max_points != 0u) {
            TrailHeaders(root.trail_headers_alt).values[slot] = TrailHeaderGpu(0u, 0u, 0.0, 0.0);
        }
    }
}
