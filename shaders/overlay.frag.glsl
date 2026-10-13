#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
#include "grade.glsl"
#include "overlay_glyph.glsl"
#if defined(BACKDROP) || defined(WORLD)
#include "texture_fetch.glsl"
#endif

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer OverlayItems {
    OverlayItemGpu values[];
};

#ifdef TRANSFORMED
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer OverlayTransforms {
    OverlayTransformGpu values[];
};
#endif

#ifdef WORLD
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer OverlayPlanes {
    OverlayPlaneGpu values[];
};
#endif

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(location = 0) flat in uint v_item;
#ifdef WORLD
layout(location = 1) in vec2 v_plane;
#endif
layout(location = 0) out vec4 out_color;

#ifdef WORLD
// Reverse-Z depth that a plane item gains, so one lying on a surface of the view draws over it.
const float PLANE_DEPTH_SCALE = 1.0 + 1.0 / 65536.0;
#endif

#ifdef TRANSFORMED
vec2 overlay_local_position(OverlayTransformGpu transform, vec2 pixel) {
    return transform.inverse_x_axis * pixel.x + transform.inverse_y_axis * pixel.y + transform.inverse_offset;
}

// Local units one output pixel spans along each local axis.
vec2 overlay_local_pixel_size(OverlayTransformGpu transform) {
    return vec2(
        length(vec2(transform.inverse_x_axis.x, transform.inverse_y_axis.x)),
        length(vec2(transform.inverse_x_axis.y, transform.inverse_y_axis.y)));
}

// A clip box is tested in its own local space, with its edges one output pixel wide.
float overlay_clip_coverage(OverlayTransformGpu clip, vec2 pixel) {
    vec2 center = (clip.clip_box.xy + clip.clip_box.zw) * 0.5;
    vec2 half_extent = (clip.clip_box.zw - clip.clip_box.xy) * 0.5;
    vec2 inside = half_extent - abs(overlay_local_position(clip, pixel) - center);
    vec2 coverage = clamp(0.5 + inside / overlay_local_pixel_size(clip), 0.0, 1.0);
    return coverage.x * coverage.y;
}

#ifdef WORLD
// The same test for a plane item, whose position in the plane varies across the screen with perspective.
float overlay_plane_clip_coverage(OverlayTransformGpu clip, vec2 plane_position) {
    vec2 center = (clip.clip_box.xy + clip.clip_box.zw) * 0.5;
    vec2 half_extent = (clip.clip_box.zw - clip.clip_box.xy) * 0.5;
    vec2 local = overlay_local_position(clip, plane_position);
    vec2 pixel_size = vec2(
        length(vec2(dFdx(local.x), dFdy(local.x))),
        length(vec2(dFdx(local.y), dFdy(local.y))));
    vec2 coverage = clamp(0.5 + (half_extent - abs(local - center)) / pixel_size, 0.0, 1.0);
    return coverage.x * coverage.y;
}

// Output pixels per local unit along each local axis, from the local change per output pixel along x and y.
vec2 overlay_pixels_per_unit_from_change(vec2 local_dx, vec2 local_dy) {
    float determinant = max(abs(local_dx.x * local_dy.y - local_dy.x * local_dx.y), 1e-12);
    return vec2(length(vec2(local_dy.y, -local_dx.y)), length(vec2(-local_dy.x, local_dx.x))) / determinant;
}
#endif

// Local units per output pixel across an edge, so a transformed shape keeps edges about one pixel wide.
float overlay_edge_width(float signed_distance, bool transformed) {
    return transformed ? max(length(vec2(dFdx(signed_distance), dFdy(signed_distance))), 1e-6) : 1.0;
}

// The same width for a shape's distance field, from the field's direction instead of its pixel differences, which
// fold across a stroke thinner than two pixels. away is the offset from the nearest outline point. It is zero on
// the outline and on a line's axis, where the direction is across line, the shape's first two points apart.
float overlay_shape_edge_width(vec2 away, vec2 line, vec2 local_dx, vec2 local_dy) {
    vec2 direction = vec2(1.0, 0.0);
    if (dot(away, away) > 0.0) {
        direction = normalize(away);
    } else if (dot(line, line) > 0.0) {
        direction = normalize(vec2(-line.y, line.x));
    }
    return length(vec2(dot(direction, local_dx), dot(direction, local_dy)));
}
#endif

// Radii are top left, top right, bottom right, bottom left; y grows downward.
float rounded_box_distance(vec2 local, vec2 half_extent, vec4 radii) {
    float radius = local.x < 0.0
        ? (local.y < 0.0 ? radii.x : radii.w)
        : (local.y < 0.0 ? radii.y : radii.z);
    radius = min(radius, min(half_extent.x, half_extent.y));
    vec2 corner = abs(local) - half_extent + radius;
    return min(max(corner.x, corner.y), 0.0) + length(max(corner, 0.0)) - radius;
}

// Signed distance to a triangle of either winding, negative inside; a triangle with no area is empty.
// away is the offset from the nearest point of the outline to the point.
float triangle_distance(vec2 point, vec2 first, vec2 second, vec2 third, out vec2 away) {
    vec2 edge_a = second - first;
    vec2 edge_b = third - second;
    vec2 edge_c = first - third;
    vec2 from_first = point - first;
    vec2 from_second = point - second;
    vec2 from_third = point - third;
    vec2 near_a = from_first - edge_a * clamp(dot(from_first, edge_a) / max(dot(edge_a, edge_a), 1e-12), 0.0, 1.0);
    vec2 near_b = from_second - edge_b * clamp(dot(from_second, edge_b) / max(dot(edge_b, edge_b), 1e-12), 0.0, 1.0);
    vec2 near_c = from_third - edge_c * clamp(dot(from_third, edge_c) / max(dot(edge_c, edge_c), 1e-12), 0.0, 1.0);

    float winding = sign(edge_a.x * edge_c.y - edge_a.y * edge_c.x);
    if (winding == 0.0) {
        away = vec2(1.0, 0.0);
        return 1e30;
    }

    away = near_a;
    float nearest = dot(near_a, near_a);
    float squared_b = dot(near_b, near_b);
    float squared_c = dot(near_c, near_c);
    if (squared_b < nearest) {
        away = near_b;
        nearest = squared_b;
    }
    if (squared_c < nearest) {
        away = near_c;
        nearest = squared_c;
    }

    // The smallest side-of-edge value is positive only inside all three edges.
    float inside = min(
        min(winding * (from_first.x * edge_a.y - from_first.y * edge_a.x),
            winding * (from_second.x * edge_b.y - from_second.y * edge_b.x)),
        winding * (from_third.x * edge_c.y - from_third.y * edge_c.x));
    return inside > 0.0 ? -sqrt(nearest) : sqrt(nearest);
}

// Distance to the line between two points, which may coincide; away is the offset from its nearest point.
float segment_distance(vec2 point, vec2 from, vec2 to, out vec2 away) {
    vec2 axis = to - from;
    vec2 from_start = point - from;
    away = from_start - axis * clamp(dot(from_start, axis) / max(dot(axis, axis), 1e-12), 0.0, 1.0);
    return length(away);
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

// Ramps in linear light between colors premultiplied by alpha, so a fade to a transparent color keeps its hue. The
// points are the item's half2 offsets from its top left, and position is in the item's local pixels.
vec4 overlay_gradient_color(OverlayItemGpu item, vec2 position, vec4 start, bool radial) {
    vec2 from = item.bounds.xy + unpackHalf2x16(item.glyph_band_max);
    vec2 to = item.bounds.xy + unpackHalf2x16(item.band_texture);
    vec2 span = to - from;
    float ramp = radial
        ? length(position - from) / max(length(span), 1e-6)
        : dot(position - from, span) / max(dot(span, span), 1e-12);

    vec4 end = unpackUnorm4x8(item.glyph_location);
    vec4 premultiplied = mix(
        vec4(start.rgb * start.a, start.a),
        vec4(srgb_to_linear(end.rgb) * end.a, end.a),
        clamp(ramp, 0.0, 1.0));

    return vec4(premultiplied.rgb / max(premultiplied.a, 1e-6), premultiplied.a);
}

#ifdef TRANSFORMED
vec4 overlay_glyph_color(OverlayItemGpu item, vec2 position, vec2 pixels_per_unit) {
#else
vec4 overlay_glyph_color(OverlayItemGpu item, vec2 position) {
#endif
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
#ifdef TRANSFORMED
        pixels_per_unit / abs(em_per_pixel),
#else
        1.0 / abs(em_per_pixel),
#endif
        vec4(band_scale, -em_low * band_scale),
        glyph);
    vec4 fill = unpackUnorm4x8(item.fill);
    return vec4(srgb_to_linear(fill.rgb), fill.a * coverage);
}

#ifdef WORLD
void overlay_shade() {
#else
void main() {
#endif
#if defined(BACKDROP)
    OverlayBackdropRoot root = OverlayBackdropRoot(pc.fragment_root_gpu);
#elif defined(WORLD)
    OverlayWorldRoot root = OverlayWorldRoot(pc.fragment_root_gpu);
#else
    OverlayRoot root = OverlayRoot(pc.fragment_root_gpu);
#endif
    OverlayItemGpu item = OverlayItems(root.items).values[v_item];
    uint kind = (item.sampler_kind_flags >> OVERLAY_KIND_SHIFT) & OVERLAY_KIND_MASK;

#ifdef TRANSFORMED
    OverlayTransforms transforms = OverlayTransforms(root.transforms);
    uint transform_index = item.transform_clip & OVERLAY_TRANSFORM_MASK;
    uint clip_index = item.transform_clip >> OVERLAY_CLIP_SHIFT;

#ifdef WORLD
    bool plane = transforms.values[transform_index].plane != 0u;
#endif
    float clip_coverage = 1.0;
    while (clip_index != 0u) {
        OverlayTransformGpu clip = transforms.values[clip_index];
#ifdef WORLD
        clip_coverage *= plane
            ? overlay_plane_clip_coverage(clip, v_plane)
            : overlay_clip_coverage(clip, gl_FragCoord.xy);
#else
        clip_coverage *= overlay_clip_coverage(clip, gl_FragCoord.xy);
#endif
        clip_index = clip.clip_parent;
    }

#ifdef WORLD
    // Reverse-Z, so larger is closer. Hidden items fade to nothing instead of discarding, which keeps the derivatives
    // below defined; the view's depth is jittered under temporal anti-aliasing. A plane has the depth of its own
    // fragment, an anchored billboard that of its anchor.
    ivec2 depth_extent = texture_extent(root.depth_texture);
    vec2 depth_texel = (gl_FragCoord.xy - vec2(root.view_x, root.view_y)) * vec2(depth_extent)
        / vec2(root.view_width, root.view_height);
    float view_depth = fetch_texture_2d(root.depth_texture, clamp(ivec2(depth_texel), ivec2(0), depth_extent - 1)).r;
    float item_depth = plane ? gl_FragCoord.z * PLANE_DEPTH_SCALE : transforms.values[transform_index].depth;
    clip_coverage *= item_depth >= view_depth ? 1.0 : 0.0;
    if (plane) {
        // The view's clip plane, as the distance of the fragment's point on the plane.
        vec4 clip_plane = OverlayPlanes(root.planes).values[transform_index].distance;
        clip_coverage *= dot(clip_plane.xyz, vec3(v_plane, 1.0)) >= 0.0 ? 1.0 : 0.0;
    }
#endif

    // Item-local position, the local change per output pixel along x and y, and output pixels per local unit.
    bool transformed = transform_index != 0u;
    vec2 position = gl_FragCoord.xy;
    vec2 local_dx = vec2(1.0, 0.0);
    vec2 local_dy = vec2(0.0, 1.0);
    vec2 pixels_per_unit = vec2(1.0);
    if (transformed) {
        OverlayTransformGpu transform = transforms.values[transform_index];
        position = overlay_local_position(transform, gl_FragCoord.xy);
        local_dx = transform.inverse_x_axis;
        local_dy = transform.inverse_y_axis;
        pixels_per_unit = vec2(length(transform.x_axis), length(transform.y_axis));
#ifdef WORLD
        if (plane) {
            position = overlay_local_position(transform, v_plane);
            local_dx = dFdx(position);
            local_dy = dFdy(position);
            pixels_per_unit = overlay_pixels_per_unit_from_change(local_dx, local_dy);
        }
#endif
    }
#endif

    if (kind == OVERLAY_KIND_GLYPH) {
#ifdef TRANSFORMED
        vec4 glyph = overlay_glyph_color(item, position, pixels_per_unit);
        out_color = vec4(glyph.rgb, glyph.a * clip_coverage);
#else
        out_color = overlay_glyph_color(item, gl_FragCoord.xy);
#endif
        return;
    }

    uint flags = item.sampler_kind_flags >> OVERLAY_FLAGS_SHIFT;
#ifndef TRANSFORMED
    vec2 position = gl_FragCoord.xy;
#endif

    if (kind == OVERLAY_KIND_TRIANGLE || kind == OVERLAY_KIND_SEGMENT) {
        float shape_distance;
        vec2 away;
        if (kind == OVERLAY_KIND_TRIANGLE) {
            vec2 third = vec2(uintBitsToFloat(item.radii_top), uintBitsToFloat(item.radii_bottom));
            shape_distance = triangle_distance(position, item.uv_rect.xy, item.uv_rect.zw, third, away);
        } else {
            shape_distance = segment_distance(position, item.uv_rect.xy, item.uv_rect.zw, away)
                - uintBitsToFloat(item.radii_top);
        }

        vec4 shape_color = unpackUnorm4x8(item.fill);
#ifdef TRANSFORMED
        float edge_width = transformed
            ? overlay_shape_edge_width(away, item.uv_rect.zw - item.uv_rect.xy, local_dx, local_dy)
            : 1.0;
        float shape_coverage = clamp(0.5 - shape_distance / edge_width, 0.0, 1.0);
        out_color = vec4(srgb_to_linear(shape_color.rgb), shape_color.a * shape_coverage * clip_coverage);
#else
        out_color = vec4(srgb_to_linear(shape_color.rgb), shape_color.a * clamp(0.5 - shape_distance, 0.0, 1.0));
#endif
        return;
    }

    vec2 center = (item.bounds.xy + item.bounds.zw) * 0.5;
    vec2 half_extent = (item.bounds.zw - item.bounds.xy) * 0.5;
    vec4 radii = vec4(unpackHalf2x16(item.radii_top), unpackHalf2x16(item.radii_bottom));
#ifdef TRANSFORMED
    float outer = rounded_box_distance(position - center, half_extent, radii);
    float coverage = clamp(0.5 - outer / overlay_edge_width(outer, transformed), 0.0, 1.0);
#else
    float coverage = clamp(0.5 - rounded_box_distance(position - center, half_extent, radii), 0.0, 1.0);
#endif

    vec4 fill = unpackUnorm4x8(item.fill);
    vec4 color = vec4(srgb_to_linear(fill.rgb), fill.a);
    if ((flags & OVERLAY_FLAG_GRADIENT) != 0u) {
        color = overlay_gradient_color(item, position, color, (flags & OVERLAY_FLAG_GRADIENT_RADIAL) != 0u);
    }

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
#ifdef TRANSFORMED
        vec2 uv_dx = vec2(u.y * local_dx.x, v.y * local_dx.y);
        vec2 uv_dy = vec2(u.y * local_dy.x, v.y * local_dy.y);
        color *= sample_texture_2d_grad(item.texture, sampler_index, vec2(u.x, v.x), uv_dx, uv_dy);
#else
        color *= sample_texture_2d_grad(item.texture, sampler_index, vec2(u.x, v.x), vec2(u.y, 0.0), vec2(0.0, v.y));
#endif
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
#ifdef TRANSFORMED
        float in_border = any(lessThanEqual(inner_high, inner_low))
            ? 1.0
            : clamp(0.5 + inner / overlay_edge_width(inner, transformed), 0.0, 1.0);
#else
        float in_border = any(lessThanEqual(inner_high, inner_low)) ? 1.0 : clamp(0.5 + inner, 0.0, 1.0);
#endif
        vec4 border = unpackUnorm4x8(item.border_color);
        color = mix(color, vec4(srgb_to_linear(border.rgb), border.a), in_border);
    }

#ifdef BACKDROP
    // The blurred image replaces what is under the shape; the item's own color goes over it.
    ivec2 behind_extent = ivec2(root.backdrop_width, root.backdrop_height);
    ivec2 behind_texel = ivec2(gl_FragCoord.xy) - ivec2(root.backdrop_x, root.backdrop_y);
    vec4 behind = fetch_texture_2d(root.backdrop_texture, clamp(behind_texel, ivec2(0), behind_extent - 1));
    color = vec4(mix(behind.rgb, color.rgb, color.a), color.a + behind.a * (1.0 - color.a));
#endif

#ifdef TRANSFORMED
    out_color = vec4(color.rgb, color.a * coverage * clip_coverage);
#else
    out_color = vec4(color.rgb, color.a * coverage);
#endif
}

#ifdef WORLD
void main() {
    overlay_shade();
    out_color.rgb *= OverlayWorldRoot(pc.fragment_root_gpu).color_scale;
}
#endif
