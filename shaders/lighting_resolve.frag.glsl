#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#ifdef MULTISAMPLE
#include "multisample_heap.glsl"
#endif
#include "brdf.glsl"
#include "ibl.glsl"
#include "lights.glsl"
#include "shadows.glsl"
#include "standard_shading.glsl"
#include "gbuffer.glsl"
#include "texture_fetch.glsl"
#include "depth_face.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

#ifdef MULTISAMPLE_PIXEL
// Reading SampleId would force sample rate, so the pixel-rate form names sample 0.
#define LIGHTING_SAMPLE 0
#else
#define LIGHTING_SAMPLE gl_SampleID
#endif

void main() {
    LightingResolveRoot root = LightingResolveRoot(pc.fragment_root_gpu);
#ifdef MULTISAMPLE
    ivec2 texel = ivec2(gl_FragCoord.xy);
#ifdef MULTISAMPLE_PIXEL
    // The pixel-rate draw lights pixels whose samples agree; the sample-rate draw lights the rest.
    if (gpu_fetch_uint(root.msaa_edges, texel, 0) != 0u) discard;
#else
    // A zero mask index means the view lights every pixel per sample.
    if (root.msaa_edges != 0u && gpu_fetch_uint(root.msaa_edges, texel, 0) == 0u) discard;
#endif
    // Each invocation reads one sample of every channel, flags and layers included.
    float depth = gpu_fetch_ms(root.depth, texel, LIGHTING_SAMPLE).r;
#else
    float depth = sample_texture_2d(root.depth, root.sampler_index, v_uv).r;
#endif
    // No geometry keeps the pass clear color for the sky.
    if (depth == 0.0) discard;

    FrameRoot frame = FrameRoot(root.frame);
#ifdef MULTISAMPLE
    vec3 world_position = depth_face_texel_position(frame, root.depth, texel, DEPTH_FACE_EXTENT(root.depth), depth);
    vec4 base_color_metallic = gpu_fetch_ms(root.base_color_metallic, texel, LIGHTING_SAMPLE);
    vec4 normal_roughness = gpu_fetch_ms(root.normal_roughness, texel, LIGHTING_SAMPLE);
    vec4 emissive_specular = gpu_fetch_ms(root.emissive_specular, texel, LIGHTING_SAMPLE);
    uint layers = gpu_fetch_ms_uint(root.layers, texel, LIGHTING_SAMPLE);
    uint flags = gpu_fetch_ms_uint(root.flags, texel, LIGHTING_SAMPLE);
#else
    vec3 world_position = reconstruct_world_position(frame, v_uv, depth);
    vec4 base_color_metallic = sample_texture_2d(root.base_color_metallic, root.sampler_index, v_uv);
    vec4 normal_roughness = sample_texture_2d(root.normal_roughness, root.sampler_index, v_uv);
    vec4 emissive_specular = sample_texture_2d(root.emissive_specular, root.sampler_index, v_uv);
    ivec2 texel = ivec2(gl_FragCoord.xy);
    uint layers = gpu_fetch_uint(root.layers, texel, 0);
    uint flags = gpu_fetch_uint(root.flags, texel, 0);
#endif

    vec3 base_color = base_color_metallic.rgb;
    float metallic = base_color_metallic.a;
    vec3 normal = decode_octahedral(normal_roughness.rg);
    float roughness = normal_roughness.b;
    float occlusion = normal_roughness.a;
    float specular_weight = emissive_specular.a;
    vec3 view_direction = standard_view_direction(frame, world_position);
    StandardSurface surface = prepare_surface(
        base_color,
        metallic,
        roughness,
        normal,
        view_direction,
        STANDARD_DIELECTRIC_REFLECTANCE * specular_weight,
        vec3(specular_weight)
    );

    float ambient_occlusion = frame_ambient_occlusion(frame, texel);
    vec4 screen_indirect = frame_screen_space_indirect(frame, texel);
    vec3 color = standard_ambient_fill(frame, base_color, metallic, occlusion, ambient_occlusion, screen_indirect)
        + pre_exposed(frame, emissive_specular.rgb);
    vec3 diffuse = vec3(0.0);
    vec3 specular = vec3(0.0);
    if (frame_has_indirect(frame)) {
        evaluate_environment_lobes(
            frame,
            world_position,
            surface,
            frame_bent_normal(frame, texel, normal),
            roughness,
            occlusion,
            ambient_occlusion,
            screen_indirect,
            diffuse,
            specular
        );
    }
    if (root.reflection_texture != 0u) {
        // Texel fetch: a filtered read would blend traced and untraced texels at the region's edge.
        specular = blend_traced_specular(
            specular,
            fetch_texture_2d(root.reflection_texture, texel),
            root.brdf_lut,
            root.sampler_index,
            surface,
            roughness,
            root.max_reflection_roughness
        );
    }
    color += diffuse + specular;
#ifdef RT_SHADOWS
    trace_proxy_skip_height = gbuffer_proxy_skip_height(flags);
#endif
    color += evaluate_standard_lights(
        frame,
        surface,
        world_position,
        depth_face_normal(frame, root.depth, texel, depth, view_direction),
        layers,
        (flags & GBUFFER_FLAG_RECEIVE_SHADOW) != 0u
    );
    out_color = vec4(color, 1.0);
}
