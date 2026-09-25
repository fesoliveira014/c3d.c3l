#ifndef C3D_AO_ESTIMATE_GLSL
#define C3D_AO_ESTIMATE_GLSL

#include "gbuffer.glsl"
#include "texture_fetch.glsl"

const float AO_FALLOFF_FRACTION = 0.6; // outer share of the radius where occluders fade out; hides the cut-off ring

// Weight of an occluder at a distance: full inside the inner share of the radius, zero at the radius.
float ao_falloff(float distance, float radius) {
    float falloff_range = radius * AO_FALLOFF_FRACTION;
    return clamp(1.0 - (distance - (radius - falloff_range)) / falloff_range, 0.0, 1.0);
}

vec3 ao_view_position(
    FrameRoot frame,
    ivec2 texel,
    ivec2 extent,
    float depth
) {
    vec2 uv = (vec2(texel) + 0.5) / vec2(extent);
    return (frame.view * vec4(reconstruct_world_position(frame, uv, depth), 1.0)).xyz;
}

// Per axis the neighbour on the same surface: the one nearer in view distance.
vec3 ao_neighbour_offset(
    FrameRoot frame,
    uint depth_texture,
    ivec2 texel,
    ivec2 extent,
    ivec2 axis_step,
    vec3 position
) {
    ivec2 forward_texel = clamp(texel + axis_step, ivec2(0), extent - 1);
    ivec2 backward_texel = clamp(texel - axis_step, ivec2(0), extent - 1);
    float forward_depth = fetch_texture_2d(depth_texture, forward_texel).r;
    float backward_depth = fetch_texture_2d(depth_texture, backward_texel).r;
    float centre_distance = -position.z;
    float forward_gap = forward_depth == 0.0
        ? BACKGROUND_VIEW_DISTANCE : abs(view_distance(frame, forward_depth) - centre_distance);
    float backward_gap = backward_depth == 0.0
        ? BACKGROUND_VIEW_DISTANCE : abs(view_distance(frame, backward_depth) - centre_distance);
    if (forward_gap <= backward_gap) {
        if (forward_depth == 0.0) return vec3(0.0);
        return ao_view_position(frame, forward_texel, extent, forward_depth) - position;
    }
    return position - ao_view_position(frame, backward_texel, extent, backward_depth);
}

// View-space normal from depth alone, facing the eye.
vec3 ao_reconstructed_normal(
    FrameRoot frame,
    uint depth_texture,
    ivec2 texel,
    ivec2 extent,
    vec3 position,
    vec3 view_vector
) {
    vec3 right = ao_neighbour_offset(frame, depth_texture, texel, extent, ivec2(1, 0), position);
    vec3 down = ao_neighbour_offset(frame, depth_texture, texel, extent, ivec2(0, 1), position);
    vec3 normal = cross(down, right);
    float normal_length = length(normal);
    if (normal_length == 0.0) return view_vector;
    normal /= normal_length;
    return dot(normal, view_vector) < 0.0 ? -normal : normal;
}

#endif
