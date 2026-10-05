module c3d::ui::style_test;

import c3d;
import c3d::render @public;
import c3d::ui @public;
import c3d::ui::fixture;
import std::math;

fn UiProperties base_of(Fixture* fixture, String name) @local {
    return ui::style_properties(ui::find_style(&fixture.ui, name)!!, {});
}

fn Vec4 first_fill(Fixture* fixture) @local {
    foreach (entry : fixture.list.entries[:fixture.list.item_count]) {
        if (entry.kind == RECT) return entry.rect.fill;
    }
    unreachable("no rect drawn");
}

fn void test_child_overrides_parent_across_three_levels() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);

    fixture.ui.load_styles({ `{
        "a": { "fill": "#ff0000ff", "padding": 4, "font_size": 12 },
        "b": { "extends": "a", "fill": "#00ff00ff" },
        "c": { "extends": "b", "padding": 8 }
    }` })!!;
    UiProperties c = base_of(&fixture, "c");
    assert(c.fill == fixture::srgb(0x00ff00ff));
    assert(c.padding == (Vec4){ 8, 8, 8, 8 });
    assert(c.font_size == 12);
    assert(base_of(&fixture, "a").padding == (Vec4){ 4, 4, 4, 4 });
}

fn void test_extends_cycle_faults() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);

    fixture::expect_styles_fault(
        fixture:  &fixture,
        sheets:   { `{ "a": { "extends": "c" }, "b": { "extends": "a" }, "c": { "extends": "b" } }` },
        expected: ui::STYLE_CYCLE,
        path:     "/0/b/extends",
    );
}

fn void test_state_blocks_apply_only_in_their_state() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);

    fixture.ui.load_styles({ `{ "button": {
        "fill": "#101010ff", "text_color": "#eeeeeeff",
        "hover": { "fill": "#202020ff" },
        "pressed": { "fill": "#303030ff" },
        "disabled": { "fill": "#404040ff", "text_color": "#777777ff" }
    } }` })!!;
    UiStyle* button = ui::find_style(&fixture.ui, "button")!!;
    assert(ui::style_properties(button, {}).fill == fixture::srgb(0x101010ff));
    assert(ui::style_properties(button, { .focused = true }).fill == fixture::srgb(0x101010ff));
    assert(ui::style_properties(button, { .hovered = true }).fill == fixture::srgb(0x202020ff));
    assert(ui::style_properties(button, { .hovered = true, .pressed = true }).fill == fixture::srgb(0x303030ff));
    UiProperties disabled = ui::style_properties(button, { .hovered = true, .pressed = true, .disabled = true });
    assert(disabled.fill == fixture::srgb(0x404040ff) && disabled.text_color == fixture::srgb(0x777777ff));
    assert(ui::style_properties(button, { .hovered = true }).text_color == fixture::srgb(0xeeeeeeff));
}

fn void test_later_sheet_overrides_and_extends_across_sheets() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);

    fixture.ui.load_styles({
        `{ "base": { "fill": "#ff0000ff" }, "child": { "extends": "base", "padding": 2 } }`,
        `{ "base": { "fill": "#0000ffff" } }`,
    })!!;
    UiProperties child = base_of(&fixture, "child");
    assert(child.fill == fixture::srgb(0x0000ffff) && child.padding == (Vec4){ 2, 2, 2, 2 });
    assert(@catch(ui::find_style(&fixture.ui, "text")) == NOT_FOUND);
}

fn void test_failed_style_load_keeps_the_old_set() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);

    fixture.ui.load_styles({ `{ "a": { "fill": "#ff0000ff" } }` })!!;
    fixture::expect_styles_fault(
        fixture:  &fixture,
        sheets:   { `{ "a": { "extends": "missing" } }` },
        expected: ui::UNKNOWN_STYLE,
        path:     "/0/a/extends",
    );
    assert(base_of(&fixture, "a").fill == fixture::srgb(0xff0000ff));
}

fn void test_style_reload_re_resolves_documents() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);

    fixture.ui.load_styles({ `{ "box": { "fill": "#ff0000ff", "size": [10, 10] } }` })!!;
    UiDocumentId document = fixture.ui.load_document(`{ "root": { "kind": "panel", "style": "box" } }`)!!;
    fixture::frame(&fixture);
    assert(first_fill(&fixture) == fixture::srgb(0xff0000ff));

    fixture.ui.load_styles({ `{ "box": { "fill": "#0000ffff", "size": [10, 10] } }` })!!;
    fixture::frame(&fixture);
    assert(first_fill(&fixture) == fixture::srgb(0x0000ffff));

    assert(@catch(fixture.ui.load_styles({ `{ "other": {} }` })) == ui::UNKNOWN_STYLE);
    assert(c3d::same_id(fixture.ui.load_error_document, document));
    assert(fixture.ui.load_error_path() == "/root/style");
    fixture::frame(&fixture);
    assert(first_fill(&fixture) == fixture::srgb(0x0000ffff));
}
