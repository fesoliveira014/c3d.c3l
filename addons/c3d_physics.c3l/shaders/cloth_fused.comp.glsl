#version 460
#include "physics/cloth_step.glsl"

void main() {
    ClothRoot root = ClothRoot(DispatchRoot(pc.root_gpu).parameters);
    step_item(root, gl_GlobalInvocationID.x, root.first, root.count, root.phases, root.member_bit);
}
