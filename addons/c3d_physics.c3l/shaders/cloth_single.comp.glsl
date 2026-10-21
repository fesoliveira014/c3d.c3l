#version 460
#define CLOTH_LOCAL_SIZE 128 // the smallest group size Vulkan guarantees
#define CLOTH_COHERENT coherent
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
        bool final_substep = substep + 1u == root.substeps;
        float progress = float(substep + 1u) / float(root.substeps);
        for (uint iteration = 0u; iteration < root.iterations; iteration++) {
            for (uint color = 0u; color < root.color_count; color++) {
                uint phases = final_substep ? PASS_FINAL_SUBSTEP : 0u;
                if (iteration == 0u && color == 0u) phases |= PASS_PREDICT;
                if (color + 1u == root.color_count) {
                    phases |= PASS_COLLIDE;
                    if (iteration + 1u == root.iterations) phases |= PASS_INTEGRATE;
                }

                uint first_edge = starts.values[color];
                StepPass step = StepPass(
                    first_edge,
                    starts.values[color + 1u] - first_edge,
                    phases,
                    color == 0u ? 0u : 1u,
                    progress
                );
                uint items = step_item_count(root, step);
                for (uint item = thread; item < items; item += stride) step_item(root, item, step);
                sync_workgroup();
            }
        }
    }

    for (uint particle = thread; particle < root.particle_count; particle += stride) step_output(root, particle);
}
