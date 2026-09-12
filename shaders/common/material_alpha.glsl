#ifndef C3D_MATERIAL_ALPHA_GLSL
#define C3D_MATERIAL_ALPHA_GLSL

vec4 material_output(vec3 color, float alpha, uint flags) {
    if ((flags & MATERIAL_ALPHA_BLEND) != 0u) {
        float coverage = clamp(alpha, 0.0, 1.0);
        return vec4(color * coverage, coverage);
    }
    return vec4(color, 1.0);
}

#endif
