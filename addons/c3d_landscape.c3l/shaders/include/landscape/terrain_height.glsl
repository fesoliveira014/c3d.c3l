#ifndef LANDSCAPE_TERRAIN_HEIGHT_GLSL
#define LANDSCAPE_TERRAIN_HEIGHT_GLSL

#include "descriptor_heap.glsl"

const uint TERRAIN_HEIGHT_SLOT = 0u; // mirrored as HEIGHT_SLOT in terrain/material.c3
const uint TERRAIN_CONTROL_SLOT = 1u; // mirrored as CONTROL_SLOT in terrain/material.c3
const uint TERRAIN_BORDER_SLOT = 2u; // mirrored as BORDER_SLOT in terrain/material.c3
// Border ring rows and bits of TerrainParams.border_edges; mirrored as BorderEdge in terrain/border.c3.
const uint TERRAIN_BORDER_NORTH = 0u;
const uint TERRAIN_BORDER_SOUTH = 1u;
const uint TERRAIN_BORDER_WEST = 2u;
const uint TERRAIN_BORDER_EAST = 3u;
const uint TERRAIN_CHUNK_CELLS = 128u; // mirrored as CHUNK_CELLS in terrain/terrain.c3
const float TERRAIN_TEXEL_MAX = 65535.0; // height = height_scale * texel / 65535, the physics height-field rule
const uint TERRAIN_PROJECTION_TRIPLANAR = 1u; // mirrored as SlopeProjection.TRIPLANAR in terrain/terrain.c3

// Mirrors TerrainParams in terrain/material.c3.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer TerrainParams {
    uint texels;
    float cell_size;
    float height_scale;
    uint layer_count;
    uint border_edges;
    uint slope_projection;
    float triplanar_sharpness;
    uint padding;
};

// R16_UINT heights: only the integer view of the heap may read them.
float terrain_height(uint height_texture, TerrainParams params, ivec2 texel) {
    ivec2 last = ivec2(int(params.texels) - 1);
    uint value = gpu_fetch_uint(height_texture, clamp(texel, ivec2(0), last), 0);
    return params.height_scale * float(value) / TERRAIN_TEXEL_MAX;
}

// Height one texel past this tile's border; the ring holds the neighbour's texels along each edge.
float terrain_border_height(uint border_texture, TerrainParams params, uint edge, int along) {
    uint value = gpu_fetch_uint(border_texture, ivec2(along, int(edge)), 0);
    return params.height_scale * float(value) / TERRAIN_TEXEL_MAX;
}

bool terrain_has_border(TerrainParams params, uint edge) {
    return (params.border_edges & (1u << edge)) != 0u;
}

#endif
