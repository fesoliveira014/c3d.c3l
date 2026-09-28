#ifndef C3D_IBL_GLSL
#define C3D_IBL_GLSL

#include "descriptor_heap.glsl"
#include "brdf.glsl"
#include "irradiance.glsl"
#include "ambient_occlusion.glsl"
#include "probe_volume.glsl"

vec3 environment_rotate(EnvironmentRotationGpu rotation, vec3 direction) {
    return vec3(
        dot(rotation.row0.xyz, direction),
        dot(rotation.row1.xyz, direction),
        dot(rotation.row2.xyz, direction)
    );
}

vec3 sky_radiance(SkyRoot sky, vec3 direction) {
    return sample_texture_cube_lod(
        sky.source_cube,
        sky.sampler_index,
        environment_rotate(sky.rotation, direction),
        0.0
    ).rgb * sky.intensity;
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

// Split-sum weight of a specular radiance: reflectance x scale + grazing reflectance x bias.
vec3 environment_brdf_weight(
    uint brdf_lut,
    uint sampler_index,
    StandardSurface surface,
    float perceptual_roughness
) {
    vec2 response = sample_texture_2d(brdf_lut, sampler_index, vec2(surface.normal_view, perceptual_roughness)).rg;
    return surface.reflectance * response.x + surface.grazing_reflectance * response.y;
}

// Radiance along a ray that leaves the scene: the lighting environment, not the background cube.
vec3 trace_miss_radiance(FrameRoot frame, vec3 direction) {
    if (frame.environment == 0ul) return frame.ambient.rgb;
    EnvironmentGpu environment = EnvironmentGpu(frame.environment);
    return sample_texture_cube_lod(
        environment.specular_cube,
        environment.sampler_index,
        environment_rotate(environment.rotation, direction),
        0.0
    ).rgb * environment.intensity;
}

bool frame_has_indirect(FrameRoot frame) {
    return frame.environment != 0ul || frame.probe_volumes != 0ul;
}

// Irradiance E from the first probe volume containing the position, else the environment SH, else zero.
vec3 indirect_diffuse_irradiance(FrameRoot frame, vec3 position, vec3 normal, vec3 view_direction) {
    if (frame.probe_volumes != 0ul) {
        ProbeVolumeSetGpu set = ProbeVolumeSetGpu(frame.probe_volumes);
        uint index;
        if (probe_volume_select(set, position, index)) {
            return probe_irradiance(set.volumes[index], position, normal, view_direction);
        }
    }
    if (frame.environment == 0ul) return vec3(0.0);
    EnvironmentGpu environment = EnvironmentGpu(frame.environment);
    return environment_irradiance(environment.sh, environment_rotate(environment.rotation, normal))
        * environment.intensity;
}

void evaluate_environment_lobes(
    FrameRoot frame,
    vec3 world_position,
    StandardSurface surface,
    float roughness,
    float occlusion,
    float ambient_occlusion,
    out vec3 diffuse,
    out vec3 specular
) {
    vec3 fresnel = fresnel_schlick(surface.reflectance, surface.grazing_reflectance, surface.normal_view);
    diffuse = indirect_diffuse_irradiance(frame, world_position, surface.normal, surface.view_direction)
        * surface.diffuse_color * (1.0 - fresnel) * min(occlusion, ambient_occlusion);
    specular = vec3(0.0);
    if (frame.environment == 0ul) return;

    EnvironmentGpu environment = EnvironmentGpu(frame.environment);
    float perceptual_roughness = max(roughness, MIN_PERCEPTUAL_ROUGHNESS);
    vec3 reflection = environment_rotate(
        environment.rotation,
        reflect(-surface.view_direction, anisotropic_reflection_normal(surface, perceptual_roughness))
    );
    float lod = perceptual_roughness * float(ENVIRONMENT_SPECULAR_MIPS - 1u);
    vec3 prefiltered = sample_texture_cube_lod(
        environment.specular_cube,
        environment.sampler_index,
        reflection,
        lod
    ).rgb;
    specular = prefiltered
        * environment_brdf_weight(environment.brdf_lut, environment.sampler_index, surface, perceptual_roughness)
        * environment.intensity
        * specular_occlusion(surface.normal_view, ambient_occlusion, perceptual_roughness);
}

vec3 evaluate_environment(
    FrameRoot frame,
    vec3 world_position,
    StandardSurface surface,
    float roughness,
    float occlusion,
    float ambient_occlusion
) {
    vec3 diffuse;
    vec3 specular;
    evaluate_environment_lobes(
        frame,
        world_position,
        surface,
        roughness,
        occlusion,
        ambient_occlusion,
        diffuse,
        specular
    );
    return diffuse + specular;
}

#endif
