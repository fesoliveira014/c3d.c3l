#version 460
#include "physics/cloth_root.glsl"

void main() {
    ClothRoot root = ClothRoot(DispatchRoot(pc.root_gpu).parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.particle_count) return;

    vec4 position = ClothVectors(root.positions).values[index];
    vec4 predicted = ClothVectors(root.predicted).values[index];
    if (position.w != 0.0) {
        ClothVectors(root.velocities).values[index] = vec4((predicted.xyz - position.xyz) / root.gravity_step.w, 0.0);
    }
    ClothVectors(root.positions).values[index] = vec4(predicted.xyz, position.w);
}
