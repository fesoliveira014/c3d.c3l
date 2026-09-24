#ifndef C3D_MATERIAL_UV_GLSL
#define C3D_MATERIAL_UV_GLSL

vec2 map_uv(TextureMapGpu map, uint flags, uint map_bit, vec2 uv0, vec2 uv1) {
    vec2 uv = (flags & (map_bit << MATERIAL_MAP_UV1_SHIFT)) != 0u ? uv1 : uv0;
    return vec2(dot(map.uv_linear.xy, uv), dot(map.uv_linear.zw, uv)) + map.uv_offset;
}

bool custom_slot_present(CustomMaterialGpu material, uint slot) {
    return (material.map_flags & (1u << slot)) != 0u;
}

vec2 custom_map_uv(CustomMaterialGpu material, uint slot, vec2 uv0, vec2 uv1) {
    TextureMapGpu map = material.slots[slot];
    vec2 uv = (material.map_flags & (1u << (slot + CUSTOM_MAP_UV1_SHIFT))) != 0u ? uv1 : uv0;
    return vec2(dot(map.uv_linear.xy, uv), dot(map.uv_linear.zw, uv)) + map.uv_offset;
}

#endif
