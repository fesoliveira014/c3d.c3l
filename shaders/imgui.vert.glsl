#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer GuiVertices {
    GuiVertexGpu values[];
};

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;

void main() {
    GuiVertexRoot root = GuiVertexRoot(pc.vertex_root_gpu);
    GuiVertexGpu vertex = GuiVertices(root.vertices).values[gl_VertexIndex];
    vec2 position = vec2(vertex.position_x, vertex.position_y);
    gl_Position = vec4(position * root.scale + root.translate, 0.0, 1.0);
    v_uv = vec2(vertex.uv_x, vertex.uv_y);
    v_color = unpackUnorm4x8(vertex.rgba);
}
