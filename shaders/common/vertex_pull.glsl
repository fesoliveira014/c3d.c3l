#ifndef C3D_VERTEX_PULL_GLSL
#define C3D_VERTEX_PULL_GLSL

#include "buffer_reference.glsl"

// mirrored from GeometryFlags in render/geometry.c3
#define GEOMETRY_HAS_NORMALS 1u
#define GEOMETRY_HAS_TANGENTS 2u
#define GEOMETRY_HAS_UV0 4u
#define GEOMETRY_HAS_UV1 8u

GPU_DECLARE_READONLY_ARRAY_REF(FloatStream, float);

vec3 pull_vec3(uint64_t stream, uint index) {
    FloatStream values = FloatStream(stream);
    return vec3(values.values[3u * index], values.values[3u * index + 1u], values.values[3u * index + 2u]);
}

vec2 pull_vec2(uint64_t stream, uint index) {
    FloatStream values = FloatStream(stream);
    return vec2(values.values[2u * index], values.values[2u * index + 1u]);
}

vec4 pull_vec4(uint64_t stream, uint index) {
    FloatStream values = FloatStream(stream);
    return vec4(
        values.values[4u * index],
        values.values[4u * index + 1u],
        values.values[4u * index + 2u],
        values.values[4u * index + 3u]
    );
}

#endif
