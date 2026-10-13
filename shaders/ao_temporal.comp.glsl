#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "gbuffer.glsl"
#include "texture_fetch.glsl"
#include "ambient_occlusion.glsl"
#include "screen_space_gi.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Share of the history kept per frame at full confidence; about ten frames of accumulation.
const float AO_HISTORY_WEIGHT = 0.9;

void main() {
    AoTemporalRoot root = AoTemporalRoot(pc.root_gpu);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.width || pixel.y >= root.height) return;

    FrameRoot frame = FrameRoot(root.frame);
    ivec2 extent = texture_extent(root.depth);
    ivec2 texel = ao_depth_texel(ivec2(pixel), ivec2(root.width, root.height), extent);
    float depth = fetch_texture_2d(root.depth, texel).r;
    float visibility = load_storage_texture(root.raw, ivec2(pixel)).r;
    if (depth != 0.0 && (root.flags & AO_TEMPORAL_FLAG_HISTORY_VALID) != 0u) {
        vec4 velocity = fetch_texture_2d(root.velocity, texel);
        // The history has the estimate's extent: reproject the estimate texel centre, not its depth texel's.
        // The frame's jitter stays out: samples taken under different jitters accumulate at one texel.
        vec2 centre_uv = (vec2(pixel) + 0.5) / vec2(root.width, root.height);
        vec2 previous_uv = centre_uv - velocity.xy;
        if (ssgi_uv_inside(previous_uv)) {
            bool depth_match = ssgi_depth_matches(
                frame,
                root.previous_depth,
                previous_uv,
                velocity.z,
                root.depth_tolerance
            );
            float velocity_pixels = length(velocity.xy * vec2(extent));
            float confidence = ssgi_history_confidence(depth_match, velocity_pixels, root.velocity_threshold)
                * (1.0 - clamp(velocity.a, 0.0, 1.0));
            float history = sample_texture_2d(root.history, root.sampler_index, previous_uv).r;
            visibility = mix(visibility, history, AO_HISTORY_WEIGHT * confidence);
        }
    }

    store_storage_texture(root.output_texture, ivec2(pixel), vec4(visibility));
    store_storage_texture(root.output_depth, ivec2(pixel), vec4(depth, 0.0, 0.0, 0.0));
}
