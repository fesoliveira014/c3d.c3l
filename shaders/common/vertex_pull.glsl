#ifndef C3D_VERTEX_PULL_GLSL
#define C3D_VERTEX_PULL_GLSL

#include "buffer_reference.glsl"

// mirrored from GeometryFlags in render/geometry.c3
#define GEOMETRY_HAS_NORMALS 1u
#define GEOMETRY_HAS_TANGENTS 2u
#define GEOMETRY_HAS_UV0 4u
#define GEOMETRY_HAS_UV1 8u
#define GEOMETRY_HAS_COLORS 16u
#define GEOMETRY_INDICES_U16 128u

GPU_DECLARE_READONLY_ARRAY_REF(FloatStream, float);
GPU_DECLARE_READONLY_ARRAY_REF(IndexStream, uint);

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

uint pull_u16(IndexStream stream, uint index) {
    uint word = stream.values[index >> 1u];
    return (index & 1u) == 0u ? word & 0xffffu : word >> 16u;
}

uvec3 pull_triangle(GeometryRoot geometry, uint primitive) {
    uint first = 3u * primitive;
    if (geometry.indices == 0ul) return uvec3(first, first + 1u, first + 2u);
    IndexStream stream = IndexStream(geometry.indices);
    if ((geometry.flags & GEOMETRY_INDICES_U16) == 0u) {
        return uvec3(stream.values[first], stream.values[first + 1u], stream.values[first + 2u]);
    }
    return uvec3(pull_u16(stream, first), pull_u16(stream, first + 1u), pull_u16(stream, first + 2u));
}

#endif
