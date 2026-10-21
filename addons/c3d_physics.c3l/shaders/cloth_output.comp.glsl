#version 460
#include "physics/cloth_root.glsl"

vec3 local_position(ClothRoot root, uint particle) {
    return (root.inverse_world * vec4(ClothVectors(root.positions).values[particle].xyz, 1.0)).xyz;
}

// Writes the node-local position and the area-weighted normal of every particle of the output geometry.
void main() {
    ClothRoot root = ClothRoot(DispatchRoot(pc.root_gpu).parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.particle_count) return;

    ClothWords adjacency = ClothWords(root.adjacency);
    ClothWords triangles = ClothWords(root.triangles);
    vec3 normal = vec3(0.0);
    for (uint entry = adjacency.values[index]; entry < adjacency.values[index + 1u]; entry++) {
        uint triangle = adjacency.values[root.particle_count + 1u + entry];
        vec3 a = local_position(root, triangles.values[3u * triangle]);
        vec3 b = local_position(root, triangles.values[3u * triangle + 1u]);
        vec3 c = local_position(root, triangles.values[3u * triangle + 2u]);
        normal += cross(b - a, c - a);
    }
    float normal_length = length(normal);
    normal = normal_length > 0.0 ? normal / normal_length : vec3(0.0, 1.0, 0.0);

    vec3 position = local_position(root, index);
    ClothFloats positions = ClothFloats(root.geometry_positions);
    ClothFloats normals = ClothFloats(root.geometry_normals);
    for (uint axis = 0u; axis < 3u; axis++) {
        positions.values[3u * index + axis] = position[axis];
        normals.values[3u * index + axis] = normal[axis];
    }
}
