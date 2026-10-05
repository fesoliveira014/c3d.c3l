#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer OverlayItems {
    OverlayItemGpu values[];
};

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(location = 0) flat out uint v_item;

const vec2 QUAD_CORNERS[OVERLAY_QUAD_VERTICES] = vec2[](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(0.0, 1.0), vec2(1.0, 0.0), vec2(1.0, 1.0)
);

void main() {
    OverlayRoot root = OverlayRoot(pc.vertex_root_gpu);
    vec4 bounds = OverlayItems(root.items).values[gl_InstanceIndex].bounds;

    // The margin leaves room for the antialiased edge, which fades out half a pixel past the bounds.
    vec2 low = bounds.xy - OVERLAY_EDGE_PIXELS;
    vec2 high = bounds.zw + OVERLAY_EDGE_PIXELS;
    vec2 position = mix(low, high, QUAD_CORNERS[gl_VertexIndex]);

    gl_Position = vec4(position * root.scale + root.translate, 0.0, 1.0);
    v_item = uint(gl_InstanceIndex);
}
