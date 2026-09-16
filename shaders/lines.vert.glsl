#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer DebugVertices {
    DebugVertexGpu values[];
};

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(location = 0) out vec4 v_color;

void main() {
    DebugLinesRoot root = DebugLinesRoot(pc.vertex_root_gpu);
    DebugVertexGpu vertex = DebugVertices(root.vertices).values[gl_VertexIndex];

    gl_Position = root.view_proj * vec4(vertex.x, vertex.y, vertex.z, 1.0);
    v_color = unpackUnorm4x8(vertex.rgba);
}
