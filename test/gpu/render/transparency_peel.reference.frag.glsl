#version 460
#extension GL_EXT_buffer_reference : require
#include "generated/shader_abi.glsl"

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ReferenceRoot {
    uint64_t surfaces;
    uint first;
};
layout(push_constant) uniform Push { uint64_t vertex_root; uint64_t fragment_root; } pc;
#ifdef MESH_VERTEX_PATH
layout(location = 0) in vec3 mesh_world;
layout(location = 1) in vec3 mesh_normal;
layout(location = 2) in vec4 mesh_tangent;
layout(location = 3) in vec2 mesh_uv0;
layout(location = 4) in vec2 mesh_uv1;
layout(location = 5) in vec4 mesh_color;
layout(location = 6) in vec4 mesh_clip;
layout(location = 8) flat in uint surface_index;
#else
layout(location = 0) flat in uint surface_index;
#endif
layout(location = 0) out float raster_depth;
layout(location = 1) out float stage_depth;

void main() {
    if (surface_index != ReferenceRoot(pc.fragment_root).first) discard;
#ifdef MESH_VERTEX_PATH
    if (any(isnan(mesh_world)) || any(isnan(mesh_normal)) || any(isnan(mesh_tangent))
        || any(isnan(mesh_uv0)) || any(isnan(mesh_uv1)) || any(isnan(mesh_color)) || any(isnan(mesh_clip))) discard;
#endif
    raster_depth = gl_FragCoord.z;
    stage_depth = gl_FragCoord.z;
}
