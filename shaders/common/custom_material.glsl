#ifndef C3D_CUSTOM_MATERIAL_GLSL
#define C3D_CUSTOM_MATERIAL_GLSL

#include "material_maps.glsl"
#include "material_alpha.glsl"

// Without a frame a view-provided slot reads as absent: white.
vec4 sample_custom_map(CustomMaterialGpu material, uint slot, vec2 uv0, vec2 uv1) {
    if (custom_slot_view_provided(material, slot)) return vec4(1.0);
    TextureMapGpu map = material.slots[slot];
    return sample_texture_2d_implicit(map.texture_index, map.sampler_index, custom_map_uv(material, slot, uv0, uv1));
}

// Biased by FrameRoot.mip_bias when the caller passes it; the depth prepass cuts coverage unbiased.
vec4 sample_custom_map(CustomMaterialGpu material, uint slot, vec2 uv0, vec2 uv1, float bias) {
    if (custom_slot_view_provided(material, slot)) return vec4(1.0);
    TextureMapGpu map = material.slots[slot];
    return sample_texture_2d_bias(map.texture_index, map.sampler_index, custom_map_uv(material, slot, uv0, uv1), bias);
}

// With the frame, a view-provided slot samples the drawing view's texture, or reads as absent (white) without one.
vec4 sample_custom_map(FrameRoot frame, CustomMaterialGpu material, uint slot, vec2 uv0, vec2 uv1) {
    uint texture_index = custom_slot_texture(frame, material, slot);
    if (texture_index == 0u) return vec4(1.0);
    TextureMapGpu map = material.slots[slot];
    return sample_texture_2d_implicit(texture_index, map.sampler_index, custom_map_uv(material, slot, uv0, uv1));
}

vec4 sample_custom_map(FrameRoot frame, CustomMaterialGpu material, uint slot, vec2 uv0, vec2 uv1, float bias) {
    uint texture_index = custom_slot_texture(frame, material, slot);
    if (texture_index == 0u) return vec4(1.0);
    TextureMapGpu map = material.slots[slot];
    return sample_texture_2d_bias(texture_index, map.sampler_index, custom_map_uv(material, slot, uv0, uv1), bias);
}

// An unused reference is address zero: read only the references the material sets.
StandardMaterialGpu custom_reference(CustomMaterialGpu material, uint index) {
    return StandardMaterialRoot(material.references[index]).material;
}

#endif
