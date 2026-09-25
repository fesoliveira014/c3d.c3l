#ifndef C3D_PATH_TRACE_GLSL
#define C3D_PATH_TRACE_GLSL

#include "brdf.glsl"

const uint PATH_TRACE_MISS = 0xffffffffu; // payload row of a ray that hit nothing
const float PATH_TRACE_FAR = 1.0e4; // world units; bounce rays beyond it read the environment
const uint PATH_TRACE_ROULETTE_START = 3u; // bounces before Russian roulette may end a path
const float PATH_TRACE_SURVIVAL_MAX = 0.95; // a bright path still ends eventually
const float HDR_OUTPUT_MAX = 65504.0; // largest finite RGBA16F value; hdr_color stores the display copy
const vec3 PATH_TRACE_LUMA = vec3(0.2126, 0.7152, 0.0722); // mirrored as REC709_LUMA in grade.glsl
const uint PATH_TRACE_RANDOM_PER_BOUNCE = 4u; // lobe choice, two direction values, roulette

// Mirrored as maths::halton.
float halton(uint index, uint base) {
    float fraction = 1.0;
    float result = 0.0;
    while (index > 0u) {
        fraction /= float(base);
        result += fraction * float(index % base);
        index /= base;
    }
    return result;
}

float standard_specular_probability(StandardSurface surface, vec3 base_color, float metallic) {
    vec3 fresnel = fresnel_schlick(surface.reflectance, surface.grazing_reflectance, surface.normal_view);
    float specular = dot(fresnel, PATH_TRACE_LUMA);
    float diffuse = dot(base_color, PATH_TRACE_LUMA) * (1.0 - metallic);
    float total = specular + diffuse;
    return total > 0.0 ? specular / total : 1.0;
}

#endif
