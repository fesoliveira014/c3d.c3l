#ifndef C3D_IBL_GLSL
#define C3D_IBL_GLSL

#include "descriptor_heap.glsl"
#include "brdf.glsl"
#include "irradiance.glsl"

vec3 environment_rotate(EnvironmentRotationGpu rotation, vec3 direction) {
    return vec3(
        dot(rotation.row0.xyz, direction),
        dot(rotation.row1.xyz, direction),
        dot(rotation.row2.xyz, direction)
    );
}

vec3 evaluate_environment(
    EnvironmentGpu environment,
    StandardSurface surface,
    float roughness,
    float occlusion
) {
    vec3 normal = environment_rotate(environment.rotation, surface.normal);
    vec3 reflection = environment_rotate(
        environment.rotation,
        reflect(-surface.view_direction, surface.normal)
    );
    vec3 fresnel = fresnel_schlick(surface.reflectance, surface.normal_view);
    vec3 diffuse = environment_irradiance(environment.sh, normal)
        * surface.diffuse_color * (1.0 - fresnel) * occlusion;

    float perceptual_roughness = max(roughness, MIN_PERCEPTUAL_ROUGHNESS);
    float lod = perceptual_roughness * float(ENVIRONMENT_SPECULAR_MIPS - 1u);
    vec3 prefiltered = sample_texture_cube_lod(
        environment.specular_cube,
        environment.sampler_index,
        reflection,
        lod
    ).rgb;
    vec2 response = sample_texture_2d(
        environment.brdf_lut,
        environment.sampler_index,
        vec2(surface.normal_view, perceptual_roughness)
    ).rg;
    vec3 specular = prefiltered * (surface.reflectance * response.x + response.y);
    return (diffuse + specular) * environment.intensity;
}

#endif
