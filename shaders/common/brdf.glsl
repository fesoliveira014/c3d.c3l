#ifndef C3D_BRDF_GLSL
#define C3D_BRDF_GLSL

#include "constants.glsl"
const float MIN_PERCEPTUAL_ROUGHNESS = 0.045; // keeps the finite-light specular lobe representable

struct StandardSurface {
    vec3 diffuse_color;
    vec3 reflectance;
    float alpha_squared;
    vec3 normal;
    vec3 view_direction;
    float normal_view;
};

StandardSurface prepare_standard_surface(
    vec3 base_color,
    float metallic,
    float roughness,
    vec3 normal,
    vec3 view_direction
) {
    float perceptual = max(roughness, MIN_PERCEPTUAL_ROUGHNESS);
    float alpha = perceptual * perceptual;

    StandardSurface surface;
    surface.diffuse_color = (1.0 - metallic) * base_color / PI;
    surface.reflectance = mix(vec3(0.04), base_color, metallic);
    surface.alpha_squared = alpha * alpha;
    surface.normal = normal;
    surface.view_direction = view_direction;
    surface.normal_view = clamp(dot(normal, view_direction), 0.0, 1.0);
    return surface;
}

vec3 fresnel_schlick(vec3 reflectance, float view_half) {
    float complement = 1.0 - clamp(view_half, 0.0, 1.0);
    float squared = complement * complement;
    return reflectance + (1.0 - reflectance) * squared * squared * complement;
}

float distribution_ggx(float normal_half, float alpha_squared) {
    float cosine_squared = normal_half * normal_half;
    float denominator = (1.0 - cosine_squared) + alpha_squared * cosine_squared;
    return alpha_squared / (PI * denominator * denominator);
}

float visibility_smith(float normal_view, float normal_light, float alpha_squared) {
    float view_term = normal_light * sqrt(alpha_squared + (1.0 - alpha_squared) * normal_view * normal_view);
    float light_term = normal_view * sqrt(alpha_squared + (1.0 - alpha_squared) * normal_light * normal_light);
    return 0.5 / (view_term + light_term);
}

vec3 evaluate_standard_brdf(StandardSurface surface, vec3 light_direction) {
    float normal_light = clamp(dot(surface.normal, light_direction), 0.0, 1.0);
    if (surface.normal_view == 0.0 || normal_light == 0.0) return vec3(0.0);

    vec3 half_direction = normalize(surface.view_direction + light_direction);
    float normal_half = clamp(dot(surface.normal, half_direction), 0.0, 1.0);
    float view_half = clamp(dot(surface.view_direction, half_direction), 0.0, 1.0);
    vec3 fresnel = fresnel_schlick(surface.reflectance, view_half);
    vec3 diffuse = (1.0 - fresnel) * surface.diffuse_color;
    vec3 specular = fresnel * distribution_ggx(normal_half, surface.alpha_squared)
        * visibility_smith(surface.normal_view, normal_light, surface.alpha_squared);
    return (diffuse + specular) * normal_light;
}

#endif
