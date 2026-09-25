#ifndef C3D_TEXTURE_FETCH_GLSL
#define C3D_TEXTURE_FETCH_GLSL

#include "descriptor_heap.glsl"

vec4 fetch_texture_2d(uint texture_index, ivec2 texel) {
    return texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(texture_index))], texel, 0);
}

ivec2 texture_extent(uint texture_index) {
    return textureSize(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(texture_index))], 0);
}

vec4 sample_texture_2d_lod(uint texture_index, uint sampler_index, vec2 uv, float lod) {
    return textureLod(
        sampler2D(
            gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(texture_index))],
            gpu_sampler_heap[nonuniformEXT(GPU_HEAP_SLOT(sampler_index))]),
        uv,
        lod);
}

#endif
