#ifndef C3D_AMBIENT_OCCLUSION_GLSL
#define C3D_AMBIENT_OCCLUSION_GLSL

#include "texture_fetch.glsl"

float frame_ambient_occlusion(FrameRoot frame, ivec2 pixel) {
    if ((frame.flags & FRAME_AO_PRESENT) == 0u) return 1.0;
    return fetch_texture_2d(frame.ao_texture, pixel).r;
}

float draw_ambient_occlusion(FrameRoot frame, uint draw_flags, ivec2 pixel) {
    if ((draw_flags & DRAW_SCREEN_SPACE_TERMS) == 0u) return 1.0;
    return frame_ambient_occlusion(frame, pixel);
}

// Lagarde 2014, on linear roughness as Filament applies it.
float specular_occlusion(float normal_view, float ambient_occlusion, float perceptual_roughness) {
    float roughness = perceptual_roughness * perceptual_roughness;
    float power = exp2(-16.0 * roughness - 1.0);
    return clamp(pow(normal_view + ambient_occlusion, power) - 1.0 + ambient_occlusion, 0.0, 1.0);
}

// The estimate and the blur read the same depth texel for an AO texel.
ivec2 ao_depth_texel(ivec2 ao_texel, ivec2 ao_extent, ivec2 depth_extent) {
    vec2 uv = (vec2(ao_texel) + 0.5) / vec2(ao_extent);
    return min(ivec2(uv * vec2(depth_extent)), depth_extent - 1);
}

// Included here so shaders that include this file ahead of gbuffer.glsl keep their function order.
#include "gbuffer.glsl"

// The world bent normal travels in the green and blue channels as an octahedral pair remapped to 0 to 1.
vec2 ao_pack_bent_normal(vec3 bent_normal) {
    return encode_octahedral(bent_normal) * 0.5 + 0.5;
}

vec3 ao_unpack_bent_normal(vec2 stored) {
    return decode_octahedral(stored * 2.0 - 1.0);
}

// The unit direction of a summed vector, or the fallback when the sum has cancelled out.
vec3 ao_direction_or(vec3 sum, vec3 fallback) {
    const float min_length = 1e-4;
    float sum_length = length(sum);
    return sum_length < min_length ? fallback : sum / sum_length;
}

// The pixel's world bent normal when the view's ao holds one, else the given normal.
vec3 frame_bent_normal(FrameRoot frame, ivec2 pixel, vec3 normal) {
    if ((frame.flags & FRAME_AO_BENT_NORMALS) == 0u) return normal;
    return ao_unpack_bent_normal(fetch_texture_2d(frame.ao_texture, pixel).gb);
}

vec3 draw_bent_normal(FrameRoot frame, uint draw_flags, ivec2 pixel, vec3 normal) {
    if ((draw_flags & DRAW_SCREEN_SPACE_TERMS) == 0u) return normal;
    return frame_bent_normal(frame, pixel, normal);
}

#endif
