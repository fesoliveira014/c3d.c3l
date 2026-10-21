#version 460
#include "physics/cloth_step.glsl"

void main() {
    ClothRoot root = ClothRoot(DispatchRoot(pc.root_gpu).parameters);
    uint item = gl_GlobalInvocationID.x;
#ifndef CLOTH_LEAN
    if ((root.phases & PASS_STAGE) != 0u) {
        if (item < step_stage_count(root)) step_stage(root, item);
        return;
    }
#endif
    if ((root.phases & PASS_OUTPUT) != 0u) {
        if (item < root.particle_count) step_output(root, item);
        return;
    }
    if (root.phases == PASS_INITIALIZE) {
        if (item < root.particle_count) step_initialize(root, item);
        return;
    }

    StepPass step = StepPass(
        root.first,
        root.count,
        root.phases,
        root.member_bit,
        root.progress,
#ifdef CLOTH_LEAN
        0.0,
#else
        root.previous_progress,
#endif
        root.stiffness
    );
    if (item < step_item_count(root, step)) step_item(root, item, step);
}
