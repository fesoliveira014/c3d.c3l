module c3d::test::overlay;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::pool;
import c3d::render @public;
import c3d::shader;
import gpu;
import std::math;

const uint OUTPUT_WIDTH @local = 100;
const uint OUTPUT_HEIGHT @local = 80;
const uint FONT_GLYPH_SPACE @local = 1;
const uint FONT_GLYPH_A @local = 34;
const uint FONT_GLYPH_V @local = 55;
const uint FONT_GLYPH_COUNT @local = 106;

fn OverlayRect rect_at(Vec2 min, Vec2 size) @local {
    OverlayRect rect = render::OVERLAY_RECT_DEFAULT;
    rect.min = min;
    rect.max = min + size;
    return rect;
}

fn uint pack_all(OverlayList* list, OverlayItemGpu[] items) @local {
    return render::pack_overlay_items(
        list:        list,
        assets:      null,
        width:       OUTPUT_WIDTH,
        height:      OUTPUT_HEIGHT,
        destination: items,
    );
}

fn FontDesc test_font_desc() @local {
    return {
        .max_glyphs   = 16,
        .curve_texels = asset::FONT_TEXTURE_WIDTH,
        .band_texels  = asset::FONT_TEXTURE_WIDTH,
    };
}

fn void test_full_list_faults_and_keeps_items() @test {
    OverlayList list = render::create_overlay_list(mem, { .max_items = 2, .max_clips = 1 });
    defer render::destroy_overlay_list(&list);

    list.add_rect(rect_at({ 0, 0 }, { 10, 10 }))!!;
    list.add_rect(rect_at({ 5, 5 }, { 10, 10 }))!!;
    assert(@catch(list.add_rect(rect_at({ 9, 9 }, { 1, 1 }))) == c3d::CAPACITY_EXCEEDED);
    assert(list.item_count == 2 && list.entries[1].rect.min == (Vec2){ 5, 5 });

    list.push_clip({ 0, 0 }, { 50, 50 })!!;
    assert(@catch(list.push_clip({ 1, 1 }, { 2, 2 })) == c3d::CAPACITY_EXCEEDED);
    assert(list.clip_depth == 1 && list.clips[0] == (Vec4){ 0, 0, 50, 50 });

    list.clear();
    assert(list.item_count == 0 && list.clip_depth == 0);
    list.add_rect(rect_at({ 0, 0 }, { 1, 1 }))!!;
    list.add_rect(rect_at({ 0, 0 }, { 1, 1 }))!!;
    list.push_clip({ 0, 0 }, { 1, 1 })!!;
}

fn void test_add_rect_rejects_each_invalid_class() @test {
    OverlayList list = render::create_overlay_list(mem, { .max_items = 4, .max_clips = 1 });
    defer render::destroy_overlay_list(&list);
    float nan = float::nan;
    OverlayRect[] cases = {
        { .min = { nan, 0 }, .max = { 10, 10 } },
        { .min = { 0, 0 }, .max = { 10, float::inf } },
        { .min = { 0, 0 }, .max = { 10, 10 }, .corner_radii = { 0, nan, 0, 0 } },
        { .min = { 0, 0 }, .max = { 10, 10 }, .fill = { 1, 1, nan, 1 } },
        { .min = { 0, 0 }, .max = { 10, 10 }, .border_widths = { 0, 0, 0, nan } },
        { .min = { 0, 0 }, .max = { 10, 10 }, .border_color = { nan, 0, 0, 1 } },
        { .min = { 0, 0 }, .max = { 10, 10 }, .uv_rect = { 0, 0, float::inf, 1 } },
        { .min = { 0, 0 }, .max = { 10, 10 }, .slice_uv = { 0, nan, 0, 0 } },
        { .min = { 0, 0 }, .max = { 10, 10 }, .slice_pixels = { 0, 0, nan, 0 } },
        { .min = { 10, 0 }, .max = { 9, 10 } },
        { .min = { 0, 10 }, .max = { 10, 9 } },
        { .min = { 0, 0 }, .max = { 10, 10 }, .corner_radii = { 0, 0, -1, 0 } },
        { .min = { 0, 0 }, .max = { 10, 10 }, .border_widths = { -1, 0, 0, 0 } },
        { .min = { 0, 0 }, .max = { 10, 10 }, .slice_uv = { -0.1f, 0, 0, 0 } },
        { .min = { 0, 0 }, .max = { 10, 10 }, .slice_pixels = { 0, -1, 0, 0 } },
        { .min = { 0, 0 }, .max = { 10, 10 }, .slice_pixels = { 6, 0, 5, 0 } },
        { .min = { 0, 0 }, .max = { 10, 10 }, .slice_pixels = { 0, 6, 0, 5 } },
        { .min = { 0, 0 }, .max = { 10, 10 }, .slice_uv = { 0.6f, 0, 0.5f, 0 } },
        { .min = { 0, 0 }, .max = { 10, 10 }, .slice_uv = { 0, 0.6f, 0, 0.5f } },
    };

    list.add_rect(rect_at({ 1, 2 }, { 3, 4 }))!!;
    foreach (rect : cases) {
        assert(@catch(list.add_rect(rect)) == c3d::INVALID_ARGUMENT);
        assert(list.item_count == 1 && list.entries[0].rect.min == (Vec2){ 1, 2 });
    }

    OverlayRect edge = rect_at({ 0, 0 }, { 10, 10 });
    edge.slice_pixels = { 5, 5, 5, 5 };
    edge.slice_uv = { 0.5f, 0.5f, 0.5f, 0.5f };
    edge.min = { 3, 3 };
    edge.max = { 13, 13 };
    list.add_rect(edge)!!;
    list.add_rect(rect_at({ 7, 7 }, { 0, 0 }))!!;
    assert(list.item_count == 3);
}

fn void test_push_clip_rejects_invalid_boxes() @test {
    OverlayList list = render::create_overlay_list(mem, { .max_items = 1, .max_clips = 2 });
    defer render::destroy_overlay_list(&list);

    assert(@catch(list.push_clip({ float::nan, 0 }, { 1, 1 })) == c3d::INVALID_ARGUMENT);
    assert(@catch(list.push_clip({ 0, 0 }, { -float::inf, 1 })) == c3d::INVALID_ARGUMENT);
    assert(@catch(list.push_clip({ 5, 0 }, { 4, 1 })) == c3d::INVALID_ARGUMENT);
    assert(@catch(list.push_clip({ 0, 5 }, { 1, 4 })) == c3d::INVALID_ARGUMENT);
    assert(list.clip_depth == 0);
    list.push_clip({ 3, 3 }, { 3, 3 })!!;
    assert(list.clip_depth == 1);
}

fn void test_clips_intersect_and_restore() @test {
    OverlayList list = render::create_overlay_list(mem, { .max_items = 4, .max_clips = 2 });
    defer render::destroy_overlay_list(&list);

    list.add_rect(rect_at({ 0, 0 }, { 1, 1 }))!!;
    list.push_clip({ 10, 10 }, { 60, 40 })!!;
    list.add_rect(rect_at({ 0, 0 }, { 1, 1 }))!!;
    list.push_clip({ 30, 0 }, { 90, 20 })!!;
    list.add_rect(rect_at({ 0, 0 }, { 1, 1 }))!!;
    list.pop_clip();
    list.add_rect(rect_at({ 0, 0 }, { 1, 1 }))!!;
    list.pop_clip();

    assert(list.clip_depth == 0);
    assert(list.entries[0].clip.x == -float::max && list.entries[0].clip.w == float::max);
    assert(list.entries[1].clip == (Vec4){ 10, 10, 60, 40 });
    assert(list.entries[2].clip == (Vec4){ 30, 10, 60, 20 });
    assert(list.entries[3].clip == (Vec4){ 10, 10, 60, 40 });
}

fn void test_scissor_rounds_outward_and_clamps() @test {
    gpu::ScissorRect fractional = render::overlay_scissor({ 10.2f, 20.7f, 30.1f, 40.0f }, OUTPUT_WIDTH, OUTPUT_HEIGHT);
    assert(fractional.x == 10 && fractional.y == 20 && fractional.width == 21 && fractional.height == 20);

    gpu::ScissorRect outside = render::overlay_scissor({ -5, -5, 500, 500 }, OUTPUT_WIDTH, OUTPUT_HEIGHT);
    assert(outside.x == 0 && outside.y == 0 && outside.width == 100 && outside.height == 80);

    gpu::ScissorRect unbounded = render::overlay_scissor(
        { -float::max, -float::max, float::max, float::max },
        OUTPUT_WIDTH,
        OUTPUT_HEIGHT,
    );
    assert(unbounded.width == 100 && unbounded.height == 80);

    gpu::ScissorRect empty = render::overlay_scissor({ 30, 10, 20, 40 }, OUTPUT_WIDTH, OUTPUT_HEIGHT);
    assert(empty.width == 0 && empty.height == 0);
    gpu::ScissorRect beyond = render::overlay_scissor({ 120, 10, 130, 40 }, OUTPUT_WIDTH, OUTPUT_HEIGHT);
    assert(beyond.width == 0);
}

fn void test_items_outside_their_clip_emit_nothing() @test {
    OverlayList list = render::create_overlay_list(mem, { .max_items = 8, .max_clips = 2 });
    defer render::destroy_overlay_list(&list);
    OverlayItemGpu[8] items;

    list.push_clip({ 10, 10 }, { 50, 50 })!!;
    list.add_rect(rect_at({ 20, 20 }, { 5, 5 }))!!;
    list.add_rect(rect_at({ 60, 60 }, { 5, 5 }))!!;
    list.add_rect(rect_at({ 3, 3 }, { 4, 4 }))!!;
    list.add_rect(rect_at({ 30, 30 }, { 0, 5 }))!!;
    list.add_rect(rect_at({ 40, 40 }, { 5, 5 }))!!;
    list.push_clip({ 60, 0 }, { 70, 10 })!!;
    list.add_rect(rect_at({ 20, 20 }, { 5, 5 }))!!;
    list.pop_clip();
    list.pop_clip();
    list.add_rect(rect_at({ 150, 10 }, { 5, 5 }))!!;

    assert(pack_all(&list, items[..]) == 2);
    assert(list.prepared.run_count == 1);
    assert(list.runs[0].first == 0 && list.runs[0].count == 2);
    assert(items[0].bounds.x == 20 && items[1].bounds.x == 40);
}

fn void test_runs_split_only_at_scissor_changes() @test {
    OverlayList list = render::create_overlay_list(mem, { .max_items = 8, .max_clips = 1 });
    defer render::destroy_overlay_list(&list);
    OverlayItemGpu[8] items;
    Vec2[2][3] boxes = {
        { { 0, 0 }, { 50, 50 } },
        { { 50, 0 }, { 100, 50 } },
        { { 0.2f, 0.4f }, { 49.6f, 49.1f } },
    };
    uint[5] sequence = { 0, 0, 1, 1, 2 };

    foreach (box : sequence) {
        list.push_clip(boxes[box][0], boxes[box][1])!!;
        list.add_rect(box == 1 ? rect_at({ 60, 10 }, { 10, 10 }) : rect_at({ 10, 10 }, { 10, 10 }))!!;
        list.pop_clip();
    }

    assert(pack_all(&list, items[..]) == 5);
    assert(list.prepared.run_count == 3);
    assert(list.runs[0].first == 0 && list.runs[0].count == 2);
    assert(list.runs[1].first == 2 && list.runs[1].count == 2 && list.runs[1].scissor.x == 50);
    assert(list.runs[2].first == 4 && list.runs[2].count == 1);
    assert(list.runs[2].scissor.width == 50 && list.runs[2].scissor.height == 50);

    list.clear();
    list.push_clip(boxes[0][0], boxes[0][1])!!;
    list.add_rect(rect_at({ 10, 10 }, { 10, 10 }))!!;
    list.pop_clip();
    list.push_clip(boxes[2][0], boxes[2][1])!!;
    list.add_rect(rect_at({ 10, 10 }, { 10, 10 }))!!;
    list.pop_clip();
    assert(pack_all(&list, items[..]) == 2 && list.prepared.run_count == 1);
}

fn void test_packing_clamps_and_encodes() @test {
    OverlayRect rect = rect_at({ 0, 0 }, { 40, 20 });
    rect.corner_radii = { 100, 5, 0, 12 };
    rect.border_widths = { 50, 4, 0, 30 };
    rect.fill = { 1, 0.5f, 0, 0.25f };
    rect.border_color = { 2, -1, 0.5f, 1 };
    rect.texture = { .kind = ASSET, .asset = { .index = 3, .generation = 1 } };
    rect.uv_rect = { 0.25f, 0.5f, 4, 3 };
    rect.slice_uv = { 0.25f, 0.5f, 0.25f, 0.5f };
    rect.slice_pixels = { 8, 4, 8, 4 };
    OverlayBinding binding = { .texture = (gpu::TextureIndex)7u, .sampler = (gpu::SamplerIndex)5u };

    OverlayItemGpu item = render::pack_overlay_rect(&rect, binding);
    assert(item.bounds.z == 40 && item.bounds.w == 20 && item.uv_rect.z == 4);
    assert(item.radii_top == 0x4500_4900 && item.radii_bottom == 0x4900_0000);
    assert(item.borders_left_top == 0x4400_5100 && item.borders_right_bottom == 0x4d00_0000);
    assert(item.slice_uv_left_top == 0x8000_4000 && item.slice_uv_right_bottom == 0x8000_4000);
    assert(item.slice_pixels_left_top == 0x4400_4800 && item.slice_pixels_right_bottom == 0x4400_4800);
    assert(item.fill == 0x4000_80ff && item.border_color == 0xff80_00ff);
    assert((uint)item.texture == 7);
    uint flags = shader::OVERLAY_FLAG_TEXTURED | shader::OVERLAY_FLAG_NINE_SLICE | shader::OVERLAY_FLAG_BORDER;
    assert(item.sampler_kind_flags == (5 | (shader::OVERLAY_KIND_RECT << 16) | (flags << 24)));

    OverlayRect huge = rect_at({ 0, 0 }, { 200000, 200000 });
    huge.corner_radii = { 90000, 0, 0, 0 };
    assert(render::pack_overlay_rect(&huge, {}).radii_top == 0x0000_7bff);

    OverlayRect solid = rect_at({ 0, 0 }, { 40, 20 });
    solid.slice_pixels = { 8, 4, 8, 4 };
    OverlayItemGpu plain = render::pack_overlay_rect(&solid, binding);
    assert(plain.sampler_kind_flags == 5);
}

fn void test_references_resolve_or_fault() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    TargetPool targets = pool::create_pool{TargetRecord, RenderTargetId}(mem, 2);
    defer pool::destroy_pool{TargetRecord, RenderTargetId}(&targets);
    OverlayList list = render::create_overlay_list(mem, { .max_items = 1, .max_clips = 1 });
    defer render::destroy_overlay_list(&list);

    char[16] color_pixels;
    char[8] integer_pixels;
    char[96] cube_pixels;
    TextureId color = assets.add_texture(material::texture_2d_desc(2, 2, RGBA8_UNORM), color_pixels[..])!!;
    material::TextureDesc integer_desc = material::texture_2d_desc(2, 2, R16_UINT);
    integer_desc.generate_mips = false;
    TextureId integer = assets.add_texture(integer_desc, integer_pixels[..])!!;
    TextureId cube = assets.add_texture(material::texture_cube_desc(2, RGBA8_UNORM), cube_pixels[..])!!;
    TextureId removed = assets.add_texture(material::texture_2d_desc(2, 2, RGBA8_UNORM), color_pixels[..])!!;
    assets.remove_texture(removed);
    material::SamplerDesc compare_desc = material::sampler_desc(LINEAR, CLAMP_TO_EDGE);
    compare_desc.compare_enable = true;
    SamplerId compare = assets.add_sampler(compare_desc)!!;
    SamplerId removed_sampler = assets.add_sampler(material::sampler_desc(LINEAR, CLAMP_TO_EDGE))!!;
    assets.remove_sampler(removed_sampler);
    RenderTargetId target = targets.add({})!!;
    RenderTargetId removed_target = targets.add({})!!;
    targets.remove(removed_target);

    list.add_rect(rect_at({ 0, 0 }, { 4, 4 }))!!;
    OverlayRect* rect = &list.entries[0].rect;
    render::check_overlay_refs(&assets, &targets, &list)!!;
    rect.texture = { .kind = ASSET, .asset = color };
    render::check_overlay_refs(&assets, &targets, &list)!!;
    rect.texture = { .kind = RENDER_TARGET, .target = target };
    render::check_overlay_refs(&assets, &targets, &list)!!;

    rect.texture = { .kind = ASSET, .asset = removed };
    assert(@catch(render::check_overlay_refs(&assets, &targets, &list)) == c3d::INVALID_ID);
    rect.texture = { .kind = RENDER_TARGET, .target = removed_target };
    assert(@catch(render::check_overlay_refs(&assets, &targets, &list)) == c3d::INVALID_ID);
    rect.texture = { .kind = RENDER_TARGET, .target = {} };
    assert(@catch(render::check_overlay_refs(&assets, &targets, &list)) == c3d::INVALID_ID);
    rect.texture = { .kind = ASSET, .asset = integer };
    assert(@catch(render::check_overlay_refs(&assets, &targets, &list)) == c3d::UNSUPPORTED);
    rect.texture = { .kind = ASSET, .asset = cube };
    assert(@catch(render::check_overlay_refs(&assets, &targets, &list)) == c3d::UNSUPPORTED);

    rect.texture = { .kind = ASSET, .asset = color };
    rect.sampler = removed_sampler;
    assert(@catch(render::check_overlay_refs(&assets, &targets, &list)) == c3d::INVALID_ID);
    rect.sampler = compare;
    assert(@catch(render::check_overlay_refs(&assets, &targets, &list)) == c3d::INVALID_ARGUMENT);
}

fn void test_add_glyphs_faults_and_keeps_list() @test {
    OverlayList list = render::create_overlay_list(mem, { .max_items = 2, .max_clips = 1, .max_glyphs = 3 });
    defer render::destroy_overlay_list(&list);
    GlyphPlacement[4] glyphs = { { .glyph = 1 }, { .glyph = 2 }, { .glyph = 3 }, { .glyph = 4 } };
    OverlayGlyphRun run = { .glyphs = glyphs[:2], .size_pixels = 16, .color = { 1, 1, 1, 1 } };

    list.add_glyphs(run)!!;
    assert(@catch(list.add_glyphs(run)) == c3d::CAPACITY_EXCEEDED);
    assert(list.item_count == 1 && list.glyph_count == 2 && list.glyphs[1].glyph == 2);

    float nan = float::nan;
    OverlayGlyphRun[] invalid = {
        { .glyphs = glyphs[:1], .size_pixels = 0, .color = { 1, 1, 1, 1 } },
        { .glyphs = glyphs[:1], .size_pixels = float::inf, .color = { 1, 1, 1, 1 } },
        { .glyphs = glyphs[:1], .origin = { nan, 0 }, .size_pixels = 16, .color = { 1, 1, 1, 1 } },
        { .glyphs = glyphs[:1], .size_pixels = 16, .color = { 1, nan, 1, 1 } },
    };
    foreach (candidate : invalid) assert(@catch(list.add_glyphs(candidate)) == c3d::INVALID_ARGUMENT);
    GlyphPlacement[1] bad_position = { { .glyph = 1, .position = { nan, 0 } } };
    run.glyphs = bad_position[..];
    assert(@catch(list.add_glyphs(run)) == c3d::INVALID_ARGUMENT);
    assert(list.item_count == 1 && list.glyph_count == 2);

    list.add_rect(rect_at({ 0, 0 }, { 1, 1 }))!!;
    run.glyphs = glyphs[:1];
    assert(@catch(list.add_glyphs(run)) == c3d::CAPACITY_EXCEEDED);

    list.clear();
    assert(list.item_count == 0 && list.glyph_count == 0);
    run.glyphs = {};
    list.add_glyphs(run)!!;
}

fn void test_glyph_items_map_em_bounds_to_pixels() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    FontId font = assets.add_font($embed("../fixtures/fonts/latin.ttf"), test_font_desc())!!;
    GlyphPlacement[2] placements;
    usz count = assets.place_text(font, "AV", placements[..])!!;
    OverlayList list = render::create_overlay_list(mem, { .max_items = 2, .max_clips = 1, .max_glyphs = 2 });
    defer render::destroy_overlay_list(&list);

    list.add_glyphs({
        .font        = font,
        .glyphs      = placements[:count],
        .origin      = { 10, 50 },
        .size_pixels = 20,
        .color       = { 1, 0, 0, 1 },
    })!!;
    list.bindings[0] = { .texture = (gpu::TextureIndex)7u, .bands = (gpu::TextureIndex)9u };

    OverlayItemGpu[2] items;
    uint emitted = render::pack_overlay_items(
        list:        &list,
        assets:      &assets,
        width:       OUTPUT_WIDTH,
        height:      OUTPUT_HEIGHT,
        destination: items[..],
    );
    assert(emitted == 2 && list.prepared.run_count == 1);

    FontAsset* record = assets.font(font);
    foreach (index, item : items) {
        FontGlyph* glyph = &record.glyphs[record.glyph_slots[placements[index].glyph] - 1];
        Vec4 em = glyph.bounds;
        Vec2 pen = (Vec2){ 10, 50 } + placements[index].position * 20.0f;
        assert(item.bounds == (Vec4){ pen.x + em.x * 20, pen.y - em.w * 20, pen.x + em.z * 20, pen.y - em.y * 20 });
        assert(item.uv_rect == (Vec4){ em.x, em.w, em.z, em.y });
        assert(item.glyph_location == glyph.band_location && item.glyph_band_max == glyph.band_max);
        assert((uint)item.texture == 7 && (uint)item.band_texture == 9);
        assert(item.fill == 0xff00_00ff);
        assert(item.sampler_kind_flags == shader::OVERLAY_KIND_GLYPH << shader::OVERLAY_KIND_SHIFT);
        assert(item.radii_top == 0 && item.borders_left_top == 0 && item.slice_uv_left_top == 0);
    }
}

fn void test_glyphs_and_rects_share_scissor_runs() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    FontId font = assets.add_font($embed("../fixtures/fonts/latin.ttf"), test_font_desc())!!;
    GlyphPlacement[2] placements;
    usz count = assets.place_text(font, "AV", placements[..])!!;
    OverlayList list = render::create_overlay_list(mem, { .max_items = 6, .max_clips = 1, .max_glyphs = 4 });
    defer render::destroy_overlay_list(&list);
    OverlayGlyphRun run = {
        .font        = font,
        .glyphs      = placements[:count],
        .origin      = { 10, 50 },
        .size_pixels = 20,
        .color       = { 1, 1, 1, 1 },
    };

    list.add_rect(rect_at({ 0, 0 }, { 5, 5 }))!!;
    list.add_glyphs(run)!!;
    list.add_rect(rect_at({ 60, 0 }, { 5, 5 }))!!;
    list.push_clip({ 0, 0 }, { 20, 80 })!!;
    list.add_glyphs(run)!!;
    list.pop_clip();

    OverlayItemGpu[8] items;
    uint emitted = render::pack_overlay_items(
        list:        &list,
        assets:      &assets,
        width:       OUTPUT_WIDTH,
        height:      OUTPUT_HEIGHT,
        destination: items[..],
    );
    assert(emitted == 5 && list.prepared.run_count == 2);
    assert(list.runs[0].first == 0 && list.runs[0].count == 4);
    assert(list.runs[1].first == 4 && list.runs[1].count == 1);

    uint[5] kinds = {
        shader::OVERLAY_KIND_RECT,
        shader::OVERLAY_KIND_GLYPH,
        shader::OVERLAY_KIND_GLYPH,
        shader::OVERLAY_KIND_RECT,
        shader::OVERLAY_KIND_GLYPH,
    };
    foreach (index, kind : kinds) {
        assert(((items[index].sampler_kind_flags >> shader::OVERLAY_KIND_SHIFT) & shader::OVERLAY_KIND_MASK) == kind);
    }
    assert(items[4].glyph_location == items[1].glyph_location && items[4].bounds == items[1].bounds);
}

fn void test_glyph_references_resolve_or_fault() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    TargetPool targets = pool::create_pool{TargetRecord, RenderTargetId}(mem, 1);
    defer pool::destroy_pool{TargetRecord, RenderTargetId}(&targets);
    char[] latin = $embed("../fixtures/fonts/latin.ttf");
    FontId font = assets.add_font(latin, test_font_desc())!!;
    FontId removed = assets.add_font(latin, test_font_desc())!!;
    assets.remove_font(removed);
    GlyphPlacement[1] placements;
    assets.place_text(font, "A ", placements[..])!!;
    OverlayList list = render::create_overlay_list(mem, { .max_items = 1, .max_clips = 1, .max_glyphs = 1 });
    defer render::destroy_overlay_list(&list);

    list.add_glyphs({ .font = font, .glyphs = placements[..], .size_pixels = 16, .color = { 1, 1, 1, 1 } })!!;
    render::check_overlay_refs(&assets, &targets, &list)!!;

    OverlayText* text = &list.entries[0].text;
    text.font = removed;
    assert(@catch(render::check_overlay_refs(&assets, &targets, &list)) == c3d::INVALID_ID);
    text.font = {};
    assert(@catch(render::check_overlay_refs(&assets, &targets, &list)) == c3d::INVALID_ID);

    text.font = font;
    list.glyphs[0].glyph = FONT_GLYPH_COUNT;
    assert(@catch(render::check_overlay_refs(&assets, &targets, &list)) == c3d::INVALID_ARGUMENT);
    list.glyphs[0].glyph = FONT_GLYPH_V;
    assert(@catch(render::check_overlay_refs(&assets, &targets, &list)) == c3d::INVALID_ARGUMENT);
    list.glyphs[0].glyph = FONT_GLYPH_SPACE;
    assert(@catch(render::check_overlay_refs(&assets, &targets, &list)) == c3d::INVALID_ARGUMENT);
    list.glyphs[0].glyph = FONT_GLYPH_A;
    render::check_overlay_refs(&assets, &targets, &list)!!;
}
