#ifndef C3D_INSTANCE_WORLD_GLSL
#define C3D_INSTANCE_WORLD_GLSL

// A batch record holds an instance relative to its node; the draw root holds the node's world model and normal rows.
InstanceGpu instance_to_world(DrawRoot draw, InstanceGpu record) {
    InstanceGpu world = record;
    world.model = draw.model * record.model;
    mat3 normal_matrix = mat3(draw.normal_0.xyz, draw.normal_1.xyz, draw.normal_2.xyz)
        * mat3(record.normal_0.xyz, record.normal_1.xyz, record.normal_2.xyz);
    world.normal_0.xyz = normal_matrix[0];
    world.normal_1.xyz = normal_matrix[1];
    world.normal_2.xyz = normal_matrix[2];
    return world;
}

#endif
