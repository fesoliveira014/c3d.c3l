#ifndef C3D_DEPTH_FACE_GLSL
#define C3D_DEPTH_FACE_GLSL

#include "gbuffer.glsl"
#include "texture_fetch.glsl"

#ifdef MULTISAMPLE
#include "multisample_heap.glsl"

#define DEPTH_FACE_EXTENT(depth_texture) textureSize(gpu_texture_ms_heap[nonuniformEXT(GPU_HEAP_SLOT(depth_texture))])

#ifdef MULTISAMPLE_PIXEL
// A pixel-rate invocation shades sample 0 and cannot read SampleId or SamplePosition, which would force sample rate.
#define DEPTH_FACE_FETCH(depth_texture, texel) gpu_fetch_ms(depth_texture, texel, 0).r
#define DEPTH_FACE_TEXEL_OFFSET(depth_texture) depth_face_sample_zero_position(depth_texture)

// Vulkan's standard sample locations of sample 0, in pixels from the top-left corner.
vec2 depth_face_sample_zero_position(uint depth_texture) {
    int samples = textureSamples(gpu_texture_ms_heap[nonuniformEXT(GPU_HEAP_SLOT(depth_texture))]);
    if (samples == 2) return vec2(0.25, 0.25);
    if (samples == 4) return vec2(0.375, 0.125);
    if (samples == 8) return vec2(0.5625, 0.3125);
    return vec2(0.5);
}
#else
// A sample-rate invocation shades one sample: depth reads take its index and texel positions its offset in the pixel.
#define DEPTH_FACE_FETCH(depth_texture, texel) gpu_fetch_ms(depth_texture, texel, gl_SampleID).r
#define DEPTH_FACE_TEXEL_OFFSET(depth_texture) gl_SamplePosition
#endif
#else
#define DEPTH_FACE_FETCH(depth_texture, texel) fetch_texture_2d(depth_texture, texel).r
#define DEPTH_FACE_EXTENT(depth_texture) texture_extent(depth_texture)
#define DEPTH_FACE_TEXEL_OFFSET(depth_texture) 0.5
#endif

const float DEPTH_FACE_SIDE_MISSING = 1e30; // error of a side that leaves the image or meets the background

vec3 depth_face_texel_position(
    FrameRoot frame,
    uint depth_texture,
    ivec2 texel,
    ivec2 extent,
    float depth
) {
    return reconstruct_world_position(
        frame,
        (vec2(texel) + DEPTH_FACE_TEXEL_OFFSET(depth_texture)) / vec2(extent),
        depth
    );
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
    side_depth = DEPTH_FACE_FETCH(depth_texture, texel + side);
    float far_depth = DEPTH_FACE_FETCH(depth_texture, far_texel);
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
        return depth_face_texel_position(frame, depth_texture, texel + axis, extent, forward_depth) - centre;
    }
    return centre - depth_face_texel_position(frame, depth_texture, texel - axis, extent, backward_depth);
}

// World-space face under the texel from depth alone, turned toward the camera.
vec3 depth_face_normal(
    FrameRoot frame,
    uint depth_texture,
    ivec2 texel,
    float depth,
    vec3 toward_camera
) {
    ivec2 extent = DEPTH_FACE_EXTENT(depth_texture);
    vec3 centre = depth_face_texel_position(frame, depth_texture, texel, extent, depth);
    vec3 across = depth_face_axis_step(frame, depth_texture, texel, extent, ivec2(1, 0), depth, centre);
    vec3 down = depth_face_axis_step(frame, depth_texture, texel, extent, ivec2(0, 1), depth, centre);
    vec3 normal = cross(down, across);
    float normal_length = length(normal);
    if (normal_length == 0.0) return toward_camera;
    normal /= normal_length;
    return dot(normal, toward_camera) < 0.0 ? -normal : normal;
}

#endif
