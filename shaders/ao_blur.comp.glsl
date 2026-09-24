#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "gbuffer.glsl"
#include "texture_fetch.glsl"
#include "ambient_occlusion.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Relative depth gap at which a tap's weight falls to e^-1; wider bleeds AO across silhouettes.
const float AO_BLUR_DEPTH_FRACTION = 0.1;
const float AO_BLUR_TENT_RADIUS = 2.0;    // input texels; the 4x4 footprint around the source position
const float AO_BLUR_MIN_WEIGHT = 1e-5;

void main() {
    AoBlurRoot root = AoBlurRoot(pc.root_gpu);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.width || pixel.y >= root.height) return;

    FrameRoot frame = FrameRoot(root.frame);
    ivec2 depth_extent = texture_extent(root.depth);
    ivec2 output_extent = ivec2(root.width, root.height);
    float centre_depth = fetch_texture_2d(root.depth, ao_depth_texel(ivec2(pixel), output_extent, depth_extent)).r;
    if (centre_depth == 0.0) {
        store_storage_texture(root.output_texture, ivec2(pixel), vec4(1.0));
        return;
    }

    float centre_distance = view_distance(frame, centre_depth);
    ivec2 input_extent = ivec2(root.input_width, root.input_height);
    vec2 source = (vec2(pixel) + 0.5) * vec2(input_extent) / vec2(output_extent) - 0.5;
    ivec2 first = ivec2(floor(source)) - 1;
    float total = 0.0;
    float weight_sum = 0.0;
    float nearest_value = 1.0;
    float nearest_gap = BACKGROUND_VIEW_DISTANCE;
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            ivec2 tap = first + ivec2(x, y);
            if (any(lessThan(tap, ivec2(0))) || any(greaterThanEqual(tap, input_extent))) continue;
            vec2 offset = abs(vec2(tap) - source) / AO_BLUR_TENT_RADIUS;
            float tent = max(0.0, 1.0 - offset.x) * max(0.0, 1.0 - offset.y);
            float tap_depth = fetch_texture_2d(root.depth, ao_depth_texel(tap, input_extent, depth_extent)).r;
            if (tent == 0.0 || tap_depth == 0.0) continue;

            float tap_value = load_storage_texture(root.input_texture, tap).r;
            float gap = abs(view_distance(frame, tap_depth) - centre_distance);
            if (gap < nearest_gap) {
                nearest_gap = gap;
                nearest_value = tap_value;
            }
            float weight = tent * exp(-gap / (AO_BLUR_DEPTH_FRACTION * centre_distance));
            total += weight * tap_value;
            weight_sum += weight;
        }
    }
    float occlusion = weight_sum > AO_BLUR_MIN_WEIGHT ? total / weight_sum : nearest_value;
    store_storage_texture(root.output_texture, ivec2(pixel), vec4(occlusion));
}
