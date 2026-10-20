#version 460
#define CLOTH_LOCAL_SIZE 1024 // the largest group size every desktop device offers
#ifdef CACHED
#define CLOTH_COHERENT // not guaranteed visible across invocations without the qualifier; measures its cost only
#else
#define CLOTH_COHERENT coherent
#endif
#include "physics/cloth_step.glsl"

// Every thread of the one workgroup reaches each of these in step; the loops around them have uniform bounds.
void sync_workgroup() {
    groupMemoryBarrier();
    barrier();
}

void main() {
    ClothRoot root = ClothRoot(DispatchRoot(pc.root_gpu).parameters);
    uint thread = gl_LocalInvocationID.x;
    uint stride = gl_WorkGroupSize.x;

    if ((root.phases & PASS_INITIALIZE) != 0u) {
        for (uint particle = thread; particle < root.particle_count; particle += stride) step_initialize(root, particle);
        sync_workgroup();
    }

    ClothWords starts = ClothWords(root.color_starts);
    for (uint substep = 0u; substep < root.substeps; substep++) {
        for (uint iteration = 0u; iteration < root.iterations; iteration++) {
            for (uint color = 0u; color < root.color_count; color++) {
                uint phases = 0u;
                if (iteration == 0u && color == 0u) phases |= PASS_PREDICT;
                if (color + 1u == root.color_count) {
                    phases |= PASS_COLLIDE;
                    if (iteration + 1u == root.iterations) phases |= PASS_INTEGRATE;
                }
                uint first_edge = starts.values[color];
                uint edge_count = starts.values[color + 1u] - first_edge;
                uint member_bit = color == 0u ? 0u : 1u;
                uint items = step_item_count(root, edge_count, phases);
                for (uint item = thread; item < items; item += stride) {
                    step_item(root, item, first_edge, edge_count, phases, member_bit);
                }
                sync_workgroup();
            }
        }
    }

    for (uint particle = thread; particle < root.particle_count; particle += stride) step_output(root, particle);
}
