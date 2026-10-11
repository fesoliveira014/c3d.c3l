#version 460
invariant gl_Position;
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "mesh_vertex.glsl"

layout(location = 7) flat out uint v_receiver_instance;

void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    FrameRoot frame = FrameRoot(draw.frame);
    uint index = uint(gl_VertexIndex);
    MeshVertexInput vertex = pull_mesh_vertex(geometry, index);
    apply_mesh_deformation(vertex, draw, geometry, index);
    write_mesh_outputs(vertex, draw, frame, geometry);
#ifdef INSTANCED
    v_receiver_instance = instance_source(draw);
#else
    v_receiver_instance = 0u;
#endif
}
