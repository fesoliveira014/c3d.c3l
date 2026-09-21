#ifndef C3D_MESH_VERTEX_GLSL
#define C3D_MESH_VERTEX_GLSL

#include "vertex_pull.glsl"
#if defined(SKINNED) || defined(SKINNED_U16) || defined(MORPH)
#include "deform.glsl"
#endif
#if !defined(DEPTH_ONLY) && !defined(VELOCITY)
#include "normal_mapping.glsl"
#endif

layout(location = 0) out vec3 v_world_pos;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec4 v_tangent;
layout(location = 3) out vec2 v_uv0;
layout(location = 4) out vec2 v_uv1;
layout(location = 5) out vec4 v_color;
layout(location = 6) out vec4 v_clip_pos;
#ifdef VELOCITY
layout(location = 7) out vec4 v_prev_clip_pos;
#endif

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

struct MeshVertexInput {
    vec3 position;
    vec3 normal;
    vec4 tangent;
    vec2 uv0;
    vec2 uv1;
    vec4 color;
};

MeshVertexInput pull_mesh_vertex(GeometryRoot geometry, uint index) {
    MeshVertexInput vertex;
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

void apply_mesh_deformation(inout MeshVertexInput vertex, DrawRoot draw, GeometryRoot geometry, uint index) {
#ifdef MORPH
    MorphWeightsGpu morph = MorphWeightsGpu(draw.morph);
    vertex.position += morph_delta(geometry, morph, index, MORPH_STREAM_POSITION);
    vertex.normal += morph_delta(geometry, morph, index, MORPH_STREAM_NORMAL);
#endif
#if defined(SKINNED) || defined(SKINNED_U16)
    mat4 skin = skin_matrix(geometry, draw.skin, index);
    vertex.position = (skin * vec4(vertex.position, 1.0)).xyz;
    vertex.normal = mat3(skin) * vertex.normal;
    vertex.tangent.xyz = mat3(skin) * vertex.tangent.xyz;
#endif
}

void write_mesh_outputs(MeshVertexInput vertex, DrawRoot draw, FrameRoot frame, GeometryRoot geometry) {
    vec4 world = draw.model * vec4(vertex.position, 1.0);
#ifdef VELOCITY
    v_prev_clip_pos = frame.prev_view_proj * (draw.prev_model * vec4(vertex.position, 1.0));
#endif
#if !defined(DEPTH_ONLY) && !defined(VELOCITY)
    mat3 normal_matrix = mat3(draw.normal_0.xyz, draw.normal_1.xyz, draw.normal_2.xyz);
    v_world_pos = world.xyz;
    v_normal = normalize(normal_matrix * vertex.normal);
    v_tangent = (geometry.flags & GEOMETRY_HAS_TANGENTS) != 0u
        ? world_tangent(draw.model, vertex.tangent)
        : vec4(0.0);
#endif
    v_uv0 = vertex.uv0;
    v_uv1 = vertex.uv1;
    v_color = vertex.color;
    v_clip_pos = frame.view_proj * world;
    gl_Position = v_clip_pos;
}

#endif
