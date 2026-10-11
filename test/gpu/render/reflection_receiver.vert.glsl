#version 460
invariant gl_Position;
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "mesh_vertex.glsl"

#ifdef INSTANCED
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ReceiverIdentityRoot {
    layout(offset = 0) uint64_t logical_indices;
};
#endif

layout(location = 7) flat out uint v_receiver_instance;
layout(location = 8) flat out uint v_receiver_primitive;

void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    FrameRoot frame = FrameRoot(draw.frame);
    uint invocation = uint(gl_VertexIndex);
    uint primitive = invocation / 3u;
    uvec3 triangle = pull_triangle(geometry, primitive);
    uint index = triangle[invocation % 3u];
    MeshVertexInput vertex = pull_mesh_vertex(geometry, index);
    apply_mesh_deformation(vertex, draw, geometry, index);
    write_mesh_outputs(vertex, draw, frame, geometry);
    v_receiver_primitive = primitive;
#ifdef INSTANCED
    uint source = instance_source(draw);
    uint64_t logical_indices = ReceiverIdentityRoot(draw.instance_effects).logical_indices;
    v_receiver_instance = logical_indices != 0ul ? IndexStream(logical_indices).values[source] : source;
#else
    v_receiver_instance = 0u;
#endif
}
