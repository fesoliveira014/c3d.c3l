#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#define SCENE_TRACE_RAY_QUERY
#define RT_SHADOWS
#include "constants.glsl"
#include "gbuffer.glsl"
#include "noise.glsl"
#include "sampling.glsl"
#include "texture_fetch.glsl"
#include "hit_shading.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const float RT_REFLECTION_FAR = 1.0e4; // world units; misses beyond it read the environment

void main() {
    RtReflectionRoot root = RtReflectionRoot(pc.root_gpu);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.width || pixel.y >= root.height) return;

    ivec2 texel = ivec2(pixel);
    float depth = fetch_texture_2d(root.depth, texel).r;
    vec4 normal_roughness = fetch_texture_2d(root.normal_roughness, texel);
    float specular_weight = fetch_texture_2d(root.emissive_specular, texel).a;
    float roughness = normal_roughness.b;
    if (depth == 0.0 || specular_weight == 0.0 || roughness > root.max_roughness) {
        store_storage_texture(root.output_texture, texel, vec4(0.0));
        return;
    }

    FrameRoot frame = FrameRoot(root.frame);
    vec2 uv = (vec2(texel) + 0.5) / vec2(root.width, root.height);
    vec3 position = reconstruct_world_position(frame, uv, depth);
    vec3 normal = decode_octahedral(normal_roughness.rg);
    vec3 view_direction = standard_view_direction(frame, position);
    float perceptual = max(roughness, MIN_PERCEPTUAL_ROUGHNESS);
    float alpha = perceptual * perceptual;

    mat3 basis = tangent_frame(normal);
    vec2 u = vec2(
        interleaved_gradient_noise(vec2(pixel), root.noise_frame),
        interleaved_gradient_noise(vec2(pixel.yx), root.noise_frame)
    );
    vec3 half_vector = basis * sample_ggx_vndf(u, transpose(basis) * view_direction, alpha);
    vec3 direction = reflect(-view_direction, half_vector);
    if (dot(direction, normal) <= 0.0) direction = reflect(-view_direction, normal);

    bool orthographic = frame.proj[3][3] != 0.0;
    float pixel_spread = 2.0 / (abs(frame.proj[1][1]) * float(root.height));
    float cone_width = orthographic ? pixel_spread : pixel_spread * view_distance(frame, depth);
    float cone_spread = orthographic ? alpha : pixel_spread + alpha;

    SceneTraceRoot scene = SceneTraceRoot(frame.trace);
    SceneHit hit;
    vec3 radiance;
    if (trace_scene(scene, position + normal * TRACE_SURFACE_OFFSET, direction, RT_REFLECTION_FAR, TRACE_MASK_ALL, hit)) {
        TraceSurface surface = surface_from_hit(scene, hit, direction, cone_width + hit.t * cone_spread);
        radiance = shade_hit(frame, surface, -direction);
    } else {
        radiance = trace_miss_radiance(frame, direction);
    }
    store_storage_texture(root.output_texture, texel, vec4(radiance, 1.0));
}
