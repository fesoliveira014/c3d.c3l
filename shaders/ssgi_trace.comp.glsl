#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "constants.glsl"
#include "gbuffer.glsl"
#include "noise.glsl"
#include "sampling.glsl"
#include "texture_fetch.glsl"
#include "ambient_occlusion.glsl"
#include "ao_estimate.glsl"
#include "screen_space_gi.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const uint SSGI_SECOND_SEQUENCE = 7u;  // offsets the second noise stream so the two coordinates decorrelate
const uint SSGI_STEP_SEQUENCE = 13u;   // offsets the step jitter stream

vec3 surface_normal(
    SsgiTraceRoot root,
    FrameRoot frame,
    ivec2 texel,
    float depth,
    vec3 position
) {
    bool orthographic = frame.proj[3][3] != 0.0;
    vec3 view_vector = orthographic ? vec3(0.0, 0.0, 1.0) : normalize(-position);
    if ((root.flags & SSGI_FLAG_GBUFFER_NORMALS) != 0u) {
        vec4 gbuffer_normal = fetch_texture_2d(root.normals, texel);
        if (ao_gbuffer_normal_written(gbuffer_normal)) {
            return normalize(mat3(frame.view) * decode_octahedral(gbuffer_normal.rg));
        }
    }
    return ao_reconstructed_normal(frame, root.depth, texel, depth, view_vector);
}

void main() {
    SsgiTraceRoot root = SsgiTraceRoot(pc.root_gpu);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.width || pixel.y >= root.height) return;

    FrameRoot frame = FrameRoot(root.frame);
    ivec2 extent = texture_extent(root.depth);
    ivec2 texel = ao_depth_texel(ivec2(pixel), ivec2(root.width, root.height), extent);
    float depth = fetch_texture_2d(root.depth, texel).r;
    // Without a previous frame there is no lit colour to read; the consumers keep the base term.
    if (depth == 0.0 || (root.flags & SSGI_FLAG_HISTORY_VALID) == 0u) {
        store_storage_texture(root.output_texture, ivec2(pixel), vec4(0.0));
        return;
    }

    vec3 position = ao_view_position(frame, texel, extent, depth);
    vec3 normal = surface_normal(root, frame, texel, depth, position);
    mat3 basis = tangent_frame(normal);
    float step_length = root.max_distance / float(root.max_steps);
    vec3 sum = vec3(0.0);
    float hits = 0.0;
    for (uint ray = 0u; ray < root.rays; ray++) {
        uint sequence = root.noise_frame * root.rays + ray;
        vec2 u = vec2(
            interleaved_gradient_noise(vec2(pixel), sequence),
            interleaved_gradient_noise(vec2(pixel.yx), sequence + SSGI_SECOND_SEQUENCE)
        );
        vec3 direction = basis * cosine_sample_hemisphere(u);
        float step_offset = interleaved_gradient_noise(vec2(pixel), sequence + SSGI_STEP_SEQUENCE);
        for (uint step_index = 1u; step_index <= root.max_steps; step_index++) {
            vec3 point = position + direction * step_length * (float(step_index) - step_offset);
            vec4 clip = frame.proj * vec4(point, 1.0);
            if (clip.w <= 0.0) break;
            vec2 uv = (clip.xy / clip.w) * vec2(0.5, -0.5) + 0.5;
            if (!ssgi_uv_inside(uv)) break;
            ivec2 hit_texel = min(ivec2(uv * vec2(extent)), extent - 1);
            float stored_depth = fetch_texture_2d(root.depth, hit_texel).r;
            if (stored_depth == 0.0) continue;
            float behind = -point.z - view_distance(frame, stored_depth);
            if (behind <= 0.0 || behind >= root.thickness) continue;

            vec2 hit_uv = (vec2(hit_texel) + 0.5) / vec2(extent);
            vec4 velocity = fetch_texture_2d(root.velocity, hit_texel);
            vec2 previous_uv = ssgi_previous_uv(frame, hit_uv, velocity);
            vec3 hit_position = ao_view_position(frame, hit_texel, extent, stored_depth);
            bool faces = dot(surface_normal(root, frame, hit_texel, stored_depth, hit_position), -direction) > 0.0;
            if (faces && ssgi_uv_inside(previous_uv)
                && ssgi_depth_matches(frame, root.previous_depth, previous_uv, velocity.z, root.depth_tolerance)) {
                sum += sample_texture_2d(root.previous_color, root.sampler_index, previous_uv).rgb;
                hits += 1.0;
            }
            break;
        }
    }
    float rays = float(root.rays);
    store_storage_texture(root.output_texture, ivec2(pixel), vec4(PI * sum / rays, hits / rays));
}
