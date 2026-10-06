#ifndef C3D_DEPTH_FACE_GLSL
#define C3D_DEPTH_FACE_GLSL

#include "gbuffer.glsl"
#include "texture_fetch.glsl"

const float DEPTH_FACE_SIDE_MISSING = 1e30; // error of a side that leaves the image or meets the background

vec3 depth_face_texel_position(
    FrameRoot frame,
    ivec2 texel,
    ivec2 extent,
    float depth
) {
    return reconstruct_world_position(frame, (vec2(texel) + 0.5) / vec2(extent), depth);
}

// Depth is linear in screen space across a plane, so a side whose two texels extrapolate to the
// centre's depth lies on the centre's face; a crease or a silhouette breaks the line.
float depth_face_side_error(
    uint depth_texture,
    ivec2 texel,
    ivec2 extent,
    ivec2 side,
    float depth,
    out float side_depth
) {
    side_depth = 0.0;
    ivec2 far_texel = texel + 2 * side;
    if (any(lessThan(far_texel, ivec2(0))) || any(greaterThanEqual(far_texel, extent))) return DEPTH_FACE_SIDE_MISSING;
    side_depth = fetch_texture_2d(depth_texture, texel + side).r;
    float far_depth = fetch_texture_2d(depth_texture, far_texel).r;
    if (side_depth == 0.0 || far_depth == 0.0) return DEPTH_FACE_SIDE_MISSING;
    return abs(2.0 * side_depth - far_depth - depth);
}

vec3 depth_face_axis_step(
    FrameRoot frame,
    uint depth_texture,
    ivec2 texel,
    ivec2 extent,
    ivec2 axis,
    float depth,
    vec3 centre
) {
    float forward_depth;
    float backward_depth;
    float forward_error = depth_face_side_error(depth_texture, texel, extent, axis, depth, forward_depth);
    float backward_error = depth_face_side_error(depth_texture, texel, extent, -axis, depth, backward_depth);
    if (min(forward_error, backward_error) == DEPTH_FACE_SIDE_MISSING) return vec3(0.0);
    if (forward_error <= backward_error) {
        return depth_face_texel_position(frame, texel + axis, extent, forward_depth) - centre;
    }
    return centre - depth_face_texel_position(frame, texel - axis, extent, backward_depth);
}

// World-space face under the texel from depth alone, turned toward the camera.
vec3 depth_face_normal(
    FrameRoot frame,
    uint depth_texture,
    ivec2 texel,
    float depth,
    vec3 toward_camera
) {
    ivec2 extent = texture_extent(depth_texture);
    vec3 centre = depth_face_texel_position(frame, texel, extent, depth);
    vec3 across = depth_face_axis_step(frame, depth_texture, texel, extent, ivec2(1, 0), depth, centre);
    vec3 down = depth_face_axis_step(frame, depth_texture, texel, extent, ivec2(0, 1), depth, centre);
    vec3 normal = cross(down, across);
    float normal_length = length(normal);
    if (normal_length == 0.0) return toward_camera;
    normal /= normal_length;
    return dot(normal, toward_camera) < 0.0 ? -normal : normal;
}

#endif
