#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"

// FXAA 3.11 quality, preset 12; luma is the alpha written by the grade stage.
layout(local_size_x = 8, local_size_y = 8) in;

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const float FXAA_SUBPIX = 0.75;
const float FXAA_EDGE_THRESHOLD = 0.166;
const float FXAA_EDGE_THRESHOLD_MIN = 0.0833;
const float FXAA_SEARCH_STEP_0 = 1.0;
const float FXAA_SEARCH_STEP_1 = 1.5;
const float FXAA_SEARCH_STEP_2 = 2.0;
const float FXAA_SEARCH_STEP_3 = 4.0;
const float FXAA_SEARCH_STEP_4 = 12.0;

FxaaRoot root;

vec4 fetch(vec2 uv) {
    return sample_texture_2d(root.input_texture, root.sampler_index, uv);
}

float luma_at(vec2 uv, vec2 offset_texels, vec2 inverse_size) {
    return fetch(uv + offset_texels * inverse_size).a;
}

bool search_step(
    inout vec2 position_negative,
    inout vec2 position_positive,
    inout float luma_end_negative,
    inout float luma_end_positive,
    inout bool done_negative,
    inout bool done_positive,
    vec2 offset,
    float step_scale,
    float luma_average,
    float gradient_scaled
) {
    if (!done_negative) luma_end_negative = fetch(position_negative).a - luma_average;
    if (!done_positive) luma_end_positive = fetch(position_positive).a - luma_average;
    done_negative = abs(luma_end_negative) >= gradient_scaled;
    done_positive = abs(luma_end_positive) >= gradient_scaled;
    if (!done_negative) position_negative -= offset * step_scale;
    if (!done_positive) position_positive += offset * step_scale;
    return !done_negative || !done_positive;
}

vec4 fxaa(vec2 uv, vec2 inverse_size) {
    vec4 center = fetch(uv);
    float luma_center = center.a;
    float luma_south = luma_at(uv, vec2(0.0, 1.0), inverse_size);
    float luma_east = luma_at(uv, vec2(1.0, 0.0), inverse_size);
    float luma_north = luma_at(uv, vec2(0.0, -1.0), inverse_size);
    float luma_west = luma_at(uv, vec2(-1.0, 0.0), inverse_size);

    float range_max = max(max(luma_north, luma_west), max(luma_east, max(luma_south, luma_center)));
    float range_min = min(min(luma_north, luma_west), min(luma_east, min(luma_south, luma_center)));
    float range = range_max - range_min;
    if (range < max(FXAA_EDGE_THRESHOLD_MIN, range_max * FXAA_EDGE_THRESHOLD)) return center;

    float luma_north_west = luma_at(uv, vec2(-1.0, -1.0), inverse_size);
    float luma_south_east = luma_at(uv, vec2(1.0, 1.0), inverse_size);
    float luma_north_east = luma_at(uv, vec2(1.0, -1.0), inverse_size);
    float luma_south_west = luma_at(uv, vec2(-1.0, 1.0), inverse_size);

    float luma_ns = luma_north + luma_south;
    float luma_we = luma_west + luma_east;
    float subpix_rcp_range = 1.0 / range;
    float subpix_nswe = luma_ns + luma_we;
    float edge_horizontal_1 = -2.0 * luma_center + luma_ns;
    float edge_vertical_1 = -2.0 * luma_center + luma_we;
    float luma_nese = luma_north_east + luma_south_east;
    float luma_nwne = luma_north_west + luma_north_east;
    float edge_horizontal_2 = -2.0 * luma_east + luma_nese;
    float edge_vertical_2 = -2.0 * luma_north + luma_nwne;
    float luma_nwsw = luma_north_west + luma_south_west;
    float luma_swse = luma_south_west + luma_south_east;
    float edge_horizontal_4 = abs(edge_horizontal_1) * 2.0 + abs(edge_horizontal_2);
    float edge_vertical_4 = abs(edge_vertical_1) * 2.0 + abs(edge_vertical_2);
    float edge_horizontal_3 = -2.0 * luma_west + luma_nwsw;
    float edge_vertical_3 = -2.0 * luma_south + luma_swse;
    float edge_horizontal = abs(edge_horizontal_3) + edge_horizontal_4;
    float edge_vertical = abs(edge_vertical_3) + edge_vertical_4;
    float subpix_diagonal = luma_nwsw + luma_nese;

    bool horizontal_span = edge_horizontal >= edge_vertical;
    float length_sign = horizontal_span ? inverse_size.y : inverse_size.x;
    float subpix_a = subpix_nswe * 2.0 + subpix_diagonal;
    if (!horizontal_span) luma_north = luma_west;
    if (!horizontal_span) luma_south = luma_east;
    float subpix_b = subpix_a * (1.0 / 12.0) - luma_center;

    float gradient_north = luma_north - luma_center;
    float gradient_south = luma_south - luma_center;
    float luma_nn = luma_north + luma_center;
    float luma_ss = luma_south + luma_center;
    bool pair_north = abs(gradient_north) >= abs(gradient_south);
    float gradient = max(abs(gradient_north), abs(gradient_south));
    if (pair_north) length_sign = -length_sign;
    float subpix_c = clamp(abs(subpix_b) * subpix_rcp_range, 0.0, 1.0);

    vec2 position_base = uv;
    if (horizontal_span) {
        position_base.y += length_sign * 0.5;
    } else {
        position_base.x += length_sign * 0.5;
    }
    vec2 offset = horizontal_span ? vec2(inverse_size.x, 0.0) : vec2(0.0, inverse_size.y);
    vec2 position_negative = position_base - offset * FXAA_SEARCH_STEP_0;
    vec2 position_positive = position_base + offset * FXAA_SEARCH_STEP_0;
    float subpix_d = -2.0 * subpix_c + 3.0;
    float subpix_e = subpix_c * subpix_c;
    float luma_average = 0.5 * (pair_north ? luma_nn : luma_ss);
    float gradient_scaled = gradient * 0.25;
    float luma_center_below = luma_center - luma_average;
    float subpix_f = subpix_d * subpix_e;
    bool center_below_average = luma_center_below < 0.0;

    float luma_end_negative = fetch(position_negative).a - luma_average;
    float luma_end_positive = fetch(position_positive).a - luma_average;
    bool done_negative = abs(luma_end_negative) >= gradient_scaled;
    bool done_positive = abs(luma_end_positive) >= gradient_scaled;
    if (!done_negative) position_negative -= offset * FXAA_SEARCH_STEP_1;
    if (!done_positive) position_positive += offset * FXAA_SEARCH_STEP_1;
    bool searching = !done_negative || !done_positive;
    if (searching) {
        searching = search_step(position_negative, position_positive, luma_end_negative, luma_end_positive,
            done_negative, done_positive, offset, FXAA_SEARCH_STEP_2, luma_average, gradient_scaled);
    }
    if (searching) {
        searching = search_step(position_negative, position_positive, luma_end_negative, luma_end_positive,
            done_negative, done_positive, offset, FXAA_SEARCH_STEP_3, luma_average, gradient_scaled);
    }
    if (searching) {
        searching = search_step(position_negative, position_positive, luma_end_negative, luma_end_positive,
            done_negative, done_positive, offset, FXAA_SEARCH_STEP_4, luma_average, gradient_scaled);
    }

    float distance_negative = horizontal_span ? uv.x - position_negative.x : uv.y - position_negative.y;
    float distance_positive = horizontal_span ? position_positive.x - uv.x : position_positive.y - uv.y;
    bool good_span_negative = (luma_end_negative < 0.0) != center_below_average;
    bool good_span_positive = (luma_end_positive < 0.0) != center_below_average;
    float span_length = distance_positive + distance_negative;
    bool direction_negative = distance_negative < distance_positive;
    float distance_nearest = min(distance_negative, distance_positive);
    bool good_span = direction_negative ? good_span_negative : good_span_positive;
    float subpix_g = subpix_f * subpix_f;
    float pixel_offset = distance_nearest * (-1.0 / span_length) + 0.5;
    float subpix_h = subpix_g * FXAA_SUBPIX;
    float pixel_offset_good = good_span ? pixel_offset : 0.0;
    float pixel_offset_subpix = max(pixel_offset_good, subpix_h);

    vec2 final_uv = uv;
    if (horizontal_span) {
        final_uv.y += pixel_offset_subpix * length_sign;
    } else {
        final_uv.x += pixel_offset_subpix * length_sign;
    }
    return fetch(final_uv);
}

void main() {
    root = FxaaRoot(pc.root_gpu);
    uvec2 texel = gl_GlobalInvocationID.xy;
    if (texel.x >= root.width || texel.y >= root.height) return;

    vec2 inverse_size = 1.0 / vec2(root.width, root.height);
    vec2 uv = (vec2(texel) + 0.5) * inverse_size;
    vec4 filtered = fxaa(uv, inverse_size);
    store_storage_texture(root.output_texture, ivec2(texel), vec4(filtered.rgb, 1.0));
}
