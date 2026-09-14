#ifndef C3D_DEFORM_GLSL
#define C3D_DEFORM_GLSL

#include "buffer_reference.glsl"
#include "vertex_pull.glsl"

// Morph deltas are packed target-major: every target's position deltas, then every target's normal deltas.
#define MORPH_STREAM_POSITION 0u
#define MORPH_STREAM_NORMAL 1u

GPU_DECLARE_READONLY_ARRAY_REF(JointPalette, mat4);
GPU_DECLARE_READONLY_ARRAY_REF(UintStream, uint);

vec3 morph_delta(GeometryRoot geometry, MorphWeightsGpu morph, uint index, uint stream) {
    vec3 delta = vec3(0.0);
    uint stream_base = stream * geometry.morph_target_count * geometry.vertex_count;
    for (uint slot = 0u; slot < morph.count; slot++) {
        uint target = morph.indices[slot];
        delta += morph.weights[slot] * pull_vec3(geometry.morph_deltas, stream_base + target * geometry.vertex_count + index);
    }
    return delta;
}

uvec4 load_joints(GeometryRoot geometry, uint index) {
    UintStream joints = UintStream(geometry.joints);
#ifdef SKINNED_U16
    uint low = joints.values[2u * index];
    uint high = joints.values[2u * index + 1u];
    return uvec4(low & 0xFFFFu, low >> 16, high & 0xFFFFu, high >> 16);
#else
    uint packed = joints.values[index];
    return uvec4(packed & 0xFFu, (packed >> 8) & 0xFFu, (packed >> 16) & 0xFFu, packed >> 24);
#endif
}

mat4 skin_matrix(GeometryRoot geometry, uint64_t palette_address, uint index) {
    JointPalette palette = JointPalette(palette_address);
    uvec4 joints = load_joints(geometry, index);
    vec4 weights = pull_vec4(geometry.weights, index);
    return weights.x * palette.values[joints.x] + weights.y * palette.values[joints.y]
        + weights.z * palette.values[joints.z] + weights.w * palette.values[joints.w];
}

#endif
