#ifndef C3D_INSTANCE_RECORD_GLSL
#define C3D_INSTANCE_RECORD_GLSL

// Packs a placement relative to its batch node into the record the instance stages read; mirrors write_instance in
// instances.c3. The matrix is affine and does not mirror space, and the seed lies in [0, 1).
InstanceGpu pack_instance_record(mat4 model, vec4 color, float seed) {
    mat3 normal_matrix = transpose(inverse(mat3(model)));
    return InstanceGpu(
        model,
        vec4(normal_matrix[0], seed),
        vec4(normal_matrix[1], 0.0),
        vec4(normal_matrix[2], 0.0),
        color
    );
}

#endif
