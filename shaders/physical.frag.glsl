#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "vertex_pull.glsl"
#include "standard_surface.glsl"
#include "brdf.glsl"
#include "ibl.glsl"
#include "lights.glsl"
#include "material_alpha.glsl"
#include "material_maps.glsl"
#include "physical.glsl"
#include "shadows.glsl"

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec4 v_tangent;
layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    PhysicalMaterialGpu material = PhysicalMaterialGpu(draw.material);
    StandardMaterialSample material_sample = sample_standard_material(
        material.standard,
        geometry,
        v_world_pos,
        v_normal,
        v_tangent,
        v_uv0,
        v_uv1,
        standard_view_direction(frame, v_world_pos),
        !gl_FrontFacing
    );

    float clearcoat = material.clearcoat;
    float clearcoat_roughness = material.clearcoat_roughness;
    vec3 coat_normal = material_sample.offset_normal;
    if (clearcoat > 0.0) {
        if ((material.map_flags & PHYSICAL_MAP_CLEARCOAT) != 0u) {
            clearcoat = clamp(clearcoat * sample_map(
                material.clearcoat_map,
                material.map_flags,
                PHYSICAL_MAP_CLEARCOAT,
                v_uv0,
                v_uv1
            ).r, 0.0, 1.0);
        }
        if ((material.map_flags & PHYSICAL_MAP_CLEARCOAT_ROUGHNESS) != 0u) {
            clearcoat_roughness = clamp(clearcoat_roughness * sample_map(
                material.clearcoat_roughness_map,
                material.map_flags,
                PHYSICAL_MAP_CLEARCOAT_ROUGHNESS,
                v_uv0,
                v_uv1
            ).g, 0.0, 1.0);
        }
        if ((material.map_flags & PHYSICAL_MAP_CLEARCOAT_NORMAL) != 0u
            && material.clearcoat_normal_scale != 0.0) {
            coat_normal = sample_material_normal(
                material.clearcoat_normal_map,
                material.map_flags,
                PHYSICAL_MAP_CLEARCOAT_NORMAL,
                material.clearcoat_normal_scale,
                geometry,
                v_world_pos,
                normalize(v_normal),
                v_tangent,
                v_uv0,
                v_uv1
            );
            if ((material.standard.flags & MATERIAL_DOUBLE_SIDED) != 0u && !gl_FrontFacing) {
                coat_normal = -coat_normal;
            }
        }
    }

    vec3 sheen_color = material.sheen_color_roughness.rgb;
    float sheen_roughness = material.sheen_color_roughness.a;
    if (any(greaterThan(sheen_color, vec3(0.0)))) {
        if ((material.map_flags & PHYSICAL_MAP_SHEEN_COLOR) != 0u) {
            sheen_color = clamp(sheen_color * sample_map(
                material.sheen_color_map,
                material.map_flags,
                PHYSICAL_MAP_SHEEN_COLOR,
                v_uv0,
                v_uv1
            ).rgb, 0.0, 1.0);
        }
        if ((material.map_flags & PHYSICAL_MAP_SHEEN_ROUGHNESS) != 0u) {
            sheen_roughness = clamp(sheen_roughness * sample_map(
                material.sheen_roughness_map,
                material.map_flags,
                PHYSICAL_MAP_SHEEN_ROUGHNESS,
                v_uv0,
                v_uv1
            ).a, 0.0, 1.0);
        }
    }

    float specular_weight = material.specular_color_weight.w;
    vec3 specular_color = material.specular_color_weight.rgb;
    if (specular_weight > 0.0) {
        if ((material.extension_map_flags & PHYSICAL_EXTENSION_MAP_SPECULAR) != 0u) {
            specular_weight = clamp(specular_weight * sample_map(
                material.specular_map,
                material.extension_map_flags,
                PHYSICAL_EXTENSION_MAP_SPECULAR,
                v_uv0,
                v_uv1
            ).a, 0.0, 1.0);
        }
        if ((material.extension_map_flags & PHYSICAL_EXTENSION_MAP_SPECULAR_COLOR) != 0u) {
            specular_color *= sample_map(
                material.specular_color_map,
                material.extension_map_flags,
                PHYSICAL_EXTENSION_MAP_SPECULAR_COLOR,
                v_uv0,
                v_uv1
            ).rgb;
        }
    }
    vec3 dielectric_reflectance = min(
        dielectric_normal_reflectance(material.ior) * specular_color,
        vec3(1.0)
    ) * specular_weight;

    float anisotropy = material.anisotropy;
    vec2 anisotropy_direction = vec2(cos(material.anisotropy_rotation), sin(material.anisotropy_rotation));
    vec4 anisotropy_tangent = vec4(0.0);
    if (anisotropy > 0.0) {
        vec2 anisotropy_uv = v_uv0;
        if ((material.extension_map_flags & PHYSICAL_EXTENSION_MAP_ANISOTROPY) != 0u) {
            anisotropy_uv = map_uv(
                material.anisotropy_map,
                material.extension_map_flags,
                PHYSICAL_EXTENSION_MAP_ANISOTROPY,
                v_uv0,
                v_uv1
            );
            vec3 sampled = sample_texture_2d_implicit(
                material.anisotropy_map.texture_index,
                material.anisotropy_map.sampler_index,
                anisotropy_uv
            ).rgb;
            mat2 rotation = mat2(
                anisotropy_direction.x, anisotropy_direction.y,
                -anisotropy_direction.y, anisotropy_direction.x
            );
            anisotropy_direction = rotation * (sampled.rg * 2.0 - 1.0);
            anisotropy = clamp(anisotropy * sampled.b, 0.0, 1.0);
        }
        anisotropy_tangent = (geometry.flags & GEOMETRY_HAS_TANGENTS) != 0u
            ? v_tangent
            : derivative_tangent(
                normalize(v_normal),
                dFdx(v_world_pos),
                dFdy(v_world_pos),
                dFdx(anisotropy_uv),
                dFdy(anisotropy_uv)
            );
    }

    float transmission = material.transmission;
    float thickness = material.thickness;
    if (transmission > 0.0) {
        if ((material.extension_map_flags & PHYSICAL_EXTENSION_MAP_TRANSMISSION) != 0u) {
            transmission = clamp(transmission * sample_map(
                material.transmission_map,
                material.extension_map_flags,
                PHYSICAL_EXTENSION_MAP_TRANSMISSION,
                v_uv0,
                v_uv1
            ).r, 0.0, 1.0);
        }
        if ((material.extension_map_flags & PHYSICAL_EXTENSION_MAP_THICKNESS) != 0u) {
            thickness = max(thickness * sample_map(
                material.thickness_map,
                material.extension_map_flags,
                PHYSICAL_EXTENSION_MAP_THICKNESS,
                v_uv0,
                v_uv1
            ).g, 0.0);
        }
    }

    // Derivatives and implicit-LOD samples must retain helper lanes across cutouts.
    if ((material.standard.flags & MATERIAL_ALPHA_MASK) != 0u
        && material_sample.base_color.a < material.standard.alpha_cutoff) discard;

    PhysicalSurface surface;
    surface.standard = prepare_surface(
        material_sample.base_color.rgb,
        material_sample.metallic,
        material_sample.roughness,
        material_sample.normal,
        material_sample.view_direction,
        dielectric_reflectance,
        vec3(specular_weight)
    );
    if (anisotropy > 0.0) {
        vec3 frame_tangent;
        vec3 frame_bitangent;
        if (surface_tangent_frame(normalize(v_normal), anisotropy_tangent, frame_tangent, frame_bitangent)) {
            vec3 direction = frame_tangent * anisotropy_direction.x + frame_bitangent * anisotropy_direction.y;
            direction -= surface.standard.normal * dot(surface.standard.normal, direction);
            float length_squared = dot(direction, direction);
            if (length_squared > 0.0) {
                direction *= inversesqrt(length_squared);
                apply_anisotropy(
                    surface.standard,
                    direction,
                    cross(surface.standard.normal, direction),
                    anisotropy
                );
            }
        }
    }
    surface.coat_normal = coat_normal;
    surface.sheen_color = sheen_color;
    surface.sheen_roughness = sheen_roughness;
    surface.sheen_strength = max(sheen_color.r, max(sheen_color.g, sheen_color.b));
    surface.sheen_view_albedo = surface.sheen_strength == 0.0
        ? 0.0
        : sheen_albedo(
            draw.sheen_lut,
            draw.sheen_sampler,
            surface.standard.normal_view,
            sheen_roughness
        );
    surface.coat_weight = clearcoat_view_weight(
        clearcoat,
        coat_normal,
        material_sample.view_direction
    );
    surface.coat_roughness = clearcoat_roughness;
    surface.transmission = transmission;
    surface.ior = material.ior;
    surface.transmission_color = material_sample.base_color.rgb * (1.0 - material_sample.metallic);
    surface.attenuation_color = material.attenuation_color_distance.rgb;
    surface.attenuation_distance = material.attenuation_color_distance.w;
    surface.transmission_ray = vec3(0.0);
    vec3 transmitted = vec3(0.0);
    if (transmission > 0.0) {
        vec3 refracted = refract(-material_sample.view_direction, material_sample.normal, 1.0 / material.ior);
        surface.transmission_ray = transmission_ray(refracted, thickness, draw.model);
        vec3 radiance = volume_attenuation(
            transmitted_radiance(frame, v_world_pos, surface.transmission_ray, refracted, material_sample.roughness),
            length(surface.transmission_ray),
            surface.attenuation_color,
            surface.attenuation_distance
        );
        vec3 fresnel = fresnel_schlick(
            surface.standard.reflectance,
            surface.standard.grazing_reflectance,
            surface.standard.normal_view
        );
        transmitted = (1.0 - fresnel) * radiance * surface.transmission_color;
    }

    vec3 base_ambient = frame.ambient.rgb * material_sample.base_color.rgb
        * (1.0 - material_sample.metallic) * material_sample.occlusion;
    vec3 base_fill = (1.0 - transmission) * base_ambient + transmission * transmitted;
    vec3 color;
    if (surface.coat_weight == 0.0 && surface.sheen_strength == 0.0) {
        color = base_fill + material_sample.emissive;
    } else {
        color = (1.0 - surface.coat_weight)
            * (base_fill * physical_sheen_attenuation(surface)
                + material_sample.emissive);
    }
    if (frame.environment != 0ul) {
        EnvironmentGpu environment = EnvironmentGpu(frame.environment);
        color += evaluate_physical_environment(
            environment,
            surface,
            material_sample.roughness,
            material_sample.occlusion
        );
    }
    float view_depth = -(frame.view * vec4(v_world_pos, 1.0)).z;
    for (uint index = 0u; index < frame.light_count; index++) {
        LightGpu light = LightArray(frame.lights).values[index];
        if ((draw.layers & light.layers) == 0u) continue;
        float visibility = 1.0;
        if ((draw.flags & DRAW_RECEIVE_SHADOW) != 0u && light.shadow_count != 0u) {
            visibility = shadow_visibility(
                frame,
                light,
                v_world_pos,
                material_sample.offset_normal,
                view_depth
            );
        }
        color += visibility * evaluate_physical_light(
            light,
            v_world_pos,
            surface,
            draw.sheen_lut,
            draw.sheen_sampler
        );
    }
    out_color = material_output(
        color,
        material_sample.base_color.a,
        material.standard.flags
    );
}
