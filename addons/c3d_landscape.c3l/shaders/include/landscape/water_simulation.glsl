#ifndef LANDSCAPE_WATER_SIMULATION_GLSL
#define LANDSCAPE_WATER_SIMULATION_GLSL

#include "texture_fetch.glsl"
#include "landscape/water_waves.glsl"

const uint WATER_SIMULATION_SLOT = 1u; // mirrored as SIMULATION_SLOT in water/material.c3

// A simulated body's heights at a vertex of its grid: x the height drawn this frame, y the one drawn the frame before.
// The grid repeats its edge texels; the fetch is unfiltered, so the stored floats are read as written.
vec2 water_grid_heights(uint grid_texture, WaterParams params, ivec2 texel) {
    ivec2 last = ivec2(int(params.grid_texels) - 1);
    return fetch_texture_2d(grid_texture, clamp(texel, ivec2(0), last)).xy;
}

// The grid vertex a mesh vertex of the built grid stands on: the grid stores its vertices row by row.
ivec2 water_grid_texel(WaterParams params, uint vertex_index) {
    return ivec2(int(vertex_index % params.grid_texels), int(vertex_index / params.grid_texels));
}

// Slope of the drawn height along x and z: central differences, one-sided at the edges. Twin of vertex_normal in
// water/simulation.c3.
vec2 water_grid_slope(uint grid_texture, WaterParams params, ivec2 texel) {
    int last = int(params.grid_texels) - 1;
    ivec2 low = max(texel - 1, 0);
    ivec2 high = min(texel + 1, last);
    float west = water_grid_heights(grid_texture, params, ivec2(low.x, texel.y)).x;
    float east = water_grid_heights(grid_texture, params, ivec2(high.x, texel.y)).x;
    float north = water_grid_heights(grid_texture, params, ivec2(texel.x, low.y)).x;
    float south = water_grid_heights(grid_texture, params, ivec2(texel.x, high.y)).x;
    return vec2(east - west, south - north) / (vec2(high - low) * params.grid_spacing);
}

// The grid vertex as the vertex stage draws it. The simulation has no crest factor.
WaterSurfacePoint water_simulated_point(WaterParams params, uint grid_texture, uint vertex_index, vec2 rest) {
    ivec2 texel = water_grid_texel(params, vertex_index);
    vec2 slope = water_grid_slope(grid_texture, params, texel);
    WaterSurfacePoint point;
    point.position = vec3(rest.x, water_grid_heights(grid_texture, params, texel).x, rest.y);
    point.tangent = normalize(vec3(1.0, slope.x, 0.0));
    point.normal = normalize(vec3(-slope.x, 1.0, -slope.y));
    point.crest = 0.0;
    return point;
}

// Where the grid vertex was drawn the frame before.
vec3 water_simulated_previous_position(WaterParams params, uint grid_texture, uint vertex_index, vec2 rest) {
    return vec3(rest.x, water_grid_heights(grid_texture, params, water_grid_texel(params, vertex_index)).y, rest.y);
}

#endif
