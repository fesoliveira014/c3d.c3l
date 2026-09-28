#ifndef C3D_SCREEN_SPACE_GI_GLSL
#define C3D_SCREEN_SPACE_GI_GLSL

#include "gbuffer.glsl"
#include "texture_fetch.glsl"

// Premultiplied bounce and hit share of the pixel; the filter already scaled both by the view's intensity.
vec4 frame_screen_space_indirect(FrameRoot frame, ivec2 pixel) {
    if ((frame.flags & FRAME_SSGI_PRESENT) == 0u) return vec4(0.0);
    return fetch_texture_2d(frame.ssgi_texture, pixel);
}

// The image describes the opaque surface of the pixel, so draws outside the prepass set take none of it.
vec4 draw_screen_space_indirect(FrameRoot frame, uint draw_flags, ivec2 pixel) {
    if ((draw_flags & DRAW_AMBIENT_OCCLUSION) == 0u) return vec4(0.0);
    return frame_screen_space_indirect(frame, pixel);
}

// Mirrored as screen_space_base_share in screen_space_gi.c3: the hit share and AO bound the same occlusion.
float screen_space_base_share(float occlusion, float ambient_occlusion, vec4 screen_indirect) {
    return min(min(occlusion, ambient_occlusion), 1.0 - screen_indirect.a);
}

// Mirrored as ssgi_depth_matches in screen_space_gi.c3: any texel of the 2 x 2 footprint within the tolerance.
bool ssgi_depth_matches(FrameRoot frame, uint depth_texture, vec2 uv, float expected, float tolerance) {
    ivec2 extent = texture_extent(depth_texture);
    ivec2 base = ivec2(floor(uv * vec2(extent) - 0.5));
    ivec2 last = extent - 1;
    float expected_distance = view_distance(frame, expected);
    for (int y = 0; y < 2; y++) {
        for (int x = 0; x < 2; x++) {
            float stored = fetch_texture_2d(depth_texture, clamp(base + ivec2(x, y), ivec2(0), last)).r;
            if (expected == 0.0 && stored == 0.0) return true;
            if (expected == 0.0 || stored == 0.0) continue;
            if (abs(view_distance(frame, stored) - expected_distance) <= tolerance * expected_distance) return true;
        }
    }
    return false;
}

// Previous-frame uv of a pixel centre through its velocity; the velocity excludes the frame's jitter.
vec2 ssgi_previous_uv(FrameRoot frame, vec2 uv, vec4 velocity) {
    return uv - frame.jitter_time.xy * vec2(0.5, -0.5) - velocity.xy;
}

bool ssgi_uv_inside(vec2 uv) {
    return all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)));
}

#endif
