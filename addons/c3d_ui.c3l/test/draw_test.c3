module c3d::ui::draw_test;

import c3d;
import c3d::asset;
import c3d::render @public;
import c3d::ui;
import c3d::ui::fixture;
import std::math;

const String THREE_LABELS @local = `{ "root": { "kind": "panel", "direction": "column", "children": [
    { "kind": "label", "style": "text", "text": "Alpha" },
    { "kind": "label", "style": "text", "text": "Beta" },
    { "kind": "label", "style": "text", "text": "Gamma" } ] } }`;

struct Many @local {
    uint count;
}

fn UiValue many_count(void* user, UiScope* scope) @local => { .kind = LIST, .count = ((Many*)user).count };

fn String entry_bytes(OverlayList* list) @local {
    return (String)((char*)list.entries.ptr)[:list.item_count * OverlayEntry::size];
}

fn String glyph_bytes(OverlayList* list) @local {
    return (String)((char*)list.glyphs.ptr)[:list.glyph_count * GlyphPlacement::size];
}

fn uint rect_count(OverlayList* list) @local {
    uint count;
    foreach (entry : list.entries[:list.item_count]) {
        if (entry.kind == RECT) count++;
    }
    return count;
}

fn OverlayEntry* glyph_run(OverlayList* list, uint index) @local {
    uint seen;
    foreach (&entry : list.entries[:list.item_count]) {
        if (entry.kind != GLYPHS) continue;
        if (seen == index) return entry;
        seen++;
    }
    unreachable("no such glyph run");
}

fn void test_same_inputs_produce_the_same_list() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    fixture::register_squad(&fixture);
    fixture.ui.load_document(`{ "root": { "kind": "list", "items": "{squad.members}", "direction": "column", "gap": 2,
        "template": { "kind": "panel", "fill": "#204060ff", "radius": 3, "padding": 2, "children": [
            { "kind": "label", "style": "text", "text": "{member.name}" },
            { "kind": "bar", "value": "{member.health}", "size": [40, 4], "bar_fill": "#c03030ff" } ] } } }`)!!;

    fixture::frame(&fixture);
    String entries = entry_bytes(&fixture.list).tcopy();
    String glyphs = glyph_bytes(&fixture.list).tcopy();
    assert(fixture.list.item_count > 0 && fixture.list.glyph_count > 0);

    fixture::frame(&fixture);
    assert(entry_bytes(&fixture.list) == entries && glyph_bytes(&fixture.list) == glyphs);
}

fn void test_instance_capacity_fault_leaves_the_ui_usable() @test {
    UiDesc desc = ui::default_ui_desc();
    desc.max_instances = 4;
    Fixture fixture;
    fixture::create_fixture(&fixture, desc);
    defer fixture::destroy_fixture(&fixture);
    Many many = { .count = 10 };
    fixture.ui.bind(
        name:   "many.items",
        kind:   LIST,
        getter: &many_count,
        user:   &many,
    )!!;
    fixture.ui.load_document(`{ "root": { "kind": "list", "items": "{many.items}",
        "template": { "kind": "panel", "fill": "#ffffffff", "size": [4, 4] } } }`)!!;

    assert(@catch(fixture.ui.update(800, 600, 1)) == c3d::CAPACITY_EXCEEDED);
    fixture.list.clear();
    fixture.ui.draw(&fixture.list)!!;
    assert(fixture.list.item_count == 0);

    many.count = 2;
    fixture::frame(&fixture);
    assert(rect_count(&fixture.list) == 2);
}

fn void test_overlay_capacity_fault_leaves_the_ui_usable() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture, list_desc: { .max_items = 2, .max_clips = 4, .max_glyphs = 64 });
    defer fixture::destroy_fixture(&fixture);
    fixture.ui.load_document(`{ "root": { "kind": "panel", "children": [
        { "kind": "panel", "fill": "#ff0000ff", "size": [4, 4] },
        { "kind": "panel", "fill": "#00ff00ff", "size": [4, 4] },
        { "kind": "panel", "fill": "#0000ffff", "size": [4, 4] } ] } }`)!!;

    fixture.ui.update(800, 600, 1)!!;
    fixture.list.clear();
    assert(@catch(fixture.ui.draw(&fixture.list)) == c3d::CAPACITY_EXCEEDED);

    render::destroy_overlay_list(&fixture.list);
    fixture.list = render::create_overlay_list(mem, render::default_overlay_list_desc());
    fixture::frame(&fixture);
    assert(rect_count(&fixture.list) == 3);
}

fn void test_placement_cache_hits_unchanged_lines() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    fixture.ui.load_document(THREE_LABELS)!!;

    fixture::frame(&fixture);
    assert(fixture.ui.stats.placement_misses == 3 && fixture.ui.stats.placement_hits == 0);
    fixture::frame(&fixture);
    assert(fixture.ui.stats.placement_misses == 0 && fixture.ui.stats.placement_hits == 3);
    assert(fixture.ui.stats.placement_clears == 0);
}

fn void test_placement_cache_clears_when_full() @test {
    UiDesc desc = ui::default_ui_desc();
    desc.cache_lines = 2;
    Fixture fixture;
    fixture::create_fixture(&fixture, desc);
    defer fixture::destroy_fixture(&fixture);
    fixture.ui.load_document(THREE_LABELS)!!;

    fixture::frame(&fixture);
    assert(fixture.ui.stats.placement_clears >= 1);
    assert(fixture.list.glyph_count == 14);
}

fn void test_fallback_splits_runs_by_font() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    fixture.ui.load_document(`{ "root": { "kind": "label", "style": "text", "text": "AB中文" } }`)!!;
    fixture::frame(&fixture);

    OverlayEntry* latin = glyph_run(&fixture.list, 0);
    OverlayEntry* cjk = glyph_run(&fixture.list, 1);
    assert(c3d::same_id(latin.text.font, fixture.latin) && latin.text.count == 2);
    assert(c3d::same_id(cjk.text.font, fixture.cjk) && cjk.text.count == 2);
    float advance = fixture.assets.measure_text(fixture.latin, "AB", 10)!!.width;
    assert(math::abs(cjk.text.origin.x - latin.text.origin.x - advance) < 1e-3);
    assert(latin.text.origin.y == cjk.text.origin.y && latin.text.origin.y == math::round(latin.text.origin.y));
}

fn void test_scale_multiplies_layout_and_pointer() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    fixture.ui.on("box.click", &fixture::record_action, &fixture.recorder)!!;
    fixture.ui.load_document(`{ "root": {
        "kind": "button", "fill": "#ffffffff", "size": [100, 20], "on_click": "box.click" } }`)!!;

    fixture::frame(&fixture, scale: 2);
    OverlayRect rect = fixture.list.entries[0].rect;
    assert(rect.min == (Vec2){ 0, 0 } && rect.max == (Vec2){ 200, 40 });

    fixture::point(&fixture, { 150, 30 });
    fixture::frame(&fixture, { fixture::button_down({ 150, 30 }), fixture::button_up({ 150, 30 }) }, scale: 2);
    assert(fixture.recorder.calls == 1);
}

fn void test_tooltip_shows_only_while_its_parent_is_hovered() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    fixture.ui.load_document(`{ "root": { "kind": "panel", "size": [100, 20], "children": [
        { "kind": "tooltip", "children": [ { "kind": "label", "style": "text", "text": "tip" } ] } ] } }`)!!;

    fixture::frame(&fixture);
    assert(!fixture::has_line(&fixture, "tip"));
    fixture::point(&fixture, { 10, 10 });
    fixture::frame(&fixture);
    assert(fixture::has_line(&fixture, "tip"));
    fixture::point(&fixture, { 300, 300 });
    fixture::frame(&fixture);
    assert(!fixture::has_line(&fixture, "tip"));
}

fn void test_font_replacement_clears_placement_cache() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    fixture.ui.load_document(THREE_LABELS)!!;
    fixture::frame(&fixture);
    fixture::frame(&fixture);
    assert(fixture.ui.stats.placement_clears == 0 && fixture.ui.stats.placement_hits == 3);

    fixture.assets.replace_font(
        font: fixture.latin,
        file: $embed("../../../test/fixtures/fonts/pair.ttc"),
        desc: fixture::TEST_FONT_DESC,
    )!!;
    fixture::frame(&fixture);

    assert(fixture.ui.stats.placement_clears == 1 && fixture.ui.stats.placement_misses == 3);
    uint glyph_total = (uint)fixture.assets.font(fixture.latin).glyph_slots.len;
    assert(fixture.list.glyph_count > 0);
    foreach (placement : fixture.list.glyphs[:fixture.list.glyph_count]) assert(placement.glyph < glyph_total);
}

fn void test_removed_font_after_restyle_keeps_drawing() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    fixture.ui.load_document(`{ "root": { "kind": "label", "style": "text", "text": "Alpha" } }`)!!;
    fixture::frame(&fixture);
    fixture.ui.load_styles({ `{ "text": { "font": "ui/cjk", "font_size": 10 } }` })!!;
    fixture::frame(&fixture);
    fixture.assets.remove_font(fixture.latin);
    fixture::frame(&fixture);
}
