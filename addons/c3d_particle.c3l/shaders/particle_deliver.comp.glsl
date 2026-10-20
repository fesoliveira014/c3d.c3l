#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "particle/particle_spawn.glsl"

layout(local_size_x = 256) in; // mirrored as GROUP_SIZE in gpu/system.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Adds to a 64-bit counter kept as two words.
void count_dropped(ParticleControl control, uint amount) {
    uint before = atomicAdd(control.dropped_low, amount);
    if (before + amount < before) atomicAdd(control.dropped_high, 1u);
}

void count_skipped(ParticleControl control, uint amount) {
    uint before = atomicAdd(control.skipped_events_low, amount);
    if (before + amount < before) atomicAdd(control.skipped_events_high, 1u);
}

// Takes up to wanted of the free slots after the children already delivered; first receives the slot index of the
// first one. Slots go to whichever event asks first, so the order of the children in the pool is not fixed.
uint claim_children(ParticleControl target, uint free_slots, uint wanted, out uint first) {
    uint seen = atomicAdd(target.delivered, 0u);
    while (true) {
        uint take = min(wanted, free_slots - min(free_slots, seen));
        first = seen;
        if (take == 0u) return 0u;

        uint previous = atomicCompSwap(target.delivered, seen, seen + take);
        if (previous == seen) return take;

        seen = previous;
    }
    return 0u;
}

// One invocation per event of the source's last step. An event the sub-emitter accepts spawns count children at its
// position in the target, or is counted as skipped when the target cannot take children. Mirrors process_events in
// update.c3.
void main() {
    StepRoot root = StepRoot(DispatchRoot(pc.root_gpu).parameters);
    ParticleControl source = ParticleControl(root.source_control);
    uint half_index = (source.step - 1u) & 1u;
    uint index = gl_GlobalInvocationID.x;
    if (index >= min(source.event_counts[half_index], root.source_event_capacity)) return;

    uint64_t half_offset = uint64_t(half_index) * uint64_t(root.source_event_capacity) * PARTICLE_EVENT_BYTES;
    ParticleEventGpu event = ParticleEvents(root.source_events + half_offset).values[index];
    if (((event.accepted >> root.delivery_sub) & 1u) == 0u) return;

    if (root.delivery_valid == 0u) {
        count_skipped(source, 1u);
        return;
    }

    ParticleControl target = ParticleControl(root.control);
    uint first;
    uint taken = claim_children(target, root.capacity - target.alive, root.delivery_count, first);
    if (taken < root.delivery_count) count_dropped(target, root.delivery_count - taken);

    uint stream = particle_child_seed(event.seed, event.key, root.delivery_sub);
    ParticleStates home = ParticleStates(root.state_home);
    bool raises_birth = root.event_accept[PARTICLE_TRIGGER_BIRTH] != 0u;
    for (uint child = 0u; child < taken; child++) {
        ParticleGpu particle = particle_spawn(root, stream, uvec2(child, 0u), event.position);
        particle.velocity += event.velocity * root.delivery_inherit;
        particle.spawn.x = uaddCarry(target.spawn_low, first + child, particle.spawn.y);
        particle.spawn.y += target.spawn_high;
        particle.fresh = raises_birth ? 1u : 0u;
        uint slot = target.alive + first + child;
        home.values[slot] = particle;
        if (root.trail_max_points != 0u) {
            TrailHeaders(root.trail_headers_home).values[slot] = TrailHeaderGpu(0u, 0u, 0.0, 0.0);
        }
    }
}
