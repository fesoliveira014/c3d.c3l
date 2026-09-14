#ifndef C3D_BRDF_GLSL
#define C3D_BRDF_GLSL

#include "constants.glsl"
const float MIN_PERCEPTUAL_ROUGHNESS = 0.045; // keeps the finite-light specular lobe representable

const vec3 STANDARD_DIELECTRIC_REFLECTANCE = vec3(0.04); // ior 1.5 at normal incidence

struct StandardSurface {
    vec3 diffuse_color;
    vec3 reflectance;
    vec3 grazing_reflectance;
    float alpha_squared;
    vec3 normal;
    vec3 view_direction;
    float normal_view;
    vec3 anisotropic_tangent;
    vec3 anisotropic_bitangent;
    float anisotropy;
    float alpha_tangent;
    float alpha_bitangent;
};

StandardSurface prepare_surface(
    vec3 base_color,
    float metallic,
    float roughness,
    vec3 normal,
    vec3 view_direction,
    vec3 dielectric_reflectance,
    vec3 dielectric_grazing_reflectance
) {
    float perceptual = max(roughness, MIN_PERCEPTUAL_ROUGHNESS);
    float alpha = perceptual * perceptual;

    StandardSurface surface;
    surface.diffuse_color = (1.0 - metallic) * base_color / PI;
    surface.reflectance = mix(dielectric_reflectance, base_color, metallic);
    surface.grazing_reflectance = mix(dielectric_grazing_reflectance, vec3(1.0), metallic);
    surface.alpha_squared = alpha * alpha;
    surface.normal = normal;
    surface.view_direction = view_direction;
    surface.normal_view = clamp(dot(normal, view_direction), 0.0, 1.0);
    surface.anisotropic_tangent = vec3(0.0);
    surface.anisotropic_bitangent = vec3(0.0);
    surface.anisotropy = 0.0;
    surface.alpha_tangent = alpha;
    surface.alpha_bitangent = alpha;
    return surface;
}

void apply_anisotropy(
    inout StandardSurface surface,
    vec3 tangent_direction,
    vec3 bitangent,
    float strength
) {
    float alpha = surface.alpha_bitangent;
    surface.anisotropic_tangent = tangent_direction;
    surface.anisotropic_bitangent = bitangent;
    surface.anisotropy = strength;
    surface.alpha_tangent = mix(alpha, 1.0, strength * strength);
    surface.alpha_bitangent = alpha;
}

StandardSurface prepare_standard_surface(
    vec3 base_color,
    float metallic,
    float roughness,
    vec3 normal,
    vec3 view_direction
) {
    return prepare_surface(
        base_color,
        metallic,
        roughness,
        normal,
        view_direction,
        STANDARD_DIELECTRIC_REFLECTANCE,
        vec3(1.0)
    );
}

vec3 fresnel_schlick(vec3 reflectance, vec3 grazing_reflectance, float view_half) {
    float complement = 1.0 - clamp(view_half, 0.0, 1.0);
    float squared = complement * complement;
    return reflectance + (grazing_reflectance - reflectance) * squared * squared * complement;
}

float distribution_ggx(float normal_half, float alpha_squared) {
    float cosine_squared = normal_half * normal_half;
    float denominator = (1.0 - cosine_squared) + alpha_squared * cosine_squared;
    return alpha_squared / (PI * denominator * denominator);
}

float distribution_ggx_anisotropic(
    float normal_half,
    float tangent_half,
    float bitangent_half,
    float alpha_tangent,
    float alpha_bitangent
) {
    float alpha_product = alpha_tangent * alpha_bitangent;
    vec3 scaled = vec3(alpha_bitangent * tangent_half, alpha_tangent * bitangent_half, alpha_product * normal_half);
    float weight = alpha_product / dot(scaled, scaled);
    return alpha_product * weight * weight / PI;
}

float visibility_smith_anisotropic(
    StandardSurface surface,
    vec3 light_direction,
    float normal_light
) {
    vec3 view_scaled = vec3(
        surface.alpha_tangent * dot(surface.anisotropic_tangent, surface.view_direction),
        surface.alpha_bitangent * dot(surface.anisotropic_bitangent, surface.view_direction),
        surface.normal_view
    );
    vec3 light_scaled = vec3(
        surface.alpha_tangent * dot(surface.anisotropic_tangent, light_direction),
        surface.alpha_bitangent * dot(surface.anisotropic_bitangent, light_direction),
        normal_light
    );
    return 0.5 / (normal_light * length(view_scaled) + surface.normal_view * length(light_scaled));
}

float visibility_smith(float normal_view, float normal_light, float alpha_squared) {
    float view_term = normal_light * sqrt(alpha_squared + (1.0 - alpha_squared) * normal_view * normal_view);
    float light_term = normal_view * sqrt(alpha_squared + (1.0 - alpha_squared) * normal_light * normal_light);
    return 0.5 / (view_term + light_term);
}

void evaluate_standard_lobes(
    StandardSurface surface,
    vec3 light_direction,
    out vec3 diffuse,
    out vec3 specular
) {
    diffuse = vec3(0.0);
    specular = vec3(0.0);
    float normal_light = clamp(dot(surface.normal, light_direction), 0.0, 1.0);
    if (surface.normal_view == 0.0 || normal_light == 0.0) return;

    vec3 half_direction = normalize(surface.view_direction + light_direction);
    float normal_half = clamp(dot(surface.normal, half_direction), 0.0, 1.0);
    float view_half = clamp(dot(surface.view_direction, half_direction), 0.0, 1.0);
    vec3 fresnel = fresnel_schlick(surface.reflectance, surface.grazing_reflectance, view_half);
    diffuse = (1.0 - fresnel) * surface.diffuse_color * normal_light;
    float distribution;
    float visibility;
    if (surface.anisotropy > 0.0) {
        distribution = distribution_ggx_anisotropic(
            normal_half,
            dot(surface.anisotropic_tangent, half_direction),
            dot(surface.anisotropic_bitangent, half_direction),
            surface.alpha_tangent,
            surface.alpha_bitangent
        );
        visibility = visibility_smith_anisotropic(surface, light_direction, normal_light);
    } else {
        distribution = distribution_ggx(normal_half, surface.alpha_squared);
        visibility = visibility_smith(surface.normal_view, normal_light, surface.alpha_squared);
    }
    specular = fresnel * distribution * visibility * normal_light;
}

vec3 evaluate_standard_brdf(StandardSurface surface, vec3 light_direction) {
    vec3 diffuse;
    vec3 specular;
    evaluate_standard_lobes(surface, light_direction, diffuse, specular);
    return diffuse + specular;
}

#endif
