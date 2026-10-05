module c3d::asset;

import c3d;
import c3d::asset::truetype @public;
import std::collections::list;
import std::math;

const float FONT_CURVE_TOLERANCE @private = 1.0f / 2048; // at or below f16 rounding of em coordinates
const float FONT_BAND_OVERLAP @private = 1.0f / 1024;    // the Slug reference's band epsilon
const uint FONT_MAX_BANDS @private = 16;                 // per axis; band max fits a byte in the reference

const float CUBIC_ERROR_FACTOR @local = 0.0481125224f; // sqrt(3) / 36: midpoint quadratic error per third difference
const uint SFNT_TRUETYPE @local = 0x0001_0000;
const uint SFNT_APPLE_TRUETYPE @local = 0x7472_7565; // "true"
const uint SFNT_OPENTYPE_CFF @local = 0x4F54_544F;   // "OTTO"
const uint SFNT_COLLECTION @local = 0x7474_6366;     // "ttcf"
const usz SFNT_HEADER_BYTES @local = 12;
const usz SFNT_RECORD_BYTES @local = 16;

const SfntTable[5] SFNT_REQUIRED_TABLES @local = {
    { .tag = "cmap", .min_bytes = 4 },
    { .tag = "head", .min_bytes = 54 },
    { .tag = "hhea", .min_bytes = 36 },
    { .tag = "hmtx", .min_bytes = 4 },
    { .tag = "maxp", .min_bytes = 6 },
};

struct SfntTable @private {
    String tag;
    usz    min_bytes; // the fields stb_truetype reads
}

struct GlyphCurve @private {
    Vec2 start;
    Vec2 control;
    Vec2 end;
}

struct BandChoice @private {
    uint count;
    uint largest; // curves in the fullest band
}

struct BandList @private {
    uint first;  // index of the band's first entry in the scratch list
    uint count;
    uint offset; // texels from the band block's start
}

fn uint read_u32(char[] bytes, usz offset) @local {
    return ((uint)bytes[offset] << 24) | ((uint)bytes[offset + 1] << 16) | ((uint)bytes[offset + 2] << 8)
        | (uint)bytes[offset + 3];
}

fn uint read_u16(char[] bytes, usz offset) @local {
    return ((uint)bytes[offset] << 8) | (uint)bytes[offset + 1];
}

fn bool sfnt_version(uint version) @local {
    return version == SFNT_TRUETYPE || version == SFNT_APPLE_TRUETYPE || version == SFNT_OPENTYPE_CFF;
}

fn uint? check_sfnt(char[] file, uint face_index) @private {
    if (file.len < SFNT_HEADER_BYTES || file.len > int::max) return c3d::ASSET_FORMAT_ERROR~;

    usz face_offset;
    uint tag = read_u32(file, 0);
    if (tag == SFNT_COLLECTION) {
        usz face_count = read_u32(file, 8);
        if (SFNT_HEADER_BYTES + face_count * 4 > file.len) return c3d::ASSET_FORMAT_ERROR~;
        if (face_index >= face_count) return c3d::INVALID_ARGUMENT~;
        face_offset = read_u32(file, SFNT_HEADER_BYTES + (usz)face_index * 4);
        if (face_offset > file.len - SFNT_HEADER_BYTES) return c3d::ASSET_FORMAT_ERROR~;
        if (!sfnt_version(read_u32(file, face_offset))) return c3d::ASSET_FORMAT_ERROR~;
    } else {
        if (!sfnt_version(tag)) return c3d::ASSET_FORMAT_ERROR~;
        if (face_index > 0) return c3d::INVALID_ARGUMENT~;
    }

    usz table_count = read_u16(file, face_offset + 4);
    usz records = face_offset + SFNT_HEADER_BYTES;
    if (records + table_count * SFNT_RECORD_BYTES > file.len) return c3d::ASSET_FORMAT_ERROR~;

    uint required_found;
    bool glyf;
    bool loca;
    bool cff;
    for (usz table = 0; table < table_count; table++) {
        usz record = records + table * SFNT_RECORD_BYTES;
        String table_tag = (String)file[record:4];
        usz offset = read_u32(file, record + 8);
        usz length = read_u32(file, record + 12);
        if (offset > file.len || length > file.len - offset) return c3d::ASSET_FORMAT_ERROR~;

        foreach (index, required : SFNT_REQUIRED_TABLES) {
            if (table_tag != required.tag) continue;
            if (length < required.min_bytes) return c3d::ASSET_FORMAT_ERROR~;
            required_found |= 1u << (uint)index;
        }
        if (table_tag == "glyf") glyf = true;
        if (table_tag == "loca") loca = true;
        if (table_tag == "CFF ") cff = true;
    }

    if (required_found != (1u << SFNT_REQUIRED_TABLES.len) - 1) return c3d::ASSET_FORMAT_ERROR~;
    if (!(glyf && loca) && !cff) return c3d::UNSUPPORTED~;
    return (uint)face_offset;
}

fn void split_cubic(
    Vec2 start,
    Vec2 control1,
    Vec2 control2,
    Vec2 end,
    List{GlyphCurve}* curves,
) @private {
    Vec2 third_difference = end - control2 * 3 + control1 * 3 - start;
    if (CUBIC_ERROR_FACTOR * third_difference.length() <= FONT_CURVE_TOLERANCE) {
        curves.push({
            .start   = start,
            .control = ((control1 + control2) * 3 - start - end) * 0.25f,
            .end     = end,
        });
        return;
    }

    Vec2 left = (start + control1) * 0.5f;
    Vec2 middle = (control1 + control2) * 0.5f;
    Vec2 right = (control2 + end) * 0.5f;
    Vec2 left_middle = (left + middle) * 0.5f;
    Vec2 right_middle = (middle + right) * 0.5f;
    Vec2 split = (left_middle + right_middle) * 0.5f;
    split_cubic(
        start:    start,
        control1: left,
        control2: left_middle,
        end:      split,
        curves:   curves,
    );
    split_cubic(
        start:    split,
        control1: right_middle,
        control2: right,
        end:      end,
        curves:   curves,
    );
}

fn bool curve_flat(GlyphCurve* curve, int axis) @private {
    return curve.start[axis] == curve.control[axis] && curve.control[axis] == curve.end[axis];
}

fn Vec2 curve_extent(GlyphCurve* curve, int axis) @private {
    return {
        math::min(curve.start[axis], math::min(curve.control[axis], curve.end[axis])),
        math::max(curve.start[axis], math::max(curve.control[axis], curve.end[axis])),
    };
}

fn Vec2 band_span(Vec2 range, uint count, uint band) @private {
    float thickness = (math::max(range.y, range.x) - range.x) / (float)count;
    return {
        range.x + (float)band * thickness - FONT_BAND_OVERLAP,
        range.x + (float)(band + 1) * thickness + FONT_BAND_OVERLAP,
    };
}

fn bool curve_in_band(GlyphCurve* curve, int axis, Vec2 span) @private {
    if (curve_flat(curve, axis)) return false;
    Vec2 extent = curve_extent(curve, axis);
    return extent.x <= span.y && extent.y >= span.x;
}

fn BandChoice choose_bands(GlyphCurve[] curves, int axis, Vec2 range) @private {
    BandChoice best = { .largest = uint::max };
    uint max_count = range.y > range.x ? FONT_MAX_BANDS : 1;
    for (uint count = 1; count <= max_count; count++) {
        uint largest;
        for (uint band = 0; band < count; band++) {
            Vec2 span = band_span(range, count, band);
            uint size;
            foreach (&curve : curves) {
                if (curve_in_band(curve, axis, span)) size++;
            }
            largest = math::max(largest, size);
        }
        if (largest < best.largest) best = { .count = count, .largest = largest };
    }
    return best;
}

fn uint font_texel_index(uint location) @private {
    return (location >> 16) * FONT_TEXTURE_WIDTH + (location & 0xFFFF);
}

fn GlyphCurve font_curve(FontAsset* font, uint location) @private {
    uint texel = font_texel_index(location);
    return {
        .start   = font.curves[texel].xy,
        .control = font.curves[texel].zw,
        .end     = font.curves[texel + 1].xy,
    };
}

fn void? build_glyph(FontAsset* font, uint glyph) @private {
    Vertex* vertices;
    int vertex_count = truetype::get_glyph_shape(&font.face, (int)glyph, &vertices);
    defer truetype::free_shape(&font.face, vertices);

    @pool() {
        List{GlyphCurve} curve_list;
        curve_list.tinit();
        List{uint} contour_ends;
        contour_ends.tinit();
        read_glyph_shape(font, vertices[:vertex_count], &curve_list, &contour_ends);
        GlyphCurve[] curves = curve_list.array_view();
        Vec4 bounds = curve_bounds(curves);

        BandChoice horizontal = choose_bands(curves, 1, bounds.yw);
        BandChoice vertical = choose_bands(curves, 0, bounds.xz);
        BandList[] horizontal_lists = alloc::new_array(tmem, BandList, (sz)horizontal.count);
        BandList[] vertical_lists = alloc::new_array(tmem, BandList, (sz)vertical.count);
        List{uint} entries;
        entries.tinit();
        collect_bands(
            curves:  curves,
            axis:    1,
            range:   bounds.yw,
            bands:   horizontal_lists,
            entries: &entries,
        );
        collect_bands(
            curves:  curves,
            axis:    0,
            range:   bounds.xz,
            bands:   vertical_lists,
            entries: &entries,
        );
        uint lists_start = horizontal.count + vertical.count;
        uint horizontal_end = assign_offsets(horizontal_lists, entries.array_view(), lists_start);
        uint block_texels = assign_offsets(vertical_lists, entries.array_view(), horizontal_end);

        uint[] locations = alloc::new_array(tmem, uint, (sz)curves.len);
        uint curve_end = place_curves(font.curve_texels, contour_ends.array_view(), locations);
        uint block_start = font.band_texels;
        if (block_start % FONT_TEXTURE_WIDTH + block_texels > FONT_TEXTURE_WIDTH) {
            block_start = (block_start / FONT_TEXTURE_WIDTH + 1) * FONT_TEXTURE_WIDTH;
        }
        if (font.glyph_count == font.glyphs.len || curve_end > font.curves.len) return c3d::CAPACITY_EXCEEDED~;
        if (block_texels > FONT_TEXTURE_WIDTH || (usz)block_start + block_texels > font.bands.len) {
            return c3d::CAPACITY_EXCEEDED~;
        }

        foreach (index, &curve : curves) {
            uint texel = font_texel_index(locations[index]);
            font.curves[texel] = { curve.start.x, curve.start.y, curve.control.x, curve.control.y };
            font.curves[texel + 1] = { curve.end.x, curve.end.y, 0, 0 };
        }
        write_bands(
            font:         font,
            block_start:  block_start,
            first_header: 0,
            lists:        horizontal_lists,
            entries:      entries.array_view(),
            locations:    locations,
        );
        write_bands(
            font:         font,
            block_start:  block_start,
            first_header: horizontal.count,
            lists:        vertical_lists,
            entries:      entries.array_view(),
            locations:    locations,
        );

        font.glyphs[font.glyph_count] = {
            .bounds        = bounds,
            .band_location = texel_location(block_start),
            .band_max      = (vertical.count - 1) | ((horizontal.count - 1) << 16),
        };
        font.glyph_count++;
        font.glyph_slots[glyph] = font.glyph_count;
        font.curve_texels = curve_end;
        font.band_texels = block_start + block_texels;
    };
}

fn void read_glyph_shape(
    FontAsset* font,
    Vertex[] vertices,
    List{GlyphCurve}* curves,
    List{uint}* contour_ends,
) @local {
    Vec2 start;
    Vec2 pen;
    foreach (&vertex : vertices) {
        Vec2 point = (Vec2){ (float)vertex.x, (float)vertex.y } * font.em_scale;
        Vec2 control = (Vec2){ (float)vertex.control_x, (float)vertex.control_y } * font.em_scale;
        switch (vertex.type) {
            case truetype::VERTEX_MOVE:
                close_contour(curves, contour_ends, pen, start);
                start = point;
            case truetype::VERTEX_LINE:
                curves.push({ .start = pen, .control = point, .end = point });
            case truetype::VERTEX_CURVE:
                curves.push({ .start = pen, .control = control, .end = point });
            case truetype::VERTEX_CUBIC:
                split_cubic(
                    start:    pen,
                    control1: control,
                    control2: (Vec2){ (float)vertex.control1_x, (float)vertex.control1_y } * font.em_scale,
                    end:      point,
                    curves:   curves,
                );
        }
        pen = point;
    }
    close_contour(curves, contour_ends, pen, start);
}

// A contour that does not end at its start gets a closing line; an empty contour adds no end.
fn void close_contour(List{GlyphCurve}* curves, List{uint}* contour_ends, Vec2 pen, Vec2 start) @local {
    uint first = contour_ends.len() ? (*contour_ends)[contour_ends.len() - 1] : 0;
    if (curves.len() == first) return;

    if (pen != start) curves.push({ .start = pen, .control = start, .end = start });
    contour_ends.push((uint)curves.len());
}

fn Vec4 curve_bounds(GlyphCurve[] curves) @local {
    if (!curves.len) return {};

    Vec4 bounds = { curves[0].start.x, curves[0].start.y, curves[0].start.x, curves[0].start.y };
    foreach (&curve : curves) {
        Vec2[3] points = { curve.start, curve.control, curve.end };
        foreach (point : points) {
            bounds = { math::min(bounds.x, point.x), math::min(bounds.y, point.y), math::max(bounds.z, point.x),
              math::max(bounds.w, point.y) };
        }
    }
    return bounds;
}

// Each band list sorts by descending reach along the other axis, so the shader stops at the first curve past it.
fn void collect_bands(
    GlyphCurve[] curves,
    int axis,
    Vec2 range,
    BandList[] bands,
    List{uint}* entries,
) @local {
    int other_axis = 1 - axis;
    foreach (uint band, &list : bands) {
        Vec2 span = band_span(range, (uint)bands.len, band);
        list.first = (uint)entries.len();
        foreach (uint index, &curve : curves) {
            if (!curve_in_band(curve, axis, span)) continue;

            float reach = curve_extent(curve, other_axis).y;
            entries.push(index);
            sz position = entries.len() - 1;
            while (position > (sz)list.first && curve_extent(&curves[(*entries)[position - 1]], other_axis).y < reach) {
                (*entries)[position] = (*entries)[position - 1];
                position--;
            }
            (*entries)[position] = index;
        }
        list.count = (uint)entries.len() - list.first;
    }
}

// A band whose list equals the previous band's reuses its texels.
fn uint assign_offsets(BandList[] lists, uint[] entries, uint offset) @local {
    foreach (uint band, &list : lists) {
        if (band > 0 && same_list(entries, lists[band - 1], *list)) {
            list.offset = lists[band - 1].offset;
            continue;
        }
        list.offset = offset;
        offset += list.count;
    }
    return offset;
}

fn bool same_list(uint[] entries, BandList first, BandList second) @local {
    if (first.count != second.count) return false;
    for (uint entry = 0; entry < first.count; entry++) {
        if (entries[first.first + entry] != entries[second.first + entry]) return false;
    }
    return true;
}

// A curve reads its second texel at the next column without wrapping, so no curve starts in a row's last column.
fn uint place_curves(uint cursor, uint[] contour_ends, uint[] locations) @local {
    uint first;
    foreach (end : contour_ends) {
        for (uint index = first; index < end; index++) {
            if (cursor % FONT_TEXTURE_WIDTH == FONT_TEXTURE_WIDTH - 1) cursor++;
            locations[index] = texel_location(cursor);
            cursor++;
        }
        cursor++;
        first = end;
    }
    return cursor;
}

fn void write_bands(
    FontAsset* font,
    uint block_start,
    uint first_header,
    BandList[] lists,
    uint[] entries,
    uint[] locations,
) @local {
    foreach (uint band, list : lists) {
        font.bands[block_start + first_header + band] = list.count | (list.offset << 16);
        for (uint entry = 0; entry < list.count; entry++) {
            font.bands[block_start + list.offset + entry] = locations[entries[list.first + entry]];
        }
    }
}

fn uint texel_location(uint texel) @local {
    return (texel % FONT_TEXTURE_WIDTH) | ((texel / FONT_TEXTURE_WIDTH) << 16);
}
