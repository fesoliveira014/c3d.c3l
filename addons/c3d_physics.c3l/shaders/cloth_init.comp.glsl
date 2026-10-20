#version 460
#include "physics/cloth_root.glsl"

void main() {
    ClothRoot root = ClothRoot(DispatchRoot(pc.root_gpu).parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.particle_count) return;

    vec4 start = ClothVectors(root.initial).values[index];
    ClothVectors(root.positions).values[index] = start;
    ClothVectors(root.predicted).values[index] = start;
    ClothVectors(root.velocities).values[index] = vec4(0.0);
}
