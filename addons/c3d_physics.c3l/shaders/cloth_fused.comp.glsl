#version 460
#include "physics/cloth_step.glsl"

void main() {
    ClothRoot root = ClothRoot(DispatchRoot(pc.root_gpu).parameters);
    uint item = gl_GlobalInvocationID.x;
    if ((root.phases & PASS_OUTPUT) != 0u) {
        if (item < root.particle_count) step_output(root, item);
        return;
    }

    StepPass step = StepPass(root.first, root.count, root.phases, root.member_bit, root.progress);
    if (item < step_item_count(root, step)) step_item(root, item, step);
}
