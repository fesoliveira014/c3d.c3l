#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "vertex_pull.glsl"
#ifndef DEPTH_ONLY
#include "normal_mapping.glsl"
#endif

layout(location = 0) out vec3 v_world_pos;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec4 v_tangent;
layout(location = 3) out vec2 v_uv0;
layout(location = 4) out vec2 v_uv1;
layout(location = 5) out vec4 v_color;
layout(location = 6) out vec4 v_clip_pos;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    FrameRoot frame = FrameRoot(draw.frame);
    uint index = uint(gl_VertexIndex);

    vec3 position = pull_vec3(geometry.positions, index);
#ifndef DEPTH_ONLY
    vec3 normal = (geometry.flags & GEOMETRY_HAS_NORMALS) != 0u
        ? pull_vec3(geometry.normals, index)
        : vec3(0.0, 0.0, 1.0);
#endif
    vec2 uv0 = (geometry.flags & GEOMETRY_HAS_UV0) != 0u ? pull_vec2(geometry.uv0, index) : vec2(0.0);

    vec4 world = draw.model * vec4(position, 1.0);
#ifndef DEPTH_ONLY
    mat3 normal_matrix = mat3(draw.normal_0.xyz, draw.normal_1.xyz, draw.normal_2.xyz);
    v_world_pos = world.xyz;
    v_normal = normalize(normal_matrix * normal);
    v_tangent = (geometry.flags & GEOMETRY_HAS_TANGENTS) != 0u
        ? world_tangent(draw.model, pull_vec4(geometry.tangents, index))
        : vec4(0.0);
#endif
    v_uv0 = uv0;
    v_uv1 = (geometry.flags & GEOMETRY_HAS_UV1) != 0u ? pull_vec2(geometry.uv1, index) : vec2(0.0);
    v_color = vec4(1.0);
    v_clip_pos = frame.view_proj * world;
    gl_Position = v_clip_pos;
}
