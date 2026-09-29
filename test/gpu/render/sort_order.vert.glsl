#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "mesh_vertex.glsl"

#ifndef DEPTH_ONLY
layout(location = 8) flat out uvec2 v_sort_order;
#endif

void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    FrameRoot frame = FrameRoot(draw.frame);
    MeshVertexInput vertex = pull_mesh_vertex(geometry, uint(gl_VertexIndex));
    write_mesh_outputs(vertex, draw, frame, geometry);
#if defined(INSTANCED) && !defined(DEPTH_ONLY)
    v_sort_order = uvec2(uint(gl_InstanceIndex), instance_source(draw));
#elif !defined(DEPTH_ONLY)
    v_sort_order = uvec2(0u);
#endif
}
