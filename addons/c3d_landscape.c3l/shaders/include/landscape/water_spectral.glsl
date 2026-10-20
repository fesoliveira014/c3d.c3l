#ifndef LANDSCAPE_WATER_SPECTRAL_GLSL
#define LANDSCAPE_WATER_SPECTRAL_GLSL

#include "texture_fetch.glsl"
#include "landscape/water_waves.glsl"

const uint WATER_SPECTRAL_DISPLACEMENT_SLOT = 1u; // mirrored as SPECTRAL_DISPLACEMENT_SLOT in water/material.c3
const uint WATER_SPECTRAL_SLOPE_SLOT = 2u; // mirrored as SPECTRAL_SLOPE_SLOT in water/material.c3
const uint WATER_SPECTRAL_PREVIOUS_SLOT = 3u; // mirrored as SPECTRAL_PREVIOUS_SLOT in water/material.c3

// A field image of a spectral body at a rest point. The sampler repeats, so the tiles of the field meet.
vec4 water_field(CustomMaterialGpu material, uint slot, WaterParams params, vec2 rest) {
    TextureMapGpu map = material.slots[slot];
    vec2 coordinates = rest * params.field_scale + params.field_offset;
    return sample_texture_2d_lod(map.texture_index, map.sampler_index, coordinates, 0.0);
}

// Where the field of this frame or of the frame before draws a rest point. The image holds x, y and z displacement.
vec3 water_spectral_position(CustomMaterialGpu material, WaterParams params, uint slot, vec2 rest) {
    vec3 offset = water_field(material, slot, params, rest).xyz;
    return vec3(rest.x + offset.x, offset.y, rest.y + offset.z);
}

// The surface point the field draws at a rest point. The normal leans against the slope; the field has no crest factor.
WaterSurfacePoint water_spectral_point(CustomMaterialGpu material, WaterParams params, vec2 rest) {
    vec2 slope = water_field(material, WATER_SPECTRAL_SLOPE_SLOT, params, rest).xy;
    WaterSurfacePoint point;
    point.position = water_spectral_position(material, params, WATER_SPECTRAL_DISPLACEMENT_SLOT, rest);
    point.tangent = normalize(vec3(1.0, slope.x, 0.0));
    point.normal = normalize(vec3(-slope.x, 1.0, -slope.y));
    point.crest = 0.0;
    return point;
}

// Where the field of the frame before drew the rest point.
vec3 water_spectral_previous_position(CustomMaterialGpu material, WaterParams params, vec2 rest) {
    return water_spectral_position(material, params, WATER_SPECTRAL_PREVIOUS_SLOT, rest);
}

#endif
