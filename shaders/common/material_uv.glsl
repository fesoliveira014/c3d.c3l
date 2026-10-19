#ifndef C3D_MATERIAL_UV_GLSL
#define C3D_MATERIAL_UV_GLSL

vec2 map_uv(TextureMapGpu map, uint flags, uint map_bit, vec2 uv0, vec2 uv1) {
    vec2 uv = (flags & (map_bit << MATERIAL_MAP_UV1_SHIFT)) != 0u ? uv1 : uv0;
    return vec2(dot(map.uv_linear.xy, uv), dot(map.uv_linear.zw, uv)) + map.uv_offset;
}

// A view-provided slot is never present without a frame: its texture belongs to the drawing view.
bool custom_slot_present(CustomMaterialGpu material, uint slot) {
    return (material.map_flags & (1u << slot)) != 0u;
}

bool custom_slot_view_provided(CustomMaterialGpu material, uint slot) {
    return (material.slots[slot].texture_index & VIEW_TEXTURE_FLAG) != 0u;
}

// The slot's own texture index, or the drawing view's texture for a view-provided slot; zero when the view has none.
uint custom_slot_texture(FrameRoot frame, CustomMaterialGpu material, uint slot) {
    uint index = material.slots[slot].texture_index;
    return (index & VIEW_TEXTURE_FLAG) != 0u ? frame.view_textures[index & ~VIEW_TEXTURE_FLAG] : index;
}

bool custom_slot_present(FrameRoot frame, CustomMaterialGpu material, uint slot) {
    return custom_slot_view_provided(material, slot)
        ? custom_slot_texture(frame, material, slot) != 0u
        : custom_slot_present(material, slot);
}

vec2 custom_map_uv(CustomMaterialGpu material, uint slot, vec2 uv0, vec2 uv1) {
    TextureMapGpu map = material.slots[slot];
    vec2 uv = (material.map_flags & (1u << (slot + CUSTOM_MAP_UV1_SHIFT))) != 0u ? uv1 : uv0;
    return vec2(dot(map.uv_linear.xy, uv), dot(map.uv_linear.zw, uv)) + map.uv_offset;
}

#endif
