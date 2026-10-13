#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer OverlayItems {
    OverlayItemGpu values[];
};

#ifdef TRANSFORMED
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer OverlayTransforms {
    OverlayTransformGpu values[];
};
#endif

#ifdef WORLD
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer OverlayPlanes {
    OverlayPlaneGpu values[];
};

layout(location = 1) out vec2 v_plane;
#endif

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(location = 0) flat out uint v_item;

const vec2 QUAD_CORNERS[OVERLAY_QUAD_VERTICES] = vec2[](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(0.0, 1.0), vec2(1.0, 0.0), vec2(1.0, 1.0)
);

#ifdef WORLD
// Output pixels per plane unit along the axis, from the derivative of the pixel position with respect to it.
vec2 pixels_per_plane_unit(vec4 axis, vec4 clip, vec2 half_view) {
    return half_view * (vec2(axis.x, -axis.y) * clip.w - vec2(clip.x, -clip.y) * axis.w)
        / max(clip.w * clip.w, 1e-12);
}

// A corner of a plane item in the view's clip space, as the view's rectangle places it in the output.
// The margin is the edge width in item units at the corner.
void place_plane_corner(OverlayWorldRoot root, OverlayTransformGpu transform, uint transform_index, vec4 bounds) {
    OverlayPlaneGpu plane = OverlayPlanes(root.planes).values[transform_index];
    vec2 corner = QUAD_CORNERS[gl_VertexIndex];
    vec2 position = mix(bounds.xy, bounds.zw, corner);
    vec2 half_view = 0.5 * vec2(root.view_width, root.view_height);

    vec2 in_plane = transform.x_axis * position.x + transform.y_axis * position.y + transform.offset;
    vec4 clip = plane.u_axis * in_plane.x + plane.v_axis * in_plane.y + plane.origin;
    vec2 pixels_per_x = pixels_per_plane_unit(plane.u_axis, clip, half_view);
    vec2 pixels_per_y = pixels_per_plane_unit(plane.v_axis, clip, half_view);
    vec2 margin = OVERLAY_EDGE_PIXELS / max(vec2(
        length(pixels_per_x * transform.x_axis.x + pixels_per_y * transform.x_axis.y),
        length(pixels_per_x * transform.y_axis.x + pixels_per_y * transform.y_axis.y)), 1e-6);

    position += (corner * 2.0 - 1.0) * margin;
    in_plane = transform.x_axis * position.x + transform.y_axis * position.y + transform.offset;
    clip = plane.u_axis * in_plane.x + plane.v_axis * in_plane.y + plane.origin;

    vec2 view_center = vec2(root.view_x, root.view_y) + half_view;
    vec2 pixel_times_w = view_center * clip.w + half_view * vec2(clip.x, -clip.y);
    gl_Position = vec4(pixel_times_w * root.scale + root.translate * clip.w, clip.z, clip.w);
    v_plane = in_plane;
}
#endif

void main() {
#ifdef WORLD
    OverlayWorldRoot root = OverlayWorldRoot(pc.vertex_root_gpu);
    v_plane = vec2(0.0);
#else
    OverlayRoot root = OverlayRoot(pc.vertex_root_gpu);
#endif
    vec4 bounds = OverlayItems(root.items).values[gl_InstanceIndex].bounds;

    // The margin leaves room for the antialiased edge, which fades out half a pixel past the bounds.
#ifdef TRANSFORMED
    uint transform_index = OverlayItems(root.items).values[gl_InstanceIndex].transform_clip & OVERLAY_TRANSFORM_MASK;
    vec2 margin = vec2(OVERLAY_EDGE_PIXELS);
    OverlayTransformGpu transform;
    if (transform_index != 0u) {
        transform = OverlayTransforms(root.transforms).values[transform_index];
#ifdef WORLD
        if (transform.plane != 0u) {
            place_plane_corner(root, transform, transform_index, bounds);
            v_item = uint(gl_InstanceIndex);
            return;
        }
#endif
        // Local units that cover one output pixel across each pair of edges.
        margin *= vec2(
            length(vec2(transform.inverse_x_axis.x, transform.inverse_y_axis.x)),
            length(vec2(transform.inverse_x_axis.y, transform.inverse_y_axis.y)));
    }
    vec2 low = bounds.xy - margin;
    vec2 high = bounds.zw + margin;
#else
    vec2 low = bounds.xy - OVERLAY_EDGE_PIXELS;
    vec2 high = bounds.zw + OVERLAY_EDGE_PIXELS;
#endif
    vec2 position = mix(low, high, QUAD_CORNERS[gl_VertexIndex]);
#ifdef TRANSFORMED
    if (transform_index != 0u) {
        position = transform.x_axis * position.x + transform.y_axis * position.y + transform.offset;
    }
#endif

    gl_Position = vec4(position * root.scale + root.translate, 0.0, 1.0);
    v_item = uint(gl_InstanceIndex);
}
