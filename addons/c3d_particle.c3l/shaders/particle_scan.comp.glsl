#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "particle/particle_step.glsl"

layout(local_size_x = 256) in; // mirrored as GROUP_SIZE in gpu/system.c3

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

shared uvec2 sums[PARTICLE_GROUP];

// Inclusive scan of one value per invocation; every invocation of the group calls it.
uvec2 group_scan(uvec2 value) {
    uint local = gl_LocalInvocationID.x;
    sums[local] = value;
    barrier();
    for (uint offset = 1u; offset < PARTICLE_GROUP; offset <<= 1u) {
        uvec2 earlier = local >= offset ? sums[local - offset] : uvec2(0u);
        barrier();
        sums[local] += earlier;
        barrier();
    }
    return sums[local];
}

// Blocks mode ranks the flags inside each group and writes the group totals. Totals mode, one group, turns the group
// totals into the ranks of their groups and stores the grand totals in the control block.
void main() {
    StepRoot root = StepRoot(DispatchRoot(pc.root_gpu).parameters);
    ParticleScan scan = ParticleScan(root.scan);
    ParticleTotals totals = ParticleTotals(root.totals);
    uint local = gl_LocalInvocationID.x;
    if (root.mode == PARTICLE_SCAN_BLOCKS) {
        uint index = gl_GlobalInvocationID.x;
        uvec2 flags = index < root.capacity ? scan.values[index].xy : uvec2(0u);
        uvec2 inclusive = group_scan(flags);
        if (index < root.capacity) scan.values[index].zw = inclusive - flags;
        if (local == PARTICLE_GROUP - 1u) totals.values[gl_WorkGroupID.x] = inclusive;
        return;
    }

    uint groups = (root.capacity + PARTICLE_GROUP - 1u) / PARTICLE_GROUP;
    uvec2 carry = uvec2(0u);
    for (uint first = 0u; first < groups; first += PARTICLE_GROUP) {
        uint index = first + local;
        uvec2 value = index < groups ? totals.values[index] : uvec2(0u);
        uvec2 inclusive = group_scan(value);
        if (index < groups) totals.values[index] = carry + inclusive - value;
        uvec2 chunk = sums[PARTICLE_GROUP - 1u];
        barrier();
        carry += chunk;
    }
    if (local == 0u) {
        ParticleControl control = ParticleControl(root.control);
        control.live_total = carry.x;
        control.drawn_total = carry.y;
    }
}
