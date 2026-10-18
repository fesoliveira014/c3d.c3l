#ifndef C3D_MATERIAL_MAPS_GLSL
#define C3D_MATERIAL_MAPS_GLSL

#include "material_uv.glsl"
#include "descriptor_heap.glsl"

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

// The gradients take the map's linear transform as the uv does, and the bias as a scale: bias b adds b to the level.
vec4 sample_map_grad(TextureMapGpu map, vec2 uv, vec2 uv_dx, vec2 uv_dy) {
    float gradient_scale = exp2(material_mip_bias);
    vec2 transformed_dx = vec2(dot(map.uv_linear.xy, uv_dx), dot(map.uv_linear.zw, uv_dx));
    vec2 transformed_dy = vec2(dot(map.uv_linear.xy, uv_dy), dot(map.uv_linear.zw, uv_dy));
    return textureGrad(
        sampler2D(
            gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(map.texture_index))],
            gpu_sampler_heap[nonuniformEXT(GPU_HEAP_SLOT(map.sampler_index))]),
        vec2(dot(map.uv_linear.xy, uv), dot(map.uv_linear.zw, uv)) + map.uv_offset,
        transformed_dx * gradient_scale,
        transformed_dy * gradient_scale);
}

#endif
