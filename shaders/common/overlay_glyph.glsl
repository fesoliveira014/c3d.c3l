// Glyph coverage ported from the Slug reference pixel shader (github.com/EricLengyel/Slug).
// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright 2017, by Eric Lengyel.
// Curves and bands are FONT_TEXTURE_WIDTH-wide textures; a band texel packs two u16 values, low half first.

#ifndef OVERLAY_GLYPH_GLSL
#define OVERLAY_GLYPH_GLSL

#include "descriptor_heap.glsl"

// Which of a sample-relative curve's two roots cross the ray, from the signs of its three coordinates.
uint glyph_root_code(float y1, float y2, float y3) {
    uint i1 = floatBitsToUint(y1) >> 31u;
    uint i2 = floatBitsToUint(y2) >> 30u;
    uint i3 = floatBitsToUint(y3) >> 29u;
    uint shift = (i2 & 2u) | (i1 & ~2u);
    shift = (i3 & 4u) | (shift & ~4u);
    return (0x2E74u >> shift) & 0x0101u;
}

// x where the curve crosses y = 0; a nearly linear curve solves the linear term only.
vec2 glyph_solve_horizontal(vec4 p12, vec2 p3) {
    vec2 a = p12.xy - p12.zw * 2.0 + p3;
    vec2 b = p12.xy - p12.zw;
    float d = sqrt(max(b.y * b.y - a.y * p12.y, 0.0));
    float t1 = (b.y - d) / a.y;
    float t2 = (b.y + d) / a.y;
    if (abs(a.y) < 1.0 / 65536.0) {
        t1 = p12.y * 0.5 / b.y;
        t2 = t1;
    }
    return vec2((a.x * t1 - b.x * 2.0) * t1 + p12.x, (a.x * t2 - b.x * 2.0) * t2 + p12.x);
}

// y where the curve crosses x = 0.
vec2 glyph_solve_vertical(vec4 p12, vec2 p3) {
    vec2 a = p12.xy - p12.zw * 2.0 + p3;
    vec2 b = p12.xy - p12.zw;
    float d = sqrt(max(b.x * b.x - a.x * p12.x, 0.0));
    float t1 = (b.x - d) / a.x;
    float t2 = (b.x + d) / a.x;
    if (abs(a.x) < 1.0 / 65536.0) {
        t1 = p12.x * 0.5 / b.x;
        t2 = t1;
    }
    return vec2((a.y * t1 - b.y * 2.0) * t1 + p12.y, (a.y * t2 - b.y * 2.0) * t2 + p12.y);
}

ivec2 glyph_band_texel(ivec2 glyph_texel, uint offset) {
    ivec2 texel = ivec2(glyph_texel.x + int(offset), glyph_texel.y);
    texel.y += texel.x >> int(FONT_TEXTURE_WIDTH_SHIFT);
    texel.x &= int(FONT_TEXTURE_WIDTH) - 1;
    return texel;
}

uvec2 glyph_band_fetch(uint band_texture, ivec2 texel) {
    uint packed_value = gpu_fetch_uint(band_texture, texel, 0);
    return uvec2(packed_value & 0xFFFFu, packed_value >> 16u);
}

vec4 glyph_curve_fetch(uint curve_texture, ivec2 texel) {
    return texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(curve_texture))], texel, 0);
}

// glyph: band block column and row, last vertical band, last horizontal band.
// band_transform: em to band index scale (xy) and offset (zw).
float glyph_coverage(
    uint curve_texture,
    uint band_texture,
    vec2 em,
    vec2 pixels_per_em,
    vec4 band_transform,
    ivec4 glyph
) {
    ivec2 band_index = clamp(ivec2(em * band_transform.xy + band_transform.zw), ivec2(0), glyph.zw);
    ivec2 glyph_texel = glyph.xy;

    float x_coverage = 0.0;
    float x_weight = 0.0;
    uvec2 horizontal_band = glyph_band_fetch(band_texture, ivec2(glyph_texel.x + band_index.y, glyph_texel.y));
    ivec2 horizontal_list = glyph_band_texel(glyph_texel, horizontal_band.y);
    for (uint entry = 0u; entry < horizontal_band.x; entry++) {
        ivec2 list_texel = ivec2(horizontal_list.x + int(entry), horizontal_list.y);
        ivec2 curve_texel = ivec2(glyph_band_fetch(band_texture, list_texel));
        vec4 p12 = glyph_curve_fetch(curve_texture, curve_texel) - vec4(em, em);
        vec2 p3 = glyph_curve_fetch(curve_texture, ivec2(curve_texel.x + 1, curve_texel.y)).xy - em;
        // Lists sort by descending maximum x, so no later curve reaches this pixel.
        if (max(max(p12.x, p12.z), p3.x) * pixels_per_em.x < -0.5) break;

        uint code = glyph_root_code(p12.y, p12.w, p3.y);
        if (code != 0u) {
            vec2 roots = glyph_solve_horizontal(p12, p3) * pixels_per_em.x;
            if ((code & 1u) != 0u) {
                x_coverage += clamp(roots.x + 0.5, 0.0, 1.0);
                x_weight = max(x_weight, clamp(1.0 - abs(roots.x) * 2.0, 0.0, 1.0));
            }
            if (code > 1u) {
                x_coverage -= clamp(roots.y + 0.5, 0.0, 1.0);
                x_weight = max(x_weight, clamp(1.0 - abs(roots.y) * 2.0, 0.0, 1.0));
            }
        }
    }

    float y_coverage = 0.0;
    float y_weight = 0.0;
    ivec2 vertical_header = ivec2(glyph_texel.x + glyph.w + 1 + band_index.x, glyph_texel.y);
    uvec2 vertical_band = glyph_band_fetch(band_texture, vertical_header);
    ivec2 vertical_list = glyph_band_texel(glyph_texel, vertical_band.y);
    for (uint entry = 0u; entry < vertical_band.x; entry++) {
        ivec2 list_texel = ivec2(vertical_list.x + int(entry), vertical_list.y);
        ivec2 curve_texel = ivec2(glyph_band_fetch(band_texture, list_texel));
        vec4 p12 = glyph_curve_fetch(curve_texture, curve_texel) - vec4(em, em);
        vec2 p3 = glyph_curve_fetch(curve_texture, ivec2(curve_texel.x + 1, curve_texel.y)).xy - em;
        if (max(max(p12.y, p12.w), p3.y) * pixels_per_em.y < -0.5) break;

        uint code = glyph_root_code(p12.x, p12.z, p3.x);
        if (code != 0u) {
            vec2 roots = glyph_solve_vertical(p12, p3) * pixels_per_em.y;
            if ((code & 1u) != 0u) {
                y_coverage -= clamp(roots.x + 0.5, 0.0, 1.0);
                y_weight = max(y_weight, clamp(1.0 - abs(roots.x) * 2.0, 0.0, 1.0));
            }
            if (code > 1u) {
                y_coverage += clamp(roots.y + 0.5, 0.0, 1.0);
                y_weight = max(y_weight, clamp(1.0 - abs(roots.y) * 2.0, 0.0, 1.0));
            }
        }
    }

    // Nonzero fill; absolute values accept either winding direction.
    float weighted = abs(x_coverage * x_weight + y_coverage * y_weight) / max(x_weight + y_weight, 1.0 / 65536.0);
    float coverage = max(weighted, min(abs(x_coverage), abs(y_coverage)));
    return clamp(coverage, 0.0, 1.0);
}

#endif
