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

vec3 anisotropic_reflection_normal(StandardSurface surface, float perceptual_roughness) {
    if (surface.anisotropy == 0.0) return surface.normal;

    vec3 anisotropic_tangent = cross(surface.anisotropic_bitangent, surface.view_direction);
    vec3 anisotropic_normal = cross(anisotropic_tangent, surface.anisotropic_bitangent);
    float bend = 1.0 - surface.anisotropy * (1.0 - perceptual_roughness);
    bend *= bend;
    bend *= bend;
    return normalize(mix(anisotropic_normal, surface.normal, bend));
}

void evaluate_environment_lobes(
    EnvironmentGpu environment,
    StandardSurface surface,
    float roughness,
    float occlusion,
    out vec3 diffuse,
    out vec3 specular
) {
    float perceptual_roughness = max(roughness, MIN_PERCEPTUAL_ROUGHNESS);
    vec3 normal = environment_rotate(environment.rotation, surface.normal);
    vec3 reflection = environment_rotate(
        environment.rotation,
        reflect(-surface.view_direction, anisotropic_reflection_normal(surface, perceptual_roughness))
    );
    vec3 fresnel = fresnel_schlick(surface.reflectance, surface.grazing_reflectance, surface.normal_view);
    diffuse = environment_irradiance(environment.sh, normal)
        * surface.diffuse_color * (1.0 - fresnel) * occlusion * environment.intensity;

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
    specular = prefiltered
        * (surface.reflectance * response.x + surface.grazing_reflectance * response.y)
        * environment.intensity;
}

vec3 evaluate_environment(
    EnvironmentGpu environment,
    StandardSurface surface,
    float roughness,
    float occlusion
) {
    vec3 diffuse;
    vec3 specular;
    evaluate_environment_lobes(environment, surface, roughness, occlusion, diffuse, specular);
    return diffuse + specular;
}

#endif
