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

    // Derivatives and implicit-LOD samples must retain helper lanes across cutouts.
    if ((material.standard.flags & MATERIAL_ALPHA_MASK) != 0u
        && material_sample.base_color.a < material.standard.alpha_cutoff) discard;

    PhysicalSurface surface;
    surface.standard = prepare_standard_surface(
        material_sample.base_color.rgb,
        material_sample.metallic,
        material_sample.roughness,
        material_sample.normal,
        material_sample.view_direction
    );
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

    vec3 base_ambient = frame.ambient.rgb * material_sample.base_color.rgb
        * (1.0 - material_sample.metallic) * material_sample.occlusion;
    vec3 color;
    if (surface.coat_weight == 0.0 && surface.sheen_strength == 0.0) {
        color = base_ambient + material_sample.emissive;
    } else {
        color = (1.0 - surface.coat_weight)
            * (base_ambient * physical_sheen_attenuation(surface)
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
