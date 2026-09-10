vec2 map_uv(TextureMapGpu map, uint flags, uint map_bit, vec2 uv0, vec2 uv1) {
    vec2 uv = (flags & (map_bit << MATERIAL_MAP_UV1_SHIFT)) != 0u ? uv1 : uv0;
    return vec2(dot(map.uv_linear.xy, uv), dot(map.uv_linear.zw, uv)) + map.uv_offset;
}

vec4 sample_map(TextureMapGpu map, uint flags, uint map_bit, vec2 uv0, vec2 uv1) {
    return sample_texture_2d_implicit(map.texture_index, map.sampler_index, map_uv(map, flags, map_bit, uv0, uv1));
}
