#ifndef C3D_IBL_GLSL
#define C3D_IBL_GLSL

#include "descriptor_heap.glsl"
#include "brdf.glsl"
#include "irradiance.glsl"
#include "ambient_occlusion.glsl"
#include "probe_volume.glsl"
#include "screen_space_gi.glsl"
#include "reflection_probe.glsl"

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
    if (frame.environment != 0ul || frame.reflection_probes != 0ul || (frame.flags & FRAME_SSGI_PRESENT) != 0u) {
        return true;
    }
    if (frame.probe_volumes == 0ul) return false;

    ProbeVolumeSetGpu set = ProbeVolumeSetGpu(frame.probe_volumes);
    for (uint index = 0u; index < set.count; index++) {
        if ((set.volumes[index].flags & PROBE_VOLUME_UNSWEPT) == 0u) return true;
    }
    return false;
}

// Irradiance E from the first probe volume containing the position, else the environment SH, else zero.
vec3 indirect_diffuse_irradiance(FrameRoot frame, vec3 position, vec3 normal, vec3 view_direction) {
    if (frame.probe_volumes != 0ul) {
        ProbeVolumeSetGpu set = ProbeVolumeSetGpu(frame.probe_volumes);
        uint index;
        if (probe_volume_select(set, position, index)) {
            vec3 irradiance;
            if (probe_irradiance(
                set.volumes[index],
                position,
                normal,
                view_direction,
                irradiance
            )) return irradiance;
        }
    }
    if (frame.environment == 0ul) return vec3(0.0);
    EnvironmentGpu environment = EnvironmentGpu(frame.environment);
    return environment_irradiance(environment.sh, environment_rotate(environment.rotation, normal))
        * environment.intensity;
}

// The split-sum table and filtered sampler are renderer-wide; a frame without an environment carries them in its
// probe set. Read only when the frame has one or the other.
void environment_tables(FrameRoot frame, out uint brdf_lut, out uint sampler_index) {
    if (frame.environment != 0ul) {
        EnvironmentGpu environment = EnvironmentGpu(frame.environment);
        brdf_lut = environment.brdf_lut;
        sampler_index = environment.sampler_index;
        return;
    }
    ReflectionProbeSetGpu set = ReflectionProbeSetGpu(frame.reflection_probes);
    brdf_lut = set.brdf_lut;
    sampler_index = set.sampler_index;
}

// Prefiltered radiance along a world direction: the selected probes and the global environment by their shares.
vec3 environment_lobe_radiance(
    FrameRoot frame,
    ReflectionSelection selection,
    vec3 direction,
    float lod,
    uint cube
) {
    vec3 radiance = vec3(0.0);
    if (selection.global_weight > 0.0 && frame.environment != 0ul) {
        EnvironmentGpu environment = EnvironmentGpu(frame.environment);
        radiance = sample_texture_cube_lod(
            cube == ENVIRONMENT_CHARLIE_CUBE ? environment.sheen_cube : environment.specular_cube,
            environment.sampler_index,
            environment_rotate(environment.rotation, direction),
            lod
        ).rgb * (environment.intensity * selection.global_weight);
    }
    if (selection.count == 0u) return radiance;

    ReflectionProbeSetGpu set = ReflectionProbeSetGpu(frame.reflection_probes);
    radiance += reflection_probe_radiance(set, selection.first, selection.first_position, direction, lod, cube)
        * selection.first_weight;
    if (selection.count == 2u) {
        radiance += reflection_probe_radiance(set, selection.second, selection.second_position, direction, lod, cube)
            * selection.second_weight;
    }
    return radiance;
}

// screen_indirect: the pixel's premultiplied screen-space bounce and hit share, zero where there is none.
void evaluate_environment_lobes(
    FrameRoot frame,
    ReflectionSelection selection,
    vec3 world_position,
    StandardSurface surface,
    float roughness,
    float occlusion,
    float ambient_occlusion,
    vec4 screen_indirect,
    out vec3 diffuse,
    out vec3 specular
) {
    vec3 fresnel = fresnel_schlick(surface.reflectance, surface.grazing_reflectance, surface.normal_view);
    vec3 irradiance = indirect_diffuse_irradiance(frame, world_position, surface.normal, surface.view_direction)
        * screen_space_base_share(occlusion, ambient_occlusion, screen_indirect)
        + screen_indirect.rgb * occlusion;
    diffuse = irradiance * surface.diffuse_color * (1.0 - fresnel);
    specular = vec3(0.0);
    if (frame.environment == 0ul && selection.count == 0u) return;

    float perceptual_roughness = max(roughness, MIN_PERCEPTUAL_ROUGHNESS);
    vec3 reflection = reflect(-surface.view_direction, anisotropic_reflection_normal(surface, perceptual_roughness));
    float lod = perceptual_roughness * float(ENVIRONMENT_SPECULAR_MIPS - 1u);
    uint brdf_lut;
    uint sampler_index;
    environment_tables(frame, brdf_lut, sampler_index);
    specular = environment_lobe_radiance(frame, selection, reflection, lod, ENVIRONMENT_GGX_CUBE)
        * environment_brdf_weight(brdf_lut, sampler_index, surface, perceptual_roughness)
        * specular_occlusion(surface.normal_view, ambient_occlusion, perceptual_roughness);
}

void evaluate_environment_lobes(
    FrameRoot frame,
    vec3 world_position,
    StandardSurface surface,
    float roughness,
    float occlusion,
    float ambient_occlusion,
    vec4 screen_indirect,
    out vec3 diffuse,
    out vec3 specular
) {
    evaluate_environment_lobes(
        frame,
        reflection_probe_select(frame, world_position),
        world_position,
        surface,
        roughness,
        occlusion,
        ambient_occlusion,
        screen_indirect,
        diffuse,
        specular
    );
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
    evaluate_environment_lobes(
        frame,
        world_position,
        surface,
        roughness,
        occlusion,
        ambient_occlusion,
        vec4(0.0),
        diffuse,
        specular
    );
}

vec3 evaluate_environment(
    FrameRoot frame,
    vec3 world_position,
    StandardSurface surface,
    float roughness,
    float occlusion,
    float ambient_occlusion,
    vec4 screen_indirect
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
        screen_indirect,
        diffuse,
        specular
    );
    return diffuse + specular;
}

vec3 evaluate_environment(
    FrameRoot frame,
    vec3 world_position,
    StandardSurface surface,
    float roughness,
    float occlusion,
    float ambient_occlusion
) {
    return evaluate_environment(frame, world_position, surface, roughness, occlusion, ambient_occlusion, vec4(0.0));
}

#endif
