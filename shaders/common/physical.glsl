#ifndef C3D_PHYSICAL_GLSL
#define C3D_PHYSICAL_GLSL

#include "brdf.glsl"
#include "ibl.glsl"
#include "lights.glsl"
#include "sheen.glsl"
#include "transmission.glsl"

const float CLEARCOAT_REFLECTANCE = 0.04;

struct PhysicalSurface {
    StandardSurface standard;
    vec3 coat_normal;
    vec3 sheen_color;
    float sheen_strength;
    float sheen_roughness;
    float sheen_view_albedo;
    float coat_weight;
    float coat_roughness;
    float transmission;
    float ior;
    vec3 transmission_color;
    vec3 attenuation_color;
    float attenuation_distance;
    vec3 transmission_ray;
};

float dielectric_normal_reflectance(float ior) {
    float ratio = (ior - 1.0) / (ior + 1.0);
    return ratio * ratio;
}

float physical_sheen_attenuation(PhysicalSurface surface) {
    return 1.0 - surface.sheen_strength * surface.sheen_view_albedo;
}

float clearcoat_view_weight(float clearcoat, vec3 normal, vec3 view_direction) {
    float normal_view = clamp(dot(normal, view_direction), 0.0, 1.0);
    float complement = 1.0 - normal_view;
    float squared = complement * complement;
    float fresnel = CLEARCOAT_REFLECTANCE
        + (1.0 - CLEARCOAT_REFLECTANCE) * squared * squared * complement;
    return clearcoat * fresnel;
}

vec3 evaluate_clearcoat_brdf(PhysicalSurface surface, vec3 light_direction) {
    float normal_view = clamp(
        dot(surface.coat_normal, surface.standard.view_direction),
        0.0,
        1.0
    );
    float normal_light = clamp(dot(surface.coat_normal, light_direction), 0.0, 1.0);
    if (normal_view == 0.0 || normal_light == 0.0) return vec3(0.0);

    vec3 half_direction = normalize(surface.standard.view_direction + light_direction);
    float normal_half = clamp(dot(surface.coat_normal, half_direction), 0.0, 1.0);
    float perceptual = max(surface.coat_roughness, MIN_PERCEPTUAL_ROUGHNESS);
    float alpha = perceptual * perceptual;
    float alpha_squared = alpha * alpha;
    float response = distribution_ggx(normal_half, alpha_squared)
        * visibility_smith(normal_view, normal_light, alpha_squared) * normal_light;
    return vec3(response);
}

vec3 evaluate_sheen_brdf(
    PhysicalSurface surface,
    vec3 light_direction,
    uint sheen_lut,
    uint sheen_sampler,
    out float underlying_attenuation
) {
    underlying_attenuation = physical_sheen_attenuation(surface);
    float normal_light = clamp(dot(surface.standard.normal, light_direction), 0.0, 1.0);
    if (surface.standard.normal_view == 0.0 || normal_light == 0.0) return vec3(0.0);

    float light_albedo = sheen_albedo(
        sheen_lut,
        sheen_sampler,
        normal_light,
        surface.sheen_roughness
    );
    underlying_attenuation = min(
        underlying_attenuation,
        1.0 - surface.sheen_strength * light_albedo
    );

    vec3 half_direction = normalize(surface.standard.view_direction + light_direction);
    float normal_half = clamp(dot(surface.standard.normal, half_direction), 0.0, 1.0);
    float response = sheen_distribution(normal_half, surface.sheen_roughness)
        * sheen_visibility(
            surface.standard.normal_view,
            normal_light,
            surface.sheen_roughness
        ) * normal_light;
    return surface.sheen_color * response;
}

vec3 direct_transmission(LightGpu light, vec3 position, PhysicalSurface surface) {
    LightSample exit_sample = sample_light(light, position + surface.transmission_ray);
    vec3 lobe = punctual_transmission(
        surface.standard,
        surface.transmission_color,
        exit_sample.direction,
        surface.ior
    );
    return volume_attenuation(
        lobe * exit_sample.radiance,
        length(surface.transmission_ray),
        surface.attenuation_color,
        surface.attenuation_distance
    );
}

vec3 evaluate_physical_light(
    LightGpu light,
    vec3 position,
    PhysicalSurface surface,
    uint sheen_lut,
    uint sheen_sampler
) {
    if (surface.coat_weight == 0.0 && surface.sheen_strength == 0.0 && surface.transmission == 0.0) {
        return evaluate_standard_light(light, position, surface.standard);
    }

    LightSample light_sample = sample_light(light, position);
    vec3 diffuse;
    vec3 specular;
    evaluate_standard_lobes(surface.standard, light_sample.direction, diffuse, specular);
    vec3 base = ((1.0 - surface.transmission) * diffuse + specular) * light_sample.radiance;
    if (surface.transmission != 0.0) {
        base += surface.transmission * direct_transmission(light, position, surface);
    }
    float sheen_attenuation = 1.0;
    vec3 sheen = vec3(0.0);
    if (surface.sheen_strength != 0.0) {
        sheen = evaluate_sheen_brdf(
            surface,
            light_sample.direction,
            sheen_lut,
            sheen_sampler,
            sheen_attenuation
        ) * light_sample.radiance;
    }
    vec3 coat = surface.coat_weight == 0.0
        ? vec3(0.0)
        : evaluate_clearcoat_brdf(surface, light_sample.direction) * light_sample.radiance;
    return (1.0 - surface.coat_weight) * (base * sheen_attenuation + sheen)
        + surface.coat_weight * coat;
}

vec3 evaluate_physical_environment(
    EnvironmentGpu environment,
    PhysicalSurface surface,
    float base_roughness,
    float occlusion,
    float ambient_occlusion
) {
    vec3 diffuse;
    vec3 specular;
    evaluate_environment_lobes(
        environment,
        surface.standard,
        base_roughness,
        occlusion,
        ambient_occlusion,
        diffuse,
        specular
    );
    vec3 standard = (1.0 - surface.transmission) * diffuse + specular;
    if (surface.coat_weight == 0.0 && surface.sheen_strength == 0.0) return standard;

    standard *= physical_sheen_attenuation(surface);
    vec3 sheen = vec3(0.0);
    if (surface.sheen_strength != 0.0) {
        vec3 reflection = environment_rotate(
            environment.rotation,
            reflect(-surface.standard.view_direction, surface.standard.normal)
        );
        float perceptual = max(surface.sheen_roughness, MIN_PERCEPTUAL_ROUGHNESS);
        float lod = perceptual * float(ENVIRONMENT_SPECULAR_MIPS - 1u);
        vec3 prefiltered = sample_texture_cube_lod(
            environment.sheen_cube,
            environment.sampler_index,
            reflection,
            lod
        ).rgb;
        sheen = prefiltered * surface.sheen_color * surface.sheen_view_albedo
            * environment.intensity
            * specular_occlusion(surface.standard.normal_view, ambient_occlusion, perceptual);
    }

    vec3 coat = vec3(0.0);
    if (surface.coat_weight != 0.0) {
        float normal_view = clamp(
            dot(surface.coat_normal, surface.standard.view_direction),
            0.0,
            1.0
        );
        vec3 reflection = environment_rotate(
            environment.rotation,
            reflect(-surface.standard.view_direction, surface.coat_normal)
        );
        float perceptual = max(surface.coat_roughness, MIN_PERCEPTUAL_ROUGHNESS);
        float lod = perceptual * float(ENVIRONMENT_SPECULAR_MIPS - 1u);
        vec3 prefiltered = sample_texture_cube_lod(
            environment.specular_cube,
            environment.sampler_index,
            reflection,
            lod
        ).rgb;
        vec2 response = sample_texture_2d(
            environment.brdf_lut,
            environment.sampler_index,
            vec2(normal_view, perceptual)
        ).rg;
        coat = prefiltered * (response.x + response.y) * environment.intensity
            * specular_occlusion(normal_view, ambient_occlusion, perceptual);
    }
    return (1.0 - surface.coat_weight) * (standard + sheen)
        + surface.coat_weight * coat;
}

#endif
