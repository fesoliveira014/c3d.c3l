#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "brdf.glsl"
#include "ibl.glsl"
#include "lights.glsl"
#ifdef RT_SHADOWS
#define SCENE_TRACE_RAY_QUERY
#include "scene_trace.glsl"
#endif
#include "shadows.glsl"
#include "gbuffer.glsl"
#include "texture_fetch.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

const float RT_REFLECTION_FADE = 0.2; // share of the threshold over which traced and prefiltered radiance blend; hides the seam

void main() {
    LightingResolveRoot root = LightingResolveRoot(pc.fragment_root_gpu);
    float depth = sample_texture_2d(root.depth, root.sampler_index, v_uv).r;
    // No geometry keeps the pass clear color for the sky.
    if (depth == 0.0) discard;

    FrameRoot frame = FrameRoot(root.frame);
    vec3 world_position = reconstruct_world_position(frame, v_uv, depth);
    vec4 base_color_metallic = sample_texture_2d(root.base_color_metallic, root.sampler_index, v_uv);
    vec4 normal_roughness = sample_texture_2d(root.normal_roughness, root.sampler_index, v_uv);
    vec4 emissive_specular = sample_texture_2d(root.emissive_specular, root.sampler_index, v_uv);
    ivec2 texel = ivec2(gl_FragCoord.xy);
    uint layers = gpu_fetch_uint(root.layers, texel, 0);
    uint flags = gpu_fetch_uint(root.flags, texel, 0);

    vec3 base_color = base_color_metallic.rgb;
    float metallic = base_color_metallic.a;
    vec3 normal = decode_octahedral(normal_roughness.rg);
    float roughness = normal_roughness.b;
    float occlusion = normal_roughness.a;
    float specular_weight = emissive_specular.a;
    StandardSurface surface = prepare_surface(
        base_color,
        metallic,
        roughness,
        normal,
        standard_view_direction(frame, world_position),
        STANDARD_DIELECTRIC_REFLECTANCE * specular_weight,
        vec3(specular_weight)
    );

    float ambient_occlusion = frame_ambient_occlusion(frame, texel);
    vec3 color = frame.ambient.rgb * base_color * (1.0 - metallic) * min(occlusion, ambient_occlusion)
        + emissive_specular.rgb;
    vec3 diffuse = vec3(0.0);
    vec3 specular = vec3(0.0);
    if (frame.environment != 0ul) {
        EnvironmentGpu environment = EnvironmentGpu(frame.environment);
        evaluate_environment_lobes(environment, surface, roughness, occlusion, ambient_occlusion, diffuse, specular);
    }
    if (root.reflection_texture != 0u) {
        // Texel fetch: a filtered read would blend traced and untraced texels at the region's edge.
        vec4 traced = fetch_texture_2d(root.reflection_texture, texel);
        if (traced.a > 0.0) {
            float perceptual = max(roughness, MIN_PERCEPTUAL_ROUGHNESS);
            vec3 traced_specular = traced.rgb
                * environment_brdf_weight(root.brdf_lut, root.sampler_index, surface, perceptual);
            float threshold = root.max_reflection_roughness;
            specular = mix(specular, traced_specular, clamp((threshold - roughness) / (RT_REFLECTION_FADE * threshold), 0.0, 1.0));
        }
    }
    color += diffuse + specular;
    float view_depth = -(frame.view * vec4(world_position, 1.0)).z;
    LightList lights = select_lights(frame, world_position, view_depth);
    for (uint index = 0u; index < lights.count; index++) {
        LightGpu light = LightArray(frame.lights).values[selected_light_index(frame, lights, index)];
        if ((layers & light.layers) == 0u) continue;
        float visibility = 1.0;
        if ((flags & GBUFFER_FLAG_RECEIVE_SHADOW) != 0u && light_casts_shadow(light)) {
            visibility = shadow_visibility(frame, light, world_position, normal, view_depth);
        }
        color += visibility * evaluate_standard_light(light, world_position, surface);
    }
    out_color = vec4(color, 1.0);
}
