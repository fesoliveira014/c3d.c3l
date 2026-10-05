#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "grade.glsl"
#include "overlay_glyph.glsl"

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer OverlayItems {
    OverlayItemGpu values[];
};

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(location = 0) flat in uint v_item;
layout(location = 0) out vec4 out_color;

// Radii are top left, top right, bottom right, bottom left; y grows downward.
float rounded_box_distance(vec2 local, vec2 half_extent, vec4 radii) {
    float radius = local.x < 0.0
        ? (local.y < 0.0 ? radii.x : radii.w)
        : (local.y < 0.0 ? radii.y : radii.z);
    radius = min(radius, min(half_extent.x, half_extent.y));
    vec2 corner = abs(local) - half_extent + radius;
    return min(max(corner.x, corner.y), 0.0) + length(max(corner, 0.0)) - radius;
}

// Texture coordinate and its change per pixel along one axis; zero margins map the span linearly.
vec2 slice_axis(
    float position,
    vec2 span,
    vec2 uv_span,
    vec2 margins,
    vec2 uv_margins
) {
    float clamped = clamp(position, span.x, span.y);
    float inner_low = span.x + margins.x;
    float inner_high = span.y - margins.y;

    if (clamped < inner_low) {
        float rate = uv_margins.x / margins.x;
        return vec2(uv_span.x + (clamped - span.x) * rate, rate);
    }
    if (clamped > inner_high) {
        float rate = uv_margins.y / margins.y;
        return vec2(uv_span.y - (span.y - clamped) * rate, rate);
    }

    float uv_inner_low = uv_span.x + uv_margins.x;
    float uv_inner_high = uv_span.y - uv_margins.y;
    float rate = (uv_inner_high - uv_inner_low) / max(inner_high - inner_low, 1e-6);
    return vec2(uv_inner_low + (clamped - inner_low) * rate, rate);
}

// Piecewise slice coordinates jump at slice edges, so implicit derivatives would pick a too-small mip there.
vec4 sample_texture_2d_grad(
    uint texture_index,
    uint sampler_index,
    vec2 uv,
    vec2 uv_dx,
    vec2 uv_dy
) {
    return textureGrad(
        sampler2D(
            gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(texture_index))],
            gpu_sampler_heap[nonuniformEXT(GPU_HEAP_SLOT(sampler_index))]),
        uv,
        uv_dx,
        uv_dy);
}

vec4 overlay_glyph_color(OverlayItemGpu item, vec2 position) {
    vec2 em_per_pixel = (item.uv_rect.zw - item.uv_rect.xy) / (item.bounds.zw - item.bounds.xy);
    vec2 em = item.uv_rect.xy + (position - item.bounds.xy) * em_per_pixel;
    vec2 em_low = min(item.uv_rect.xy, item.uv_rect.zw);
    vec2 em_high = max(item.uv_rect.xy, item.uv_rect.zw);
    uvec2 band_max = uvec2(item.glyph_band_max & 0xFFFFu, item.glyph_band_max >> 16u);
    vec2 band_scale = vec2(band_max + 1u) / max(em_high - em_low, vec2(1.0 / 65536.0));
    ivec4 glyph = ivec4(int(item.glyph_location & 0xFFFFu), int(item.glyph_location >> 16u), ivec2(band_max));
    float coverage = glyph_coverage(
        item.texture,
        item.band_texture,
        em,
        1.0 / abs(em_per_pixel),
        vec4(band_scale, -em_low * band_scale),
        glyph);
    vec4 fill = unpackUnorm4x8(item.fill);
    return vec4(srgb_to_linear(fill.rgb), fill.a * coverage);
}

void main() {
    OverlayRoot root = OverlayRoot(pc.fragment_root_gpu);
    OverlayItemGpu item = OverlayItems(root.items).values[v_item];
    uint kind = (item.sampler_kind_flags >> OVERLAY_KIND_SHIFT) & OVERLAY_KIND_MASK;
    if (kind == OVERLAY_KIND_GLYPH) {
        out_color = overlay_glyph_color(item, gl_FragCoord.xy);
        return;
    }

    uint flags = item.sampler_kind_flags >> OVERLAY_FLAGS_SHIFT;
    vec2 position = gl_FragCoord.xy;

    vec2 center = (item.bounds.xy + item.bounds.zw) * 0.5;
    vec2 half_extent = (item.bounds.zw - item.bounds.xy) * 0.5;
    vec4 radii = vec4(unpackHalf2x16(item.radii_top), unpackHalf2x16(item.radii_bottom));
    float coverage = clamp(0.5 - rounded_box_distance(position - center, half_extent, radii), 0.0, 1.0);

    vec4 fill = unpackUnorm4x8(item.fill);
    vec4 color = vec4(srgb_to_linear(fill.rgb), fill.a);

    if ((flags & OVERLAY_FLAG_TEXTURED) != 0u) {
        vec4 slice_pixels = vec4(0.0);
        vec4 slice_uv = vec4(0.0);
        if ((flags & OVERLAY_FLAG_NINE_SLICE) != 0u) {
            slice_pixels = vec4(
                unpackHalf2x16(item.slice_pixels_left_top),
                unpackHalf2x16(item.slice_pixels_right_bottom));
            slice_uv = vec4(unpackUnorm2x16(item.slice_uv_left_top), unpackUnorm2x16(item.slice_uv_right_bottom));
        }

        vec2 uv_size = item.uv_rect.zw - item.uv_rect.xy;
        vec2 u = slice_axis(position.x, item.bounds.xz, item.uv_rect.xz, slice_pixels.xz, slice_uv.xz * uv_size.x);
        vec2 v = slice_axis(position.y, item.bounds.yw, item.uv_rect.yw, slice_pixels.yw, slice_uv.yw * uv_size.y);
        uint sampler_index = item.sampler_kind_flags & OVERLAY_SAMPLER_MASK;
        color *= sample_texture_2d_grad(item.texture, sampler_index, vec2(u.x, v.x), vec2(u.y, 0.0), vec2(0.0, v.y));
    }

    if ((flags & OVERLAY_FLAG_BORDER) != 0u) {
        vec4 borders = vec4(unpackHalf2x16(item.borders_left_top), unpackHalf2x16(item.borders_right_bottom));
        vec2 inner_low = item.bounds.xy + borders.xy;
        vec2 inner_high = item.bounds.zw - borders.zw;
        vec4 inner_radii = max(radii - vec4(
            max(borders.x, borders.y),
            max(borders.z, borders.y),
            max(borders.z, borders.w),
            max(borders.x, borders.w)), vec4(0.0));
        float inner = rounded_box_distance(
            position - (inner_low + inner_high) * 0.5,
            (inner_high - inner_low) * 0.5,
            inner_radii);
        // Borders that meet across the box leave no inner area at all.
        float in_border = any(lessThanEqual(inner_high, inner_low)) ? 1.0 : clamp(0.5 + inner, 0.0, 1.0);
        vec4 border = unpackUnorm4x8(item.border_color);
        color = mix(color, vec4(srgb_to_linear(border.rgb), border.a), in_border);
    }

    out_color = vec4(color.rgb, color.a * coverage);
}
