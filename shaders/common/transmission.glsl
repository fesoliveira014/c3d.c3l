#ifndef C3D_TRANSMISSION_GLSL
#define C3D_TRANSMISSION_GLSL

#include "descriptor_heap.glsl"
#include "brdf.glsl"
#include "ibl.glsl"

const float MIN_TRANSMISSION_ALPHA = MIN_PERCEPTUAL_ROUGHNESS * MIN_PERCEPTUAL_ROUGHNESS;

vec3 transmission_ray(vec3 refracted, float thickness, mat4 model) {
    vec3 model_scale = vec3(length(model[0].xyz), length(model[1].xyz), length(model[2].xyz));
    return normalize(refracted) * thickness * model_scale;
}

vec3 volume_attenuation(
    vec3 radiance,
    float distance,
    vec3 attenuation_color,
    float attenuation_distance
) {
    if (attenuation_distance == 0.0 || distance == 0.0) return radiance;
    return pow(attenuation_color, vec3(distance / attenuation_distance)) * radiance;
}

vec3 transmitted_radiance(
    FrameRoot frame,
    vec3 position,
    vec3 ray,
    vec3 refracted,
    float roughness
) {
    vec4 clip = frame.view_proj * vec4(position + ray, 1.0);
    if (clip.w > 0.0) {
        vec2 ndc = clip.xy / clip.w;
        vec2 uv = vec2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
        if (all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)))) {
            return sample_texture_2d(frame.scene_color, frame.scene_sampler, uv).rgb;
        }
    }
    if (frame.environment == 0ul) return vec3(0.0);

    EnvironmentGpu environment = EnvironmentGpu(frame.environment);
    float lod = max(roughness, MIN_PERCEPTUAL_ROUGHNESS) * float(ENVIRONMENT_SPECULAR_MIPS - 1u);
    return sample_texture_cube_lod(
        environment.specular_cube,
        environment.sampler_index,
        environment_rotate(environment.rotation, normalize(refracted)),
        lod
    ).rgb * environment.intensity;
}

vec3 punctual_transmission(
    StandardSurface surface,
    vec3 transmission_color,
    vec3 light_direction,
    float ior
) {
    float alpha = max(
        sqrt(surface.alpha_squared) * clamp(ior * 2.0 - 2.0, 0.0, 1.0),
        MIN_TRANSMISSION_ALPHA
    );
    float alpha_squared = alpha * alpha;
    vec3 light_mirror = normalize(
        light_direction + 2.0 * surface.normal * dot(-light_direction, surface.normal)
    );
    float normal_light = clamp(dot(surface.normal, light_mirror), 0.0, 1.0);
    if (surface.normal_view == 0.0 || normal_light == 0.0) return vec3(0.0);

    vec3 half_direction = normalize(light_mirror + surface.view_direction);
    float normal_half = clamp(dot(surface.normal, half_direction), 0.0, 1.0);
    float view_half = clamp(dot(surface.view_direction, half_direction), 0.0, 1.0);
    vec3 fresnel = fresnel_schlick(surface.reflectance, surface.grazing_reflectance, view_half);
    return (1.0 - fresnel) * transmission_color * distribution_ggx(normal_half, alpha_squared)
        * visibility_smith(surface.normal_view, normal_light, alpha_squared);
}

#endif
