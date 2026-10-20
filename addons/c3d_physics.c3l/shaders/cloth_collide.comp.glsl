#version 460
#include "physics/cloth_root.glsl"

void main() {
    ClothRoot root = ClothRoot(DispatchRoot(pc.root_gpu).parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.particle_count) return;

    ClothVectors predicted = ClothVectors(root.predicted);
    vec4 particle = predicted.values[index];
    if (particle.w == 0.0) return;

    vec3 position = particle.xyz;
    if (root.sphere.w > 0.0) {
        vec3 offset = position - root.sphere.xyz;
        float distance_now = length(offset);
        if (distance_now < root.sphere.w) {
            vec3 outward = distance_now > 1e-7 ? offset / distance_now : vec3(0.0, 1.0, 0.0);
            position = root.sphere.xyz + outward * root.sphere.w;
        }
    }
    position.y = max(position.y, root.ground);
    predicted.values[index].xyz = position;
}
