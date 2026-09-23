#ifndef C3D_MATERIAL_MAPS_GLSL
#define C3D_MATERIAL_MAPS_GLSL

vec2 map_uv(TextureMapGpu map, uint flags, uint map_bit, vec2 uv0, vec2 uv1) {
    vec2 uv = (flags & (map_bit << MATERIAL_MAP_UV1_SHIFT)) != 0u ? uv1 : uv0;
    return vec2(dot(map.uv_linear.xy, uv), dot(map.uv_linear.zw, uv)) + map.uv_offset;
}

// Level-of-detail bias of built-in material sampling; a material fragment sets it from FrameRoot.mip_bias.
float material_mip_bias = 0.0;

vec4 sample_texture_2d_bias(uint tex_index, uint smp_index, vec2 uv, float bias) {
    return texture(
        sampler2D(
            gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(tex_index))],
            gpu_sampler_heap[nonuniformEXT(GPU_HEAP_SLOT(smp_index))]),
        uv,
        bias);
}

vec4 sample_map(TextureMapGpu map, uint flags, uint map_bit, vec2 uv0, vec2 uv1) {
    vec2 uv = map_uv(map, flags, map_bit, uv0, uv1);
    return sample_texture_2d_bias(map.texture_index, map.sampler_index, uv, material_mip_bias);
}

#endif
