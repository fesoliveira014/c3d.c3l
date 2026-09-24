#ifndef C3D_AMBIENT_OCCLUSION_GLSL
#define C3D_AMBIENT_OCCLUSION_GLSL

#include "descriptor_heap.glsl"

vec4 fetch_texture_2d(uint texture_index, ivec2 texel) {
    return texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(texture_index))], texel, 0);
}

ivec2 texture_extent(uint texture_index) {
    return textureSize(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(texture_index))], 0);
}

float frame_ambient_occlusion(FrameRoot frame, ivec2 pixel) {
    if ((frame.flags & FRAME_AO_PRESENT) == 0u) return 1.0;
    return fetch_texture_2d(frame.ao_texture, pixel).r;
}

float draw_ambient_occlusion(FrameRoot frame, uint draw_flags, ivec2 pixel) {
    if ((draw_flags & DRAW_AMBIENT_OCCLUSION) == 0u) return 1.0;
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

#endif
