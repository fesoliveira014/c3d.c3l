#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#define SCENE_TRACE_RAY_QUERY
#include "scene_trace.glsl"
#include "gbuffer.glsl"
#include "noise.glsl"
#include "sampling.glsl"
#include "texture_fetch.glsl"
#include "ambient_occlusion.glsl"
#include "ao_estimate.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

void main() {
    RtAoRoot root = RtAoRoot(pc.root_gpu);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.width || pixel.y >= root.height) return;

    FrameRoot frame = FrameRoot(root.frame);
    ivec2 extent = texture_extent(root.depth);
    ivec2 texel = ao_depth_texel(ivec2(pixel), ivec2(root.width, root.height), extent);
    float depth = fetch_texture_2d(root.depth, texel).r;
    if (depth == 0.0) {
        store_storage_texture(root.output_texture, ivec2(pixel), vec4(1.0));
        return;
    }

    vec2 uv = (vec2(texel) + 0.5) / vec2(extent);
    vec3 position = reconstruct_world_position(frame, uv, depth);
    vec3 normal;
    if (root.normals != 0u) {
        normal = decode_octahedral(fetch_texture_2d(root.normals, texel).rg);
    } else {
        vec3 view_position = (frame.view * vec4(position, 1.0)).xyz;
        bool orthographic = frame.proj[3][3] != 0.0;
        vec3 view_vector = orthographic ? vec3(0.0, 0.0, 1.0) : normalize(-view_position);
        vec3 view_normal = ao_reconstructed_normal(frame, root.depth, texel, extent, view_position, view_vector);
        normal = normalize(transpose(mat3(frame.view)) * view_normal);
    }

    mat3 basis = tangent_frame(normal);
    float noise_a = interleaved_gradient_noise(vec2(pixel), root.noise_frame);
    float noise_b = interleaved_gradient_noise(vec2(pixel.yx), root.noise_frame);
    SceneTraceRoot scene = SceneTraceRoot(frame.trace);
    vec3 origin = position + normal * TRACE_SURFACE_OFFSET;
    float occlusion = 0.0;
    for (uint ray = 0u; ray < root.ray_count; ray++) {
        vec2 u = vec2(
            fract((float(ray) + noise_a) / float(root.ray_count)),
            fract(noise_b + float(ray) * GOLDEN_RATIO_CONJUGATE)
        );
        vec3 direction = basis * cosine_sample_hemisphere(u);
        SceneHit hit;
        if (trace_scene(scene, origin, direction, root.radius, TRACE_MASK_ALL, hit)) {
            occlusion += ao_falloff(hit.t, root.radius);
        }
    }
    float visibility = 1.0 - occlusion / float(root.ray_count);
    float value = clamp(1.0 - root.intensity * (1.0 - visibility), 0.0, 1.0);
    store_storage_texture(root.output_texture, ivec2(pixel), vec4(value));
}
