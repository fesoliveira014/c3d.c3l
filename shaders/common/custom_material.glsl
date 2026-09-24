#ifndef C3D_CUSTOM_MATERIAL_GLSL
#define C3D_CUSTOM_MATERIAL_GLSL

#include "material_maps.glsl"
#include "material_alpha.glsl"

vec4 sample_custom_map(CustomMaterialGpu material, uint slot, vec2 uv0, vec2 uv1) {
    TextureMapGpu map = material.slots[slot];
    return sample_texture_2d_implicit(map.texture_index, map.sampler_index, custom_map_uv(material, slot, uv0, uv1));
}

// Biased by FrameRoot.mip_bias when the caller passes it; the depth prepass cuts coverage unbiased.
vec4 sample_custom_map(CustomMaterialGpu material, uint slot, vec2 uv0, vec2 uv1, float bias) {
    TextureMapGpu map = material.slots[slot];
    return sample_texture_2d_bias(map.texture_index, map.sampler_index, custom_map_uv(material, slot, uv0, uv1), bias);
}

#endif
