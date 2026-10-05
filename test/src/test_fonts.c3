module c3d::test::fonts;

import c3d;
import c3d::asset @public;
import std::collections::list;
import std::math;

const uint GLYPH_NOTDEF @local = 0;
const uint GLYPH_SPACE @local = 1;
const uint GLYPH_A @local = 34;
const uint GLYPH_H @local = 41;
const uint GLYPH_O @local = 48;
const uint GLYPH_V @local = 55;
const uint GLYPH_ZHE @local = 101;
const uint GLYPH_ZHONG @local = 4;
const uint GLYPH_HIRAGANA_A @local = 2;
const uint WIDTH @local = asset::FONT_TEXTURE_WIDTH;

fn AssetStore create_store(uint max_fonts = 4) @local {
    AssetStoreDesc desc = asset::default_asset_store_desc();
    desc.max_fonts = max_fonts;
    return asset::create_asset_store(mem, desc);
}

fn FontDesc small_font_desc(uint max_glyphs = 128) @local {
    return { .max_glyphs = max_glyphs, .curve_texels = WIDTH, .band_texels = 4 * WIDTH };
}

fn bool near(float actual, float expected) @local {
    return math::abs(actual - expected) <= 1e-4f * math::max(1.0f, math::abs(expected));
}

fn char[] copy_bytes(char[] bytes) @local {
    char[] copy = alloc::new_array(tmem, char, (sz)bytes.len);
    copy[..] = bytes[..];
    return copy;
}

fn void rename_table(char[] file, String from, String to) @local {
    uint table_count = ((uint)file[4] << 8) | file[5];
    for (uint table = 0; table < table_count; table++) {
        char[] tag = file[12 + table * 16 : 4];
        if ((String)tag == from) {
            tag[..] = to[..];
            return;
        }
    }
    unreachable("table %s not found", from);
}

fn uint[] glyph_locations(FontAsset* font, uint glyph) @local {
    FontGlyph* record = &font.glyphs[font.glyph_slots[glyph] - 1];
    uint base = asset::font_texel_index(record.band_location);
    uint header_count = (record.band_max & 0xFFFF) + (record.band_max >> 16) + 2;
    List{uint} locations;
    locations.tinit();
    for (uint band = 0; band < header_count; band++) {
        uint header = font.bands[base + band];
        uint first = base + (header >> 16);
        foreach (location : font.bands[first : header & 0xFFFF]) {
            if (!locations.contains(location)) locations.push(location);
        }
    }
    return locations.array_view();
}

fn bool point_balanced(FontAsset* font, uint[] locations, Vec2 point) @local {
    int balance;
    foreach (location : locations) {
        GlyphCurve curve = asset::font_curve(font, location);
        if (curve.start == point) balance++;
        if (curve.end == point) balance--;
    }
    return balance == 0;
}

fn bool contours_close(FontAsset* font, uint[] locations) @local {
    foreach (location : locations) {
        GlyphCurve curve = asset::font_curve(font, location);
        if (!point_balanced(font, locations, curve.start) || !point_balanced(font, locations, curve.end)) return false;
    }
    return true;
}

fn float curve_reach(FontAsset* font, uint location, int axis) @local {
    GlyphCurve curve = asset::font_curve(font, location);
    return math::max(curve.start[axis], math::max(curve.control[axis], curve.end[axis]));
}

fn bool list_has(uint[] list, uint location) @local {
    foreach (entry : list) {
        if (entry == location) return true;
    }
    return false;
}

fn void check_bands(FontAsset* font, uint glyph) @local {
    FontGlyph* record = &font.glyphs[font.glyph_slots[glyph] - 1];
    uint[] locations = glyph_locations(font, glyph);
    uint base = asset::font_texel_index(record.band_location);
    uint horizontal_count = (record.band_max >> 16) + 1;
    uint vertical_count = (record.band_max & 0xFFFF) + 1;

    for (int axis = 0; axis < 2; axis++) {
        uint count = axis == 1 ? horizontal_count : vertical_count;
        uint header_base = axis == 1 ? base : base + horizontal_count;
        float low = record.bounds[axis];
        float high = record.bounds[axis + 2];
        float extent = math::max(high - low, 1.0f / 65536);

        for (uint sample = 0; sample < 64; sample++) {
            float coordinate = low + (high - low) * ((float)sample + 0.5f) / 64;
            uint band = (uint)math::clamp((int)((coordinate - low) * (float)count / extent), 0, (int)count - 1);
            uint header = font.bands[header_base + band];
            uint[] list = font.bands[base + (header >> 16) : header & 0xFFFF];

            foreach (location : locations) {
                GlyphCurve curve = asset::font_curve(font, location);
                float[3] along = { curve.start[axis], curve.control[axis], curve.end[axis] };
                if (along[0] == along[1] && along[1] == along[2]) continue;
                float lowest = math::min(along[0], math::min(along[1], along[2]));
                float highest = math::max(along[0], math::max(along[1], along[2]));
                if (lowest > coordinate || highest < coordinate) continue;
                assert(list_has(list, location), "glyph %d axis %d misses a crossing curve", glyph, axis);
            }
            for (usz entry = 1; entry < list.len; entry++) {
                assert(curve_reach(font, list[entry - 1], 1 - axis) >= curve_reach(font, list[entry], 1 - axis));
            }
        }
    }
}

fn Vec2 cubic_point(Vec2[4] cubic, float t) @local {
    float u = 1 - t;
    return cubic[0] * (u * u * u) + cubic[1] * (3 * u * u * t) + cubic[2] * (3 * u * t * t) + cubic[3] * (t * t * t);
}

fn Vec2 quadratic_point(GlyphCurve curve, float t) @local {
    float u = 1 - t;
    return curve.start * (u * u) + curve.control * (2 * u * t) + curve.end * (t * t);
}

fn float segment_distance(Vec2 point, Vec2 first, Vec2 second) @local {
    Vec2 edge = second - first;
    float length_squared = edge.dot(edge);
    float t = length_squared > 0 ? math::clamp((point - first).dot(edge) / length_squared, 0.0f, 1.0f) : 0.0f;
    return (point - (first + edge * t)).length();
}

fn float distance_to_curves(Vec2 point, GlyphCurve[] curves) @local {
    float best = float::max;
    foreach (curve : curves) {
        Vec2 previous = curve.start;
        for (uint step = 1; step <= 64; step++) {
            Vec2 next = quadratic_point(curve, (float)step / 64);
            best = math::min(best, segment_distance(point, previous, next));
            previous = next;
        }
    }
    return best;
}

fn void test_add_font_faults_for_unreadable_bytes() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    char[] latin = $embed("../fixtures/fonts/latin.ttf");

    char[64] noise = { [0..63] = 0xAB };
    assert(@catch(assets.add_font(noise[..], small_font_desc())) == c3d::ASSET_FORMAT_ERROR);
    assert(@catch(assets.add_font(latin[:2048], small_font_desc())) == c3d::ASSET_FORMAT_ERROR);
    assert(@catch(assets.add_font({}, small_font_desc())) == c3d::ASSET_FORMAT_ERROR);
    assert(assets.fonts.free_count == 4);
}

fn void test_add_font_selects_collection_faces() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    char[] pair = $embed("../fixtures/fonts/pair.ttc");
    char[] latin = $embed("../fixtures/fonts/latin.ttf");

    FontDesc desc = small_font_desc();
    desc.face_index = 2;
    assert(@catch(assets.add_font(pair, desc)) == c3d::INVALID_ARGUMENT);
    desc.face_index = 1;
    assert(@catch(assets.add_font(latin, desc)) == c3d::INVALID_ARGUMENT);

    FontId bold = assets.add_font(pair, desc)!!;
    desc.face_index = 0;
    FontId regular = assets.add_font(pair, desc)!!;
    assert(near(assets.measure_text(regular, "A", 1000)!!.width, 639));
    assert(near(assets.measure_text(bold, "A", 1000)!!.width, 692));
}

fn void test_add_font_faults_without_readable_outlines() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);

    char[] renamed = copy_bytes($embed("../fixtures/fonts/latin.ttf"));
    rename_table(renamed, "glyf", "CFF2");
    assert(@catch(assets.add_font(renamed, small_font_desc())) == c3d::UNSUPPORTED);
}

fn void test_add_font_rejects_full_pool_and_bad_capacities() @test {
    AssetStore assets = create_store(max_fonts: 1);
    defer asset::destroy_asset_store(&assets);
    char[] latin = $embed("../fixtures/fonts/latin.ttf");

    FontDesc[] invalid = {
        { .max_glyphs = 0, .curve_texels = WIDTH, .band_texels = WIDTH },
        { .max_glyphs = 8, .curve_texels = 0, .band_texels = WIDTH },
        { .max_glyphs = 8, .curve_texels = WIDTH, .band_texels = 0 },
        { .max_glyphs = 8, .curve_texels = WIDTH * asset::FONT_MAX_ROWS + 1, .band_texels = WIDTH },
        { .max_glyphs = 8, .curve_texels = WIDTH, .band_texels = WIDTH * asset::FONT_MAX_ROWS + 1 },
    };
    foreach (desc : invalid) assert(@catch(assets.add_font(latin, desc)) == c3d::INVALID_ARGUMENT);

    assets.add_font(latin, small_font_desc())!!;
    assert(@catch(assets.add_font(latin, small_font_desc())) == c3d::CAPACITY_EXCEEDED);
}

fn void test_measure_text_sums_advances_and_kerning() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    FontId font = assets.add_font($embed("../fixtures/fonts/latin.ttf"), small_font_desc())!!;

    TextExtent extent = assets.measure_text(font, "AV", 100)!!;
    assert(near(extent.width, 119.9f) && near(extent.ascent, 106.9f) && near(extent.descent, -29.3f));
    assert(near(assets.measure_text(font, "To", 100)!!.width, 109.1f));
    assert(near(assets.measure_text(font, "AV Ж", 100)!!.width, 236.4f));

    FontMetrics metrics = assets.font_metrics(font);
    assert(near(metrics.ascent, 1.069f) && near(metrics.descent, -0.293f) && metrics.line_gap == 0);

    char[2] invalid = { 'A', 0xFF };
    assert(@catch(assets.measure_text(font, (String)invalid[..], 100)) == c3d::INVALID_ARGUMENT);
    assert(assets.font(font).glyph_count == 0);
}

fn void test_place_text_maps_code_points_and_skips_empty_glyphs() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    FontId font = assets.add_font($embed("../fixtures/fonts/latin.ttf"), small_font_desc())!!;
    GlyphPlacement[4] placements;

    usz count = assets.place_text(font, "AV Ж", placements[..])!!;
    assert(count == 3);
    assert(placements[0].glyph == GLYPH_A && near(placements[0].position.x, 0));
    assert(placements[1].glyph == GLYPH_V && near(placements[1].position.x, 0.599f));
    assert(placements[2].glyph == GLYPH_ZHE && near(placements[2].position.x, 1.459f));
    foreach (placement : placements[:count]) assert(placement.position.y == 0);
    assert(assets.font(font).glyph_slots[GLYPH_SPACE] == asset::FONT_GLYPH_EMPTY);

    count = assets.place_text(font, "A中V", placements[..])!!;
    assert(count == 3 && placements[1].glyph == GLYPH_NOTDEF);
    assert(near(placements[1].position.x, 0.639f) && near(placements[2].position.x, 1.239f));

    assert(assets.find_glyph(font, 'A')!! == GLYPH_A);
    assert(assets.find_glyph(font, 0x416)!! == GLYPH_ZHE);
    assert(@catch(assets.find_glyph(font, 0x4E2D)) == NOT_FOUND);
}

fn void test_place_text_faults_before_building() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    FontId font = assets.add_font($embed("../fixtures/fonts/latin.ttf"), small_font_desc())!!;
    GlyphPlacement[4] placements;
    GlyphPlacement[1] too_few;

    char[3] invalid = { 'A', 'V', 0xC0 };
    assert(@catch(assets.place_text(font, (String)invalid[..], placements[..])) == c3d::INVALID_ARGUMENT);
    assert(@catch(assets.place_text(font, "A V", too_few[..])) == c3d::CAPACITY_EXCEEDED);
    assert(assets.font(font).header.revision == 1 && assets.font(font).glyph_count == 0);
    assert(assets.place_text(font, " ", too_few[..])!! == 0);
}

fn void test_revision_advances_only_for_new_outlines() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    FontId font = assets.add_font($embed("../fixtures/fonts/latin.ttf"), small_font_desc())!!;
    FontAsset* record = assets.font(font);
    GlyphPlacement[4] placements;

    assert(record.header.revision == 1);
    assets.place_text(font, "AV", placements[..])!!;
    assert(record.header.revision == 2 && record.glyph_count == 2);
    assets.place_text(font, "VA", placements[..])!!;
    assert(record.header.revision == 2);
    assets.measure_text(font, "H", 20)!!;
    assert(record.header.revision == 2 && record.glyph_count == 2);
    assets.place_text(font, "AH", placements[..])!!;
    assert(record.header.revision == 3 && record.glyph_count == 3);
}

fn void test_full_font_faults_and_keeps_built_glyphs() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    FontId font = assets.add_font($embed("../fixtures/fonts/latin.ttf"), small_font_desc(max_glyphs: 2))!!;
    FontAsset* record = assets.font(font);
    GlyphPlacement[4] placements;

    assets.place_text(font, "AV", placements[..])!!;
    uint revision = record.header.revision;
    uint curve_texels = record.curve_texels;
    uint band_texels = record.band_texels;
    Vec4[] curves = alloc::new_array(tmem, Vec4, (sz)curve_texels);
    curves[..] = record.curves[:curve_texels];
    uint[] bands = alloc::new_array(tmem, uint, (sz)band_texels);
    bands[..] = record.bands[:band_texels];
    FontGlyph[2] glyphs;
    glyphs[..] = record.glyphs[:2];

    assert(@catch(assets.place_text(font, "AH", placements[..])) == c3d::CAPACITY_EXCEEDED);
    assert(record.header.revision == revision && record.glyph_count == 2 && record.glyph_slots[GLYPH_H] == 0);
    assert(record.curve_texels == curve_texels && record.band_texels == band_texels);
    for (uint texel = 0; texel < curve_texels; texel++) assert(record.curves[texel] == curves[texel]);
    for (uint texel = 0; texel < band_texels; texel++) assert(record.bands[texel] == bands[texel]);
    for (uint slot = 0; slot < 2; slot++) {
        assert(record.glyphs[slot].bounds == glyphs[slot].bounds);
        assert(record.glyphs[slot].band_location == glyphs[slot].band_location);
        assert(record.glyphs[slot].band_max == glyphs[slot].band_max);
    }
    assert(assets.place_text(font, "VA", placements[..])!! == 2);
}

fn void test_outlines_close_and_encode_lines() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    FontId latin = assets.add_font($embed("../fixtures/fonts/latin.ttf"), small_font_desc())!!;
    FontId cjk = assets.add_font($embed("../fixtures/fonts/cjk.otf"), small_font_desc())!!;
    GlyphPlacement[8] placements;

    assets.place_text(latin, "HOAVЖ", placements[..])!!;
    assets.place_text(cjk, "中文字永あア", placements[..])!!;
    FontAsset* latin_record = assets.font(latin);
    FontAsset* cjk_record = assets.font(cjk);

    uint[5] latin_glyphs = { GLYPH_H, GLYPH_O, GLYPH_A, GLYPH_V, GLYPH_ZHE };
    foreach (glyph : latin_glyphs) {
        assert(contours_close(latin_record, glyph_locations(latin_record, glyph)), "latin glyph %d", glyph);
    }
    assert(cjk_record.glyph_count == 6);
    foreach (uint glyph, slot : cjk_record.glyph_slots) {
        if (!slot) continue;
        assert(contours_close(cjk_record, glyph_locations(cjk_record, glyph)), "cjk glyph %d", glyph);
    }

    assert(glyph_locations(latin_record, GLYPH_O).len == 20 && glyph_locations(latin_record, GLYPH_A).len == 16);
    uint[] lines = glyph_locations(latin_record, GLYPH_H);
    assert(lines.len == 12);
    foreach (location : lines) {
        GlyphCurve curve = asset::font_curve(latin_record, location);
        assert(curve.control == curve.end);
    }
}

fn void test_split_cubics_stay_within_tolerance() @test {
    Vec2[4][3] cubics = {
        { { 0, 0 }, { 0, 1 }, { 1, 1 }, { 1, 0 } },
        { { 0, 0 }, { 1, 1 }, { 0, 1 }, { 1, 0 } },
        { { 0.1f, 0.2f }, { 0.12f, 0.25f }, { 0.15f, 0.22f }, { 0.2f, 0.2f } },
    };
    foreach (cubic : cubics) {
        List{GlyphCurve} curves;
        curves.tinit();
        asset::split_cubic(
            start:    cubic[0],
            control1: cubic[1],
            control2: cubic[2],
            end:      cubic[3],
            curves:   &curves,
        );

        assert(curves[0].start == cubic[0] && curves[curves.len() - 1].end == cubic[3]);
        for (sz index = 1; index < curves.len(); index++) assert(curves[index].start == curves[index - 1].end);
        for (uint step = 0; step <= 64; step++) {
            Vec2 point = cubic_point(cubic, (float)step / 64);
            assert(distance_to_curves(point, curves.array_view()) <= asset::FONT_CURVE_TOLERANCE * 1.01f);
        }
    }
}

fn void test_band_search_prefers_fewest_bands_at_minimum() @test {
    GlyphCurve[4] square = {
        { .start = { 0, 0 }, .control = { 1, 0 }, .end = { 1, 0 } },
        { .start = { 1, 0 }, .control = { 1, 1 }, .end = { 1, 1 } },
        { .start = { 1, 1 }, .control = { 0, 1 }, .end = { 0, 1 } },
        { .start = { 0, 1 }, .control = { 0, 0 }, .end = { 0, 0 } },
    };
    BandChoice square_bands = asset::choose_bands(square[..], 1, 0, 1);
    assert(square_bands.count == 1 && square_bands.largest == 2);

    GlyphCurve[4] edges;
    for (uint edge = 0; edge < 4; edge++) {
        Vec2 bottom = { (float)edge, (float)edge / 4 + 0.05f };
        Vec2 top = { (float)edge, (float)(edge + 1) / 4 - 0.05f };
        edges[edge] = { .start = bottom, .control = top, .end = top };
    }
    BandChoice horizontal = asset::choose_bands(edges[..], 1, 0, 1);
    assert(horizontal.count == 4 && horizontal.largest == 1);
    BandChoice vertical = asset::choose_bands(edges[..], 0, 0, 3);
    assert(vertical.count == 1 && vertical.largest == 0);
}

fn void test_bands_list_every_crossing_curve_in_order() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    FontId latin = assets.add_font($embed("../fixtures/fonts/latin.ttf"), small_font_desc())!!;
    FontId cjk = assets.add_font($embed("../fixtures/fonts/cjk.otf"), small_font_desc())!!;
    GlyphPlacement[8] placements;

    assets.place_text(latin, "AOVЖ", placements[..])!!;
    assets.place_text(cjk, "中あ", placements[..])!!;
    uint[4] latin_glyphs = { GLYPH_A, GLYPH_O, GLYPH_V, GLYPH_ZHE };
    foreach (glyph : latin_glyphs) check_bands(assets.font(latin), glyph);
    check_bands(assets.font(cjk), GLYPH_ZHONG);
    check_bands(assets.font(cjk), GLYPH_HIRAGANA_A);
}

fn void test_storage_rows_never_split_a_curve_or_band_block() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    FontDesc desc = { .max_glyphs = 8, .curve_texels = 2 * WIDTH, .band_texels = 2 * WIDTH };
    FontId font = assets.add_font($embed("../fixtures/fonts/latin.ttf"), desc)!!;
    FontAsset* record = assets.font(font);
    record.curve_texels = WIDTH - 3;
    record.band_texels = WIDTH - 5;
    GlyphPlacement[1] placements;

    assets.place_text(font, "O", placements[..])!!;
    assert(record.glyphs[0].band_location == 1 << 16);
    uint[] locations = glyph_locations(record, GLYPH_O);
    bool next_row;
    foreach (location : locations) {
        assert((location & 0xFFFF) != WIDTH - 1);
        if (location >> 16 == 1) next_row = true;
    }
    assert(next_row);
    assert(contours_close(record, locations));
    check_bands(record, GLYPH_O);
}
