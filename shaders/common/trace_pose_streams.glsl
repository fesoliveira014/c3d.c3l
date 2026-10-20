#ifndef C3D_TRACE_POSE_STREAMS_GLSL
#define C3D_TRACE_POSE_STREAMS_GLSL

#include "vertex_pull.glsl"

GPU_DECLARE_WRITEONLY_ARRAY_REF(TracePoseStream, float);

// The vertex this invocation poses, before any range check: a long row dispatches a 2-D grid of groups.
uint trace_pose_linear_index() {
    return (gl_WorkGroupID.y * gl_NumWorkGroups.x + gl_WorkGroupID.x) * TRACE_POSE_GROUP_SIZE + gl_LocalInvocationID.x;
}

// The inputs of pull_mesh_vertex in mesh_vertex.glsl, which a compute stage cannot include.
struct TracePoseVertex {
    vec3 position;
    vec3 normal;
    vec4 tangent;
    vec2 uv0;
    vec2 uv1;
    vec4 color;
};

TracePoseVertex pull_trace_pose_vertex(GeometryRoot geometry, uint index) {
    TracePoseVertex vertex;
    vertex.position = pull_vec3(geometry.positions, index);
    vertex.normal = (geometry.flags & GEOMETRY_HAS_NORMALS) != 0u
        ? pull_vec3(geometry.normals, index)
        : vec3(0.0, 0.0, 1.0);
    vertex.tangent = (geometry.flags & GEOMETRY_HAS_TANGENTS) != 0u
        ? pull_vec4(geometry.tangents, index)
        : vec4(0.0);
    vertex.uv0 = (geometry.flags & GEOMETRY_HAS_UV0) != 0u ? pull_vec2(geometry.uv0, index) : vec2(0.0);
    vertex.uv1 = (geometry.flags & GEOMETRY_HAS_UV1) != 0u ? pull_vec2(geometry.uv1, index) : vec2(0.0);
    vertex.color = (geometry.flags & GEOMETRY_HAS_COLORS) != 0u ? pull_vec4(geometry.colors, index) : vec4(1.0);
    return vertex;
}

void store_trace_pose_vec3(uint64_t stream, uint index, vec3 value) {
    TracePoseStream values = TracePoseStream(stream);
    values.values[3u * index] = value.x;
    values.values[3u * index + 1u] = value.y;
    values.values[3u * index + 2u] = value.z;
}

void store_trace_pose_vec4(uint64_t stream, uint index, vec4 value) {
    TracePoseStream values = TracePoseStream(stream);
    values.values[4u * index] = value.x;
    values.values[4u * index + 1u] = value.y;
    values.values[4u * index + 2u] = value.z;
    values.values[4u * index + 3u] = value.w;
}

// Writes the streams the rest geometry has, as trace_pose.comp.glsl does; tangent w is kept by the caller.
void write_trace_pose(
    GeometryRoot geometry,
    GeometryRoot posed,
    uint index,
    vec3 position,
    vec3 normal,
    vec4 tangent
) {
    store_trace_pose_vec3(posed.positions, index, position);
    if ((geometry.flags & GEOMETRY_HAS_NORMALS) != 0u) store_trace_pose_vec3(posed.normals, index, normal);
    if ((geometry.flags & GEOMETRY_HAS_TANGENTS) != 0u) store_trace_pose_vec4(posed.tangents, index, tangent);
}

#endif
