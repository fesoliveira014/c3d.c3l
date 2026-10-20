#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "custom_material.glsl"
#include "blend_output.glsl"
#include "scene_snapshot.glsl"
#include "ibl.glsl"
#include "fog.glsl"
#include "lights.glsl"
#include "shadows.glsl"

const uint PARTICLE_UNLIT = 0u; // mirrored by ParticleLighting.UNLIT in material.c3
const uint PARTICLE_AMBIENT = 1u; // mirrored by ParticleLighting.AMBIENT in material.c3
const uint PARTICLE_DIRECT = 2u; // mirrored by ParticleLighting.DIRECT in material.c3
const uint PARTICLE_DIRECT_SHADOWED = 3u; // mirrored by ParticleLighting.DIRECT_SHADOWED in material.c3
const uint PARTICLE_NORMAL_CAMERA = 0u; // mirrored by ParticleNormal.CAMERA in material.c3
const uint PARTICLE_NORMAL_SPHERICAL = 1u; // mirrored by ParticleNormal.SPHERICAL in material.c3
const uint PARTICLE_NORMAL_VOLUME = 2u; // mirrored by ParticleNormal.VOLUME in material.c3

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec4 v_tangent;
layout(location = 3) in vec2 v_uv0;
layout(location = 4) in vec2 v_uv1;
layout(location = 5) in vec4 v_color;
layout(location = 8) in vec3 v_billboard;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ParticleParams {
    vec4 color;
    float soft_distance;
    uint lighting;
    uint normal;
    float anisotropy;
};

vec3 spherical_normal() {
    vec3 axis = normalize(v_normal);
    vec3 tangent = normalize(v_tangent.xyz);
    vec3 bitangent = cross(axis, tangent) * v_tangent.w;
    vec2 disc = vec2(v_billboard.x * 2.0 - 1.0, 1.0 - v_billboard.y * 2.0); // v runs from the top edge down
    float height = sqrt(max(1.0 - dot(disc, disc), 0.0));
    return normalize(tangent * disc.x + bitangent * disc.y + axis * height);
}

vec3 direct_lighting(
    FrameRoot frame,
    DrawRoot draw,
    ParticleParams params,
    vec3 normal,
    vec3 ray_direction
) {
    float view_depth = -(frame.view * vec4(v_world_pos, 1.0)).z;
    LightList lights = select_lights(frame, v_world_pos, view_depth);
    vec3 radiance = vec3(0.0);
    for (uint index = 0u; index < lights.count; index++) {
        LightGpu light = LightArray(frame.lights).values[selected_light_index(frame, lights, index)];
        if ((draw.layers & light.layers) == 0u) continue;

        LightSample light_sample = sample_light(light, v_world_pos);
        float response = params.normal == PARTICLE_NORMAL_VOLUME
            ? fog_phase(dot(ray_direction, light_sample.direction), params.anisotropy)
            : max(dot(normal, light_sample.direction), 0.0) / PI;
        float visibility = 1.0;
        if (params.lighting == PARTICLE_DIRECT_SHADOWED && light_casts_shadow(light)) {
            visibility = shadow_visibility(frame, light, v_world_pos, normal, view_depth);
        }
        radiance += light_sample.radiance * response * visibility;
    }
    return radiance;
}

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    ParticleParams params = ParticleParams(material.parameters);
    material_mip_bias = frame.mip_bias;
    vec4 color = v_color * params.color;
    if (custom_slot_present(material, 0u)) {
        // Under a sprite sheet UV0 is the current cell and UV1 the next, whatever set the slot reads.
        vec4 texel = sample_custom_map(material, 0u, v_uv0, v_uv0);
        if ((draw.flags & DRAW_BILLBOARD_ATLAS) != 0u) {
            texel = mix(texel, sample_custom_map(material, 0u, v_uv1, v_uv1), v_billboard.z);
        }
        color *= texel;
    }
    if (params.soft_distance > 0.0) {
        color.a *= clamp(scene_depth_gap(frame, gl_FragCoord) / params.soft_distance, 0.0, 1.0);
    }
    if (params.lighting == PARTICLE_UNLIT) {
        color.rgb = pre_exposed(frame, color.rgb);
    } else {
        vec3 view_direction = standard_view_direction(frame, v_world_pos);
        vec3 normal = params.normal == PARTICLE_NORMAL_SPHERICAL ? spherical_normal() : normalize(v_normal);
        vec3 lit = frame.ambient.rgb + indirect_diffuse_irradiance(frame, v_world_pos, normal, view_direction);
        if (params.lighting >= PARTICLE_DIRECT) {
            lit += direct_lighting(
                frame,
                draw,
                params,
                normal,
                -view_direction
            );
        }
        color.rgb *= lit;
    }
    color.rgb = apply_material_fog(frame, v_world_pos, color.rgb, material.flags);
    write_blend_output(frame, material_output(color.rgb, color.a, material.flags), v_world_pos);
}
