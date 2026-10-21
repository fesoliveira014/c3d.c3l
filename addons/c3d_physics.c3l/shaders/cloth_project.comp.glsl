#version 460
#include "physics/cloth_root.glsl"

const float MIN_EDGE_LENGTH = 1e-7; // metres; mirrored as MIN_CONSTRAINT_LENGTH in solve.c3

// The edges of one color share no particle, so each thread owns both of its particles.
void main() {
    ClothRoot root = ClothRoot(DispatchRoot(pc.root_gpu).parameters);
    uint thread = gl_GlobalInvocationID.x;
    if (thread >= root.count) return;

    uvec4 edge = ClothEdges(root.edges).values[root.first + thread];
    ClothVectors predicted = ClothVectors(root.predicted);
    vec4 first = predicted.values[edge.x];
    vec4 second = predicted.values[edge.y];
    float total_weight = first.w + second.w;
    if (total_weight == 0.0) return;

    vec3 delta = second.xyz - first.xyz;
    float length_now = length(delta);
    if (length_now <= MIN_EDGE_LENGTH) return;

    vec3 correction = delta / length_now * ((length_now - uintBitsToFloat(edge.z)) * root.stiffness / total_weight);
    predicted.values[edge.x].xyz = first.xyz + correction * first.w;
    predicted.values[edge.y].xyz = second.xyz - correction * second.w;
}
