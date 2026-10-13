#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer OverlayItems {
    OverlayItemGpu values[];
};

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer OverlayTransforms {
    OverlayTransformGpu values[];
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
    OverlayItemGpu item = OverlayItems(root.items).values[gl_InstanceIndex];
    uint transform_index = item.transform_clip & OVERLAY_TRANSFORM_MASK;

    // The margin leaves room for the antialiased edge, which fades out half a pixel past the bounds.
    vec2 margin = vec2(OVERLAY_EDGE_PIXELS);
    OverlayTransformGpu transform;
    if (transform_index != 0u) {
        transform = OverlayTransforms(root.transforms).values[transform_index];
        // Local units that cover one output pixel across each pair of edges.
        margin *= vec2(
            length(vec2(transform.inverse_x_axis.x, transform.inverse_y_axis.x)),
            length(vec2(transform.inverse_x_axis.y, transform.inverse_y_axis.y)));
    }

    vec2 low = item.bounds.xy - margin;
    vec2 high = item.bounds.zw + margin;
    vec2 position = mix(low, high, QUAD_CORNERS[gl_VertexIndex]);
    if (transform_index != 0u) {
        position = transform.x_axis * position.x + transform.y_axis * position.y + transform.offset;
    }

    gl_Position = vec4(position * root.scale + root.translate, 0.0, 1.0);
    v_item = uint(gl_InstanceIndex);
}
