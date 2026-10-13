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

#ifdef BENT_NORMALS
// A tap's visibility in x and its bent normal in yzw.
vec4 load_estimate_tap(uint input_texture, ivec2 tap, bool vector_input) {
    vec4 stored = load_storage_texture(input_texture, tap);
    if (vector_input) return vec4(stored.w, stored.xyz);

    return vec4(stored.r, ao_unpack_bent_normal(stored.gb));
}
#endif

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
#ifdef BENT_NORMALS
    bool vector_input = (root.flags & AO_BLUR_FLAG_VECTOR_INPUT) != 0u;
    vec3 total_normal = vec3(0.0);
    vec3 nearest_normal = vec3(0.0, 1.0, 0.0);
#endif
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            ivec2 tap = first + ivec2(x, y);
            if (any(lessThan(tap, ivec2(0))) || any(greaterThanEqual(tap, input_extent))) continue;
            vec2 offset = abs(vec2(tap) - source) / AO_BLUR_TENT_RADIUS;
            float tent = max(0.0, 1.0 - offset.x) * max(0.0, 1.0 - offset.y);
            float tap_depth = fetch_texture_2d(root.depth, ao_depth_texel(tap, input_extent, depth_extent)).r;
            if (tent == 0.0 || tap_depth == 0.0) continue;

#ifdef BENT_NORMALS
            vec4 tap_estimate = load_estimate_tap(root.input_texture, tap, vector_input);
            float tap_value = tap_estimate.x;
#else
            float tap_value = load_storage_texture(root.input_texture, tap).r;
#endif
            float gap = abs(view_distance(frame, tap_depth) - centre_distance);
            if (gap < nearest_gap) {
                nearest_gap = gap;
                nearest_value = tap_value;
#ifdef BENT_NORMALS
                nearest_normal = tap_estimate.yzw;
#endif
            }
            float weight = tent * exp(-gap / (AO_BLUR_DEPTH_FRACTION * centre_distance));
            total += weight * tap_value;
            weight_sum += weight;
#ifdef BENT_NORMALS
            total_normal += weight * tap_estimate.yzw;
#endif
        }
    }
    float occlusion = weight_sum > AO_BLUR_MIN_WEIGHT ? total / weight_sum : nearest_value;
#ifdef BENT_NORMALS
    vec2 packed_normal = ao_pack_bent_normal(ao_direction_or(total_normal, nearest_normal));
    store_storage_texture(root.output_texture, ivec2(pixel), vec4(occlusion, packed_normal, 1.0));
#else
    store_storage_texture(root.output_texture, ivec2(pixel), vec4(occlusion));
#endif
}
