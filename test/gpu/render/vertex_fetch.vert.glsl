#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "mesh_vertex.glsl"

const float HIDDEN_OFFSET = 10.0; // far outside the view at the camera distance used by the acceptance cases

void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    uint index = uint(gl_VertexIndex);

    TextureMapGpu map = material.slots[0];
    float shown = sample_texture_2d(map.texture_index, map.sampler_index, vec2(0.5)).r;

    MeshVertexInput vertex = pull_mesh_vertex(geometry, index);
    vertex.position.x += (1.0 - shown) * HIDDEN_OFFSET;
    write_mesh_outputs(vertex, draw, frame, geometry);
}
