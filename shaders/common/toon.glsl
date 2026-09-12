#ifndef C3D_TOON_GLSL
#define C3D_TOON_GLSL

#include "descriptor_heap.glsl"

float toon_response(ToonMaterialGpu material, float normal_light) {
    if (normal_light <= 0.0) return 0.0;

    float cosine = clamp(normal_light, 0.0, 1.0);
    if ((material.map_flags & TOON_MAP_GRADIENT) != 0u) {
        return clamp(sample_texture_2d(
            material.gradient_texture,
            material.gradient_sampler,
            vec2(cosine, 0.5)
        ).r, 0.0, 1.0);
    }

    float bands = float(material.steps);
    return min(floor(cosine * bands), bands - 1.0) / (bands - 1.0);
}

vec3 toon_rim(ToonMaterialGpu material, vec3 normal, vec3 view_direction) {
    float facing = clamp(dot(normal, view_direction), 0.0, 1.0);
    return material.rim_color_strength.rgb * material.rim_color_strength.w
        * pow(1.0 - facing, material.rim_power);
}

#endif
