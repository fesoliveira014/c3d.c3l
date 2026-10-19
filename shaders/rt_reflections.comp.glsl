#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#ifndef SCENE_TRACE_BVH
#define SCENE_TRACE_RAY_QUERY
#endif
#define RT_SHADOWS
#include "constants.glsl"
#include "gbuffer.glsl"
#include "noise.glsl"
#include "sampling.glsl"
#include "texture_fetch.glsl"
#include "hit_shading.glsl"
#include "fog.glsl"
#include "rt_reflection.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const float RT_REFLECTION_FAR = 1.0e4; // world units; misses beyond it read the environment

void main() {
    RtReflectionRoot root = RtReflectionRoot(pc.root_gpu);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.width || pixel.y >= root.height) return;

    ivec2 output_texel = ivec2(pixel);
    ivec2 texel = output_texel;
    ivec2 extent = ivec2(root.width, root.height);
    if (root.trace_shift != 0u) {
        extent = texture_extent(root.depth);
        ivec2 block_offset = RT_REFLECTION_HALF_OFFSETS[root.noise_frame & 3u];
        texel = min((output_texel << int(root.trace_shift)) + block_offset, extent - 1);
    }

    float depth = fetch_texture_2d(root.depth, texel).r;
    vec4 normal_roughness = fetch_texture_2d(root.normal_roughness, texel);
    float specular_weight = fetch_texture_2d(root.emissive_specular, texel).a;
    float roughness = normal_roughness.b;
    if (depth == 0.0 || specular_weight == 0.0 || roughness > root.max_roughness) {
        store_storage_texture(root.output_texture, output_texel, vec4(0.0));
        return;
    }

    FrameRoot frame = FrameRoot(root.frame);
    vec2 uv = (vec2(texel) + 0.5) / vec2(extent);
    vec3 position = reconstruct_world_position(frame, uv, depth);
    vec3 normal = decode_octahedral(normal_roughness.rg);
    vec3 view_direction = standard_view_direction(frame, position);
    // A shading normal facing away from the eye reflects below the surface; the raster term stays.
    if (dot(view_direction, normal) <= 0.0) {
        store_storage_texture(root.output_texture, output_texel, vec4(0.0));
        return;
    }

    float perceptual = max(roughness, MIN_PERCEPTUAL_ROUGHNESS);
    float alpha = perceptual * perceptual;

    mat3 basis = tangent_frame(normal);
    bool orthographic = frame.proj[3][3] != 0.0;
    float pixel_spread = 2.0 / (abs(frame.proj[1][1]) * float(extent.y));
    float cone_width = orthographic ? pixel_spread : pixel_spread * view_distance(frame, depth);
    float cone_spread = orthographic ? alpha : pixel_spread + alpha;
    SceneTraceRoot scene = SceneTraceRoot(frame.trace);
    vec3 origin = position + normal * TRACE_SURFACE_OFFSET;
    float proxy_skip_height = root.flags != 0u ? gbuffer_proxy_skip_height(gpu_fetch_uint(root.flags, texel, 0)) : 0.0;

    vec3 radiance_sum = vec3(0.0);
    for (uint ray = 0u; ray < root.ray_count; ray++) {
        uint sequence = root.noise_frame * root.ray_count + ray;
        vec2 u = vec2(
            interleaved_gradient_noise(vec2(texel), sequence),
            interleaved_gradient_noise(vec2(texel.yx), sequence)
        );
        vec3 half_vector = basis * sample_ggx_vndf(u, transpose(basis) * view_direction, alpha);
        vec3 direction = reflect(-view_direction, half_vector);
        if (dot(direction, normal) <= 0.0) direction = reflect(-view_direction, normal);

        SceneHit hit;
        vec3 radiance;
        float proxy_t_min = trace_proxy_t_min(proxy_skip_height, direction, normal);
        if (trace_scene(scene, origin, direction, RT_REFLECTION_FAR, TRACE_MASK_ALL, proxy_t_min, hit)) {
            TraceSurface surface = surface_from_hit(scene, hit, direction, cone_width + hit.t * cone_spread);
            radiance = shade_hit(frame, HitLights(root.lights, root.light_count, root.light_spatial), surface, -direction);
            radiance = apply_fog_segment(frame, position, surface.position, radiance);
        } else {
            radiance = trace_miss_radiance(frame, direction);
            radiance = apply_fog_to_infinity(frame, position, direction, radiance);
        }

        radiance_sum += radiance;
    }

    store_storage_texture(root.output_texture, output_texel, vec4(radiance_sum / float(root.ray_count), 1.0));
}
