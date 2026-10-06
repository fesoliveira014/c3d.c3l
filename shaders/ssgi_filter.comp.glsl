#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "gbuffer.glsl"
#include "texture_fetch.glsl"
#include "ambient_occlusion.glsl"
#include "ao_estimate.glsl"

layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

// Relative depth gap at which a tap's weight falls to e^-1; wider bleeds bounce across silhouettes.
const float SSGI_FILTER_DEPTH_FRACTION = 0.1;
const float SSGI_FILTER_NORMAL_POWER = 8.0; // keeps light from creases on the other face
const float SSGI_FILTER_TENT_RADIUS = 2.0;  // input texels; the 4x4 footprint around the source position
const float SSGI_FILTER_MIN_WEIGHT = 1e-5;

vec3 filter_normal(SsgiFilterRoot root, FrameRoot frame, ivec2 texel, ivec2 extent, float depth) {
    vec3 position = ao_view_position(frame, texel, extent, depth);
    if ((root.flags & SSGI_FLAG_GBUFFER_NORMALS) != 0u) {
        vec4 gbuffer_normal = fetch_texture_2d(root.normals, texel);
        if (ao_gbuffer_normal_written(gbuffer_normal)) {
            return normalize(mat3(frame.view) * decode_octahedral(gbuffer_normal.rg));
        }
    }
    bool orthographic = frame.proj[3][3] != 0.0;
    vec3 view_vector = orthographic ? vec3(0.0, 0.0, 1.0) : normalize(-position);
    return ao_reconstructed_normal(frame, root.depth, texel, depth, view_vector);
}

void main() {
    SsgiFilterRoot root = SsgiFilterRoot(pc.root_gpu);
    uvec2 pixel = gl_GlobalInvocationID.xy;
    if (pixel.x >= root.width || pixel.y >= root.height) return;

    FrameRoot frame = FrameRoot(root.frame);
    ivec2 depth_extent = texture_extent(root.depth);
    ivec2 output_extent = ivec2(root.width, root.height);
    ivec2 centre_texel = ao_depth_texel(ivec2(pixel), output_extent, depth_extent);
    float centre_depth = fetch_texture_2d(root.depth, centre_texel).r;
    if (centre_depth == 0.0) {
        store_storage_texture(root.output_texture, ivec2(pixel), vec4(0.0));
        return;
    }

    float centre_distance = view_distance(frame, centre_depth);
    vec3 centre_normal = filter_normal(root, frame, centre_texel, depth_extent, centre_depth);
    ivec2 input_extent = ivec2(root.input_width, root.input_height);
    vec2 source = (vec2(pixel) + 0.5) * vec2(input_extent) / vec2(output_extent) - 0.5;
    ivec2 first = ivec2(floor(source)) - 1;
    vec4 total = vec4(0.0);
    float weight_sum = 0.0;
    vec4 nearest_value = vec4(0.0);
    float nearest_gap = BACKGROUND_VIEW_DISTANCE;
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            ivec2 tap = first + ivec2(x, y);
            if (any(lessThan(tap, ivec2(0))) || any(greaterThanEqual(tap, input_extent))) continue;
            vec2 offset = abs(vec2(tap) - source) / SSGI_FILTER_TENT_RADIUS;
            float tent = max(0.0, 1.0 - offset.x) * max(0.0, 1.0 - offset.y);
            ivec2 tap_texel = ao_depth_texel(tap, input_extent, depth_extent);
            float tap_depth = fetch_texture_2d(root.depth, tap_texel).r;
            if (tent == 0.0 || tap_depth == 0.0) continue;

            vec4 tap_value = fetch_texture_2d(root.input_texture, tap);
            float gap = abs(view_distance(frame, tap_depth) - centre_distance);
            if (gap < nearest_gap) {
                nearest_gap = gap;
                nearest_value = tap_value;
            }
            vec3 tap_normal = filter_normal(root, frame, tap_texel, depth_extent, tap_depth);
            float weight = tent * exp(-gap / (SSGI_FILTER_DEPTH_FRACTION * centre_distance))
                * pow(max(dot(tap_normal, centre_normal), 0.0), SSGI_FILTER_NORMAL_POWER);
            total += weight * tap_value;
            weight_sum += weight;
        }
    }
    vec4 filtered = weight_sum > SSGI_FILTER_MIN_WEIGHT ? total / weight_sum : nearest_value;
    store_storage_texture(root.output_texture, ivec2(pixel), filtered * root.intensity);
}
