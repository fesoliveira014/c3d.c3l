#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(location = 8) flat in uvec2 v_sort_order;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer SortOrderParams {
    uint count;
    uint stride;
};

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    SortOrderParams params = SortOrderParams(CustomMaterialGpu(draw.material).parameters);
    uint rank = v_sort_order.x;
    uint source = v_sort_order.y;
    uint expected = params.count - 1u - (source * params.stride) % params.count;
    // Under premultiplied blending a misordered instance adds red; only the farthest adds colour, opaque green.
    if (rank != expected) {
        out_color = vec4(1.0, 0.0, 0.0, 0.0);
        return;
    }
    out_color = rank == 0u ? vec4(0.0, 1.0, 0.0, 1.0) : vec4(0.0);
}
