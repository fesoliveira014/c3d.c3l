#ifndef C3D_TRANSPARENCY_GLSL
#define C3D_TRANSPARENCY_GLSL

#include "descriptor_heap.glsl"
#include "texture_fetch.glsl"
#include "scene_snapshot.glsl"
#include "material_alpha.glsl"
#include "fog.glsl"

const float TRANSPARENCY_RAY_COSINE_FLOOR = 1e-4; // Keeps grazing projection division finite.

bool layered_transparency_capture(FrameRoot frame) {
    return frame.transparency != 0ul
        && TransparencyGpu(frame.transparency).phase == TRANSPARENCY_CAPTURE;
}

bool layered_transparency_retained(FrameRoot frame) {
    return frame.transparency != 0ul
        && TransparencyGpu(frame.transparency).phase == TRANSPARENCY_RETAINED;
}

FogTerms layered_transparency_connection(FrameRoot frame, vec3 position, float behind_depth) {
    if (frame.sky_fog == 0ul) return fog_none();

    SkyFogGpu sky = SkyFogGpu(frame.sky_fog);
    vec3 origin;
    vec3 direction;
    float near_distance;
    fog_view_ray(frame, position, origin, direction, near_distance);
    vec2 uv = fog_screen_uv(frame, position);
    if (behind_depth == 0.0) {
        return height_fog_beyond(frame, sky, uv, origin, direction, near_distance);
    }

    vec3 forward = -normalize(vec3(frame.view[0][2], frame.view[1][2], frame.view[2][2]));
    float far_distance = max(view_distance(frame, behind_depth)
        / max(dot(direction, forward), TRANSPARENCY_RAY_COSINE_FLOOR), near_distance);
    FogTerms near_terms = fog_terms(frame, uv, position);
    FogTerms far_terms = fog_segment(
        frame,
        sky,
        uv,
        origin,
        direction,
        fog_clip_start(frame, origin, direction),
        far_distance
    );
    return fog_between(near_terms, far_terms);
}

float layered_transparency_continuation_depth(FrameRoot frame, vec2 uv) {
    if (!layered_transparency_retained(frame)) return scene_depth_at(frame, uv);

    TransparencyGpu transparency = TransparencyGpu(frame.transparency);
    ivec2 extent = ivec2(frame.camera_params.zw);
    ivec2 pixel = clamp(ivec2(uv * frame.camera_params.zw), ivec2(0), extent - 1);
    return fetch_texture_2d(transparency.continuation_depth, pixel).r;
}

vec3 layered_transparency_transfer(FrameRoot frame, vec3 position, vec3 radiance, float behind_depth) {
    FogTerms connection = layered_transparency_connection(frame, position, behind_depth);
    return radiance * connection.transmittance + connection.inscatter;
}

vec3 layered_transparency_material_fog(FrameRoot frame, vec3 position, vec3 radiance, uint flags) {
    return layered_transparency_retained(frame)
        ? radiance : apply_material_fog(frame, position, radiance, flags);
}

#ifdef LAYERED
bool layered_transparency_accept(FrameRoot frame, float depth) {
    if (frame.transparency == 0ul) return true;

    TransparencyGpu transparency = TransparencyGpu(frame.transparency);
    if (transparency.phase == TRANSPARENCY_SORTED) return true;

    ivec2 pixel = ivec2(gl_FragCoord.xy);
    if (depth <= fetch_texture_2d(transparency.opaque_depth, pixel).r) return false;

    if (transparency.phase == TRANSPARENCY_CAPTURE) {
        return transparency.previous_depth == 0u
            || depth < fetch_texture_2d(transparency.previous_depth, pixel).r;
    }

    float selected = fetch_texture_2d(transparency.selected_depth, pixel).r;
    if (transparency.phase == TRANSPARENCY_RETAINED) return depth == selected;
    return depth < selected;
}

vec3 layered_transparency_scene_color(FrameRoot frame, vec2 uv, vec3 radiance) {
    if (!layered_transparency_retained(frame)) return radiance;

    vec2 surface_uv = gl_FragCoord.xy / frame.camera_params.zw;
    vec3 position = reconstruct_world_position(frame, surface_uv, gl_FragCoord.z);
    return layered_transparency_transfer(
        frame,
        position,
        radiance,
        layered_transparency_continuation_depth(frame, uv)
    );
}

vec4 layered_transparency_output(FrameRoot frame, vec4 color) {
    return layered_transparency_capture(frame) ? vec4(gl_FragCoord.z, 0.0, 0.0, 1.0) : color;
}
#else
bool layered_transparency_accept(FrameRoot frame, float depth) {
    return true;
}

vec4 layered_transparency_output(FrameRoot frame, vec4 color) {
    return color;
}
#endif

#endif
