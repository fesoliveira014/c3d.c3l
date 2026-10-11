#ifndef C3D_SCENE_SNAPSHOT_GLSL
#define C3D_SCENE_SNAPSHOT_GLSL

#include "descriptor_heap.glsl"
#include "texture_fetch.glsl"
#include "gbuffer.glsl"

vec2 scene_uv(FrameRoot frame, vec2 frag_coord) {
    return frag_coord / frame.camera_params.zw;
}

vec3 scene_color_at(FrameRoot frame, vec2 uv) {
    return sample_texture_2d(frame.scene_color, frame.scene_sampler, uv).rgb;
}

// Nearest texel: depth is never filtered across a silhouette.
float scene_depth_at(FrameRoot frame, vec2 uv) {
    ivec2 extent = ivec2(frame.camera_params.zw);
    ivec2 texel = clamp(ivec2(uv * frame.camera_params.zw), ivec2(0), extent - 1);
    return fetch_texture_2d(frame.scene_depth, texel).r;
}

float scene_view_distance_at(FrameRoot frame, vec2 uv) {
    return view_distance(frame, scene_depth_at(frame, uv));
}

// Depth 0 is the background and has no position; test scene_depth_at first.
vec3 scene_position_at(FrameRoot frame, vec2 uv) {
    return reconstruct_world_position(frame, uv, scene_depth_at(frame, uv));
}

float scene_depth_gap(FrameRoot frame, vec4 frag_coord) {
    return scene_view_distance_at(frame, scene_uv(frame, frag_coord.xy)) - view_distance(frame, frag_coord.z);
}

#endif
