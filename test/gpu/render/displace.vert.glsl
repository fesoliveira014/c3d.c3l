#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "mesh_vertex.glsl"
#include "test/displace.glsl"

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer DisplaceParams {
    vec4 color;
    vec4 motion;
};

void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    DisplaceParams params = DisplaceParams(material.parameters);
    uint index = uint(gl_VertexIndex);
#ifdef INSTANCED
    float instance_x = InstanceArray(draw.instance_data).values[instance_source(draw)].model[3].x;
#else
    float instance_x = 0.0;
#endif

    MeshVertexInput vertex = pull_mesh_vertex(geometry, index);
    vertex.position = displace_position(vertex.position, frame.jitter_time.z, params.motion, instance_x);
    write_mesh_outputs(vertex, draw, frame, geometry);
}
