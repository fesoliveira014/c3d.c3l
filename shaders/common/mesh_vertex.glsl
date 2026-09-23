#ifndef C3D_MESH_VERTEX_GLSL
#define C3D_MESH_VERTEX_GLSL

#include "vertex_pull.glsl"
#if defined(SKINNED) || defined(SKINNED_U16) || defined(MORPH)
#include "deform.glsl"
#endif
#if !defined(DEPTH_ONLY) && !defined(VELOCITY)
#include "normal_mapping.glsl"
#endif

#ifdef INSTANCED
GPU_DECLARE_READONLY_ARRAY_REF(InstanceArray, InstanceGpu);
#ifdef VELOCITY
GPU_DECLARE_READONLY_ARRAY_REF(PreviousInstanceArray, mat4);
#endif
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

#ifdef VELOCITY
// Object-space position under the deformation the view drew last time.
vec3 previous_position(DrawRoot draw, GeometryRoot geometry, uint index) {
    vec3 position = pull_vec3(geometry.positions, index);
#ifdef MORPH
    MorphWeightsGpu morph = MorphWeightsGpu(PreviousPoseGpu(draw.previous_pose).morph);
    position += morph_delta(geometry, morph, index, MORPH_STREAM_POSITION);
#endif
#if defined(SKINNED) || defined(SKINNED_U16)
    mat4 skin = skin_matrix(geometry, PreviousPoseGpu(draw.previous_pose).skin, index);
    position = (skin * vec4(position, 1.0)).xyz;
#endif
    return position;
}
#endif

void write_mesh_outputs(MeshVertexInput vertex, DrawRoot draw, FrameRoot frame, GeometryRoot geometry) {
#ifdef INSTANCED
    InstanceGpu instance = InstanceArray(draw.instance_data).values[gl_InstanceIndex];
    mat4 model = instance.model;
    mat3 normal_matrix = mat3(instance.normal_0.xyz, instance.normal_1.xyz, instance.normal_2.xyz);
#else
    mat4 model = draw.model;
    mat3 normal_matrix = mat3(draw.normal_0.xyz, draw.normal_1.xyz, draw.normal_2.xyz);
#endif
    vec4 world = model * vec4(vertex.position, 1.0);
#ifdef VELOCITY
    vec4 previous = vec4(previous_position(draw, geometry, uint(gl_VertexIndex)), 1.0);
#ifdef INSTANCED
    // Without previous instance matrices, prev_model is the batch node's motion after the current instance matrix.
    uint64_t previous_instances = PreviousPoseGpu(draw.previous_pose).instances;
    v_prev_clip_pos = previous_instances != 0ul
        ? frame.prev_view_proj * (PreviousInstanceArray(previous_instances).values[gl_InstanceIndex] * previous)
        : frame.prev_view_proj * (draw.prev_model * (model * previous));
#else
    v_prev_clip_pos = frame.prev_view_proj * (draw.prev_model * previous);
#endif
#endif
#if !defined(DEPTH_ONLY) && !defined(VELOCITY)
    v_world_pos = world.xyz;
    v_normal = normalize(normal_matrix * vertex.normal);
    v_tangent = (geometry.flags & GEOMETRY_HAS_TANGENTS) != 0u
        ? world_tangent(model, vertex.tangent)
        : vec4(0.0);
#endif
    v_uv0 = vertex.uv0;
    v_uv1 = vertex.uv1;
    v_color = vertex.color;
#ifdef INSTANCED
    v_color *= instance.color;
#endif
    vec4 clip = frame.view_proj * world;
    gl_Position = clip;
#ifdef VELOCITY
    // Velocity is unjittered: remove the view's jitter from the rasterized position.
    clip.xy -= frame.jitter_time.xy * clip.w;
#endif
    v_clip_pos = clip;
}

#endif
