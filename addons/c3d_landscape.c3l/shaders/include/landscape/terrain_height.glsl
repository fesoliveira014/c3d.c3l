#ifndef LANDSCAPE_TERRAIN_HEIGHT_GLSL
#define LANDSCAPE_TERRAIN_HEIGHT_GLSL

#include "descriptor_heap.glsl"

const uint TERRAIN_HEIGHT_SLOT = 0u; // mirrored as HEIGHT_SLOT in terrain/material.c3
const uint TERRAIN_CONTROL_SLOT = 1u; // mirrored as CONTROL_SLOT in terrain/material.c3
const float TERRAIN_TEXEL_MAX = 65535.0; // height = height_scale * texel / 65535, the physics height-field rule

// Mirrors TerrainParams in terrain/material.c3.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer TerrainParams {
    uint texels;
    float cell_size;
    float height_scale;
    uint layer_count;
};

// R16_UINT heights: only the integer view of the heap may read them.
float terrain_height(uint height_texture, TerrainParams params, ivec2 texel) {
    ivec2 last = ivec2(int(params.texels) - 1);
    uint value = gpu_fetch_uint(height_texture, clamp(texel, ivec2(0), last), 0);
    return params.height_scale * float(value) / TERRAIN_TEXEL_MAX;
}

#endif
