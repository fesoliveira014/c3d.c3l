#version 460
#include "physics/cloth_root.glsl"

void main() {
    ClothRoot root = ClothRoot(DispatchRoot(pc.root_gpu).parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.particle_count) return;

    vec4 position = ClothVectors(root.positions).values[index];
    if (position.w == 0.0) {
        vec3 target = (root.world * vec4(ClothVectors(root.rest).values[index].xyz, 1.0)).xyz;
        ClothVectors(root.predicted).values[index] = vec4(target, 0.0);
        return;
    }

    float step_seconds = root.gravity_step.w;
    vec3 held = ClothVectors(root.velocities).values[index].xyz;
    vec3 velocity = (held + root.gravity_step.xyz * step_seconds) * root.damping;
    ClothVectors(root.velocities).values[index] = vec4(velocity, 0.0);
    ClothVectors(root.predicted).values[index] = vec4(position.xyz + velocity * step_seconds, position.w);
}
