#version 460
#define CLOTH_LOCAL_SIZE 128 // the smallest group size Vulkan guarantees
#define CLOTH_COHERENT coherent
#include "physics/cloth_step.glsl"

// Every thread of a workgroup reaches each of these in step; the loops around them have uniform bounds.
void sync_workgroup() {
    groupMemoryBarrier();
    barrier();
}

// Workgroup i steps the i-th root; workgroups share no data and never wait for each other.
void main() {
    uint64_t roots = DispatchRoot(pc.root_gpu).parameters;
    ClothRoot root = ClothRoot(roots + uint64_t(gl_WorkGroupID.x) * CLOTH_ROOT_BYTES);
    uint thread = gl_LocalInvocationID.x;
    uint stride = gl_WorkGroupSize.x;

    if (step_stage_count(root) != 0u) {
        for (uint item = thread; item < step_stage_count(root); item += stride) step_stage(root, item);
        sync_workgroup();
    }
    if ((root.phases & PASS_INITIALIZE) != 0u) {
        for (uint particle = thread; particle < root.particle_count; particle += stride) step_initialize(root, particle);
        sync_workgroup();
    }

    ClothWords starts = ClothWords(root.color_starts);
    bool soft = (root.features & CLOTH_FEATURE_SOFT) != 0u;
    bool shapes = (root.features & CLOTH_FEATURE_SHAPES) != 0u;
    for (uint substep = 0u; substep < root.substeps; substep++) {
        bool final_substep = substep + 1u == root.substeps;
        float progress = float(substep + 1u) / float(root.substeps);
        float previous_progress = float(substep) / float(root.substeps);
        for (uint iteration = 0u; iteration < root.iterations; iteration++) {
            for (uint pass = 0u; pass < root.color_count; pass++) {
                uint phases = final_substep ? PASS_FINAL_SUBSTEP : 0u;
                if (iteration == 0u && pass == 0u) {
                    phases |= PASS_PREDICT;
                    if (soft) phases |= PASS_SOFT_BEFORE;
                }
                if (pass + 1u == root.color_count) {
                    phases |= PASS_COLLIDE;
                    if (shapes) {
                        phases |= PASS_SHAPES;
                        if (iteration == 0u) phases |= PASS_FIRST_CONTACT;
                    }
                    if (iteration + 1u == root.iterations) {
                        phases |= PASS_INTEGRATE;
                    } else if (soft) {
                        phases |= PASS_SOFT_AFTER;
                    }
                }

                uint first_constraint = starts.values[pass];
                StepPass step = StepPass(
                    first_constraint,
                    starts.values[pass + 1u] - first_constraint,
                    phases,
                    pass == 0u ? 0u : 1u,
                    progress,
                    previous_progress,
                    pass < root.edge_colors ? root.stretch_stiffness : root.bend_stiffness
                );
                uint items = step_item_count(root, step);
                for (uint item = thread; item < items; item += stride) step_item(root, item, step);
                sync_workgroup();
            }
        }
    }

    for (uint particle = thread; particle < root.particle_count; particle += stride) step_output(root, particle);
}
