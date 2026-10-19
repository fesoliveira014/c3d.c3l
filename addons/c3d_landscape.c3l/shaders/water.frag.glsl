#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "custom_material.glsl"
#include "standard_shading.glsl"
#include "scene_snapshot.glsl"
#include "texture_fetch.glsl"
#include "fog.glsl"
#include "landscape/water_waves.glsl"
#include "landscape/water_reflection.glsl"

const vec3 WATER_REFLECTANCE = vec3(0.02); // ior 1.33 at normal incidence
const float WATER_IOR = 1.33; // air is 1; a ray leaving the water takes its inverse
const uint WATER_RIPPLES = 0u; // mirrored as RIPPLE_REFERENCE in water/material.c3
const uint WATER_FOAM = 1u; // mirrored as FOAM_REFERENCE in water/material.c3
const float WATER_REFRACTION_DEPTH = 1.0; // metres of water behind the surface at which refraction bends fully

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec4 v_tangent;
layout(location = 3) in vec2 v_uv0;
layout(location = 5) in vec4 v_color;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

StandardMaterialSample water_layer(
    CustomMaterialGpu material,
    uint reference,
    GeometryRoot geometry,
    vec3 normal,
    vec2 uv,
    vec3 view_direction
) {
    return sample_standard_material(
        custom_reference(material, reference),
        geometry,
        v_world_pos,
        normal,
        v_tangent,
        uv,
        uv,
        view_direction,
        false
    );
}

// What a ray leaving the water through the surface sees, from the snapshot where the direction lies in the frame and
// from the environment where it does not. The depth is that of the snapshot sample; 0 is the background.
vec3 water_window(FrameRoot frame, vec3 direction, out float depth) {
    depth = 0.0;
    vec4 clip = frame.view_proj * vec4(direction, 0.0);
    if (frame.proj[3][3] == 0.0 && clip.w > 0.0) {
        vec2 uv = vec2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
        if (water_inside_frame(uv)) {
            depth = scene_depth_at(frame, uv);
            return sample_texture_2d_lod(frame.scene_color, frame.scene_sampler, uv, 0.0).rgb;
        }
    }
    return water_miss_radiance(frame, direction);
}

// The underwater scene a ray reflected back down sees, fogged by the water's medium from the surface to where it hits.
vec3 water_underwater_reflection(FrameRoot frame, WaterParams params, vec3 position, vec3 direction) {
    vec3 radiance;
    float hit_distance;
    if ((params.flags & WATER_MARCH) != 0u && water_march(frame, position, direction, radiance, hit_distance)) {
        return apply_fog_segment(frame, position, position + direction * hit_distance, radiance);
    }
    return apply_fog_to_infinity(frame, position, direction, water_miss_radiance(frame, direction));
}

// The surface seen from under it: the scene above through the window inside the critical angle, the underwater scene
// outside it. The view's fog pass fogs the path from the camera to the surface.
vec3 water_from_below(FrameRoot frame, WaterParams params, vec3 position, vec3 normal, vec3 view_direction) {
    vec3 incident = -view_direction;
    vec3 into_water = faceforward(-normal, incident, -normal);
    vec3 transmitted = refract(incident, into_water, WATER_IOR);
    bool total_reflection = dot(transmitted, transmitted) == 0.0;

    // Schlick's fit takes the angle in the rarer medium on this side; it reaches 1 at the critical angle.
    vec3 fresnel = vec3(1.0);
    vec3 window = vec3(0.0);
    float window_depth = 0.0;
    if (!total_reflection) {
        fresnel = fresnel_schlick(WATER_REFLECTANCE, vec3(1.0), dot(transmitted, -into_water));
        window = water_window(frame, transmitted, window_depth);
    }

    vec3 reflection = water_underwater_reflection(frame, params, position, reflect(incident, into_water));
    return apply_fog_refracted(frame, position, vec3(1.0) - fresnel, window, window_depth, fresnel * reflection);
}

void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    material_mip_bias = frame.mip_bias;
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    WaterParams params = WaterParams(material.parameters);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    vec3 view_direction = standard_view_direction(frame, v_world_pos);
    vec3 wave_normal = normalize(v_normal);

    // The references are per material, so both samples run in uniform control flow for their derivatives.
    vec3 normal = wave_normal;
    if (material.references[WATER_RIPPLES] != 0ul) {
        vec4 scroll = params.scroll_origin + params.scroll_velocity * (frame.jitter_time.z - params.scroll_time);
        vec2 first_uv = v_uv0 + scroll.xy;
        vec2 second_uv = v_uv0 + scroll.zw;
        vec3 first = water_layer(material, WATER_RIPPLES, geometry, wave_normal, first_uv, view_direction).normal;
        vec3 second = water_layer(material, WATER_RIPPLES, geometry, wave_normal, second_uv, view_direction).normal;
        // Sums the two perturbations of the wave normal.
        normal = normalize(first + second - wave_normal);
    }
    float foam = 0.0;
    vec3 foam_color = vec3(0.0);
    float foam_roughness = params.roughness;
    if (material.references[WATER_FOAM] != 0ul) {
        StandardMaterialSample foam_sample = water_layer(material, WATER_FOAM, geometry, normal, v_uv0, view_direction);
        foam_color = foam_sample.base_color.rgb;
        foam_roughness = foam_sample.roughness;
        float crest_foam = clamp((v_color.a - params.foam_crest) / (1.0 - params.foam_crest), 0.0, 1.0);
        float shore_foam = params.foam_depth > 0.0
            ? 1.0 - clamp(scene_depth_gap(frame, gl_FragCoord) / params.foam_depth, 0.0, 1.0)
            : 0.0;
        foam = max(crest_foam, shore_foam);
    }

    vec2 screen_uv = scene_uv(frame, gl_FragCoord.xy);
    vec3 rest_normal = normalize(mat3(draw.normal_0.xyz, draw.normal_1.xyz, draw.normal_2.xyz) * vec3(0.0, 1.0, 0.0));
    vec3 view_tilt = mat3(frame.view) * (normal - rest_normal);
    vec2 screen_tilt = vec2(view_tilt.x, -view_tilt.y);
    float bend = clamp(scene_depth_gap(frame, gl_FragCoord) / WATER_REFRACTION_DEPTH, 0.0, 1.0);
    vec2 refracted_uv = screen_uv + screen_tilt * (params.refraction_strength * bend);
    // Reverse-Z: a larger depth is nearer, so the offset sample landed on something in front of the water.
    if (scene_depth_at(frame, refracted_uv) > gl_FragCoord.z) refracted_uv = screen_uv;

    vec3 irradiance = indirect_diffuse_irradiance(frame, v_world_pos, normal, view_direction);
    vec3 foam_albedo = foam_color * foam;
    StandardSurface surface = prepare_surface(
        foam_albedo,
        0.0,
        mix(params.roughness, foam_roughness, foam),
        normal,
        view_direction,
        WATER_REFLECTANCE,
        vec3(1.0)
    );
    vec3 color = evaluate_standard_lights(
        frame,
        surface,
        v_world_pos,
        wave_normal,
        draw.layers,
        (draw.flags & DRAW_RECEIVE_SHADOW) != 0u
    );

    // The branch holds explicit-lod reads only, so the derivatives above stay in uniform control flow.
    if (!gl_FrontFacing) {
        color = water_from_below(frame, params, v_world_pos, normal, view_direction);
        out_color = material_output(color, 1.0, material.flags);
        return;
    }

    vec3 fresnel = fresnel_schlick(surface.reflectance, surface.grazing_reflectance, surface.normal_view);
    vec3 reflection = water_reflection(
        frame,
        material,
        params,
        v_world_pos,
        reflect(-view_direction, normal),
        screen_uv,
        screen_tilt
    );
    vec3 foam_ambient = standard_ambient_fill(frame, foam_albedo, 0.0, 1.0, 1.0, vec4(0.0))
        + irradiance * surface.diffuse_color;
    color += fresnel * reflection + (1.0 - fresnel) * foam_ambient;
    vec3 behind = sample_texture_2d_lod(frame.scene_color, frame.scene_sampler, refracted_uv, 0.0).rgb;
    color = apply_fog_refracted(
        frame,
        v_world_pos,
        (1.0 - fresnel) * (1.0 - foam),
        behind,
        scene_depth_at(frame, refracted_uv),
        color
    );
    out_color = material_output(color, 1.0, material.flags);
}
