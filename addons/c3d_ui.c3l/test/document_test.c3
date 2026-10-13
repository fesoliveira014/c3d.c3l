module c3d::ui::document_test;

import c3d;
import c3d::ui @public;
import c3d::ui::fixture;
import std::encoding::json;

const String SPAN_SHEET @local = `{
  "text": { "font": ["ui/latin", "ui/cjk"], "font_size": 10 },
  "warn": { "text_color": "#ff0000ff", "underline": true },
  "big": { "font_size": 20 },
  "boxed": { "padding": 4 }
}`;

const String MARKUP_LABEL @local = `{ "root": { "kind": "label", "style": "text", "markup": true, "text": "%s" } }`;

const String TREE @local = `{
  "root": { "kind": "panel", "direction": "column", "children": [
    { "kind": "label", "style": "text", "text": "Squad" },
    { "kind": "list", "items": "{squad.members}", "template": {
        "kind": "button", "on_click": "squad.select", "children": [
          { "kind": "label", "style": "text", "text": "{member.name}" }
        ] } },
    { "kind": "bar", "value": 0.5, "size": [40, 4] }
  ] }
}`;

fn void test_document_builds_expected_tree() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    fixture::register_squad(&fixture);

    UiDocumentId document = fixture.ui.load_document(TREE)!!;
    UiElement[] elements = ui::ui_elements(&fixture.ui, document);
    assert(elements.len == 6);
    assert(elements[0].kind == PANEL && elements[0].parent == ui::UI_NONE && elements[0].first_child == 1);
    assert(elements[1].kind == LABEL && elements[1].parent == 0 && elements[1].next_sibling == 2);
    assert(elements[2].kind == LIST && elements[2].template == 3 && elements[2].first_child == ui::UI_NONE);
    assert(elements[2].next_sibling == 5);
    assert(elements[3].kind == BUTTON && elements[3].parent == 2 && elements[3].first_child == 4);
    assert(elements[4].kind == LABEL && elements[4].parent == 3);
    assert(elements[5].kind == BAR && elements[5].parent == 0 && elements[5].next_sibling == ui::UI_NONE);

    fixture::frame(&fixture);
    String[] lines = fixture::text_lines(&fixture);
    assert(lines.len == 4 && lines[0] == "Squad" && lines[1] == "Beep" && lines[2] == "Hob" && lines[3] == "Ruka");
}

fn void expect_markup_fault(Fixture* fixture, String text, fault expected) @local {
    fixture::expect_load_fault(
        fixture:  fixture,
        document: string::tformat(MARKUP_LABEL, text),
        expected: expected,
        path:     "/root/text",
    );
}

fn void expect_transition_fault(
    Fixture* fixture,
    String value,
    String pointer,
    fault expected = c3d::ASSET_FORMAT_ERROR,
) @local {
    fixture::expect_styles_fault(
        fixture:  fixture,
        sheets:   { string::tformat(`{ "t": { "transition": %s } }`, value) },
        expected: expected,
        path:     string::tformat("/0/t/transition/%s", pointer),
    );
}

fn String repeat_span(uint count) @local {
    String text = "";
    for (uint index = 0; index < count; index++) text = string::tformat("%s[warn]a[/warn]", text);

    return text;
}

fn void test_load_faults_report_json_pointers() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    fixture::register_squad(&fixture);

    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "panel", "children": [
                    { "kind": "label", "style": "text", "text": "a" }, { "kind": "slider" } ] } }`,
        expected: ui::UNKNOWN_ELEMENT_KIND,
        path:     "/root/children/1/kind",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "panel", "paddng": 4 } }`,
        expected: ui::UNKNOWN_PROPERTY,
        path:     "/root/paddng",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "panel", "children": [ { "kind": "label", "style": "titel", "text": "a" } ] } }`,
        expected: ui::UNKNOWN_STYLE,
        path:     "/root/children/0/style",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "panel", "children": [
            { "kind": "label", "style": "text", "text": "Hi {squad.missing}" } ] } }`,
        expected: ui::UNKNOWN_BINDING,
        path:     "/root/children/0/text",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "label", "style": "text", "text": "{member.name}" } }`,
        expected: ui::UNKNOWN_BINDING,
        path:     "/root/text",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "list", "items": "{squad.members}",
            "template": { "kind": "bar", "value": "{member.name}" } } }`,
        expected: ui::BINDING_KIND_MISMATCH,
        path:     "/root/template/value",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "button", "on_click": "squad.dance" } }`,
        expected: ui::UNKNOWN_ACTION,
        path:     "/root/on_click",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "image", "image": "icons/axe" } }`,
        expected: ui::UNKNOWN_ASSET,
        path:     "/root/image",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "label", "text": "a" } }`,
        expected: ui::UNKNOWN_ASSET,
        path:     "/root/font",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "panel", "fill": "#12345" } }`,
        expected: c3d::ASSET_FORMAT_ERROR,
        path:     "/root/fill",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "panel", "id": "log", "children": [
            { "kind": "panel", "id": "side" }, { "kind": "panel", "id": "log" } ] } }`,
        expected: c3d::ASSET_FORMAT_ERROR,
        path:     "/root/children/1/id",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "panel", "id": "Log" } }`,
        expected: c3d::ASSET_FORMAT_ERROR,
        path:     "/root/id",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "panel", "children": [
            { "kind": "panel", "id": "gv_u" }, { "kind": "panel", "id": "15xa" } ] } }`,
        expected: c3d::ASSET_FORMAT_ERROR,
        path:     "/root/children/1/id",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "panel", "children": [ { "kind": "panel", "window": true } ] } }`,
        expected: c3d::ASSET_FORMAT_ERROR,
        path:     "/root/children/0/window",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "panel", "children": [
            { "kind": "label", "style": "text", "id": "tool", "window": true, "text": "a" } ] } }`,
        expected: ui::UNKNOWN_PROPERTY,
        path:     "/root/children/0/window",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "list", "items": "{squad.members}", "template": { "kind": "panel", "children": [
            { "kind": "panel", "id": "tool", "window": true } ] } } }`,
        expected: c3d::ASSET_FORMAT_ERROR,
        path:     "/root/template/children/0/window",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "panel", "drag_handle": true } }`,
        expected: ui::UNKNOWN_PROPERTY,
        path:     "/root/drag_handle",
    );
    fixture::expect_styles_fault(
        fixture:  &fixture,
        sheets:   { `{ "title": { "font": ["ui/latin", "ui/gothic"] } }` },
        expected: ui::UNKNOWN_ASSET,
        path:     "/0/title/font/1",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "panel", "opacity": 1.5 } }`,
        expected: c3d::ASSET_FORMAT_ERROR,
        path:     "/root/opacity",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "panel", "offset": [4] } }`,
        expected: c3d::ASSET_FORMAT_ERROR,
        path:     "/root/offset",
    );
    expect_transition_fault(&fixture, `{ "properties": ["fill"] }`, "duration");
    expect_transition_fault(&fixture, `{ "properties": [], "duration": 1 }`, "properties");
    expect_transition_fault(&fixture, `{ "properties": ["fill_"], "duration": 1 }`, "properties/0");
    expect_transition_fault(&fixture, `{ "properties": ["fill", "size", "fill"], "duration": 1 }`, "properties/2");
    expect_transition_fault(&fixture, `{ "properties": ["fill"], "duration": -1 }`, "duration");
    expect_transition_fault(&fixture, `{ "properties": ["fill"], "duration": 1, "easing": "bounce" }`, "easing");
    expect_transition_fault(
        fixture:  &fixture,
        value:    `{ "properties": ["fill"], "duration": 1, "speed": 2 }`,
        pointer:  "speed",
        expected: ui::UNKNOWN_PROPERTY,
    );
}

fn void test_syntax_error_passes_the_parser_fault() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);

    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "panel",, } }`,
        expected: json::UNEXPECTED_CHARACTER,
        path:     "",
    );
}

fn void test_nesting_past_scope_depth_faults() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    fixture::register_squad(&fixture);

    String level = `{ "kind": "list", "items": "{squad.members}", "template": %s }`;
    String nested = `{ "kind": "panel" }`;
    for (uint depth = 0; depth < ui::UI_SCOPE_DEPTH + 1; depth++) nested = string::tformat(level, nested);
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: string::tformat(`{ "root": %s }`, nested),
        expected: c3d::CAPACITY_EXCEEDED,
        path:     "/root/template/template/template/template",
    );
}

fn void test_failed_reload_keeps_the_old_tree() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);

    String one = `{ "root": { "kind": "label", "style": "text", "text": "one" } }`;
    UiDocumentId document = fixture.ui.load_document(one)!!;
    fixture::frame(&fixture);
    assert(fixture::has_line(&fixture, "one"));

    String broken = `{ "root": { "kind": "label", "style": "text", "text": "{nope}" } }`;
    assert(@catch(fixture.ui.reload_document(document, broken)) == ui::UNKNOWN_BINDING);
    fixture::frame(&fixture);
    assert(fixture::has_line(&fixture, "one"));

    fixture.ui.reload_document(document, `{ "root": { "kind": "label", "style": "text", "text": "two" } }`)!!;
    fixture::frame(&fixture);
    assert(fixture::has_line(&fixture, "two") && !fixture::has_line(&fixture, "one"));
}

fn void test_markup_faults_report_json_pointers() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    fixture.ui.load_styles({ SPAN_SHEET })!!;

    expect_markup_fault(&fixture, "[warn]open", c3d::ASSET_FORMAT_ERROR);
    expect_markup_fault(&fixture, "[warn]a[/big]", c3d::ASSET_FORMAT_ERROR);
    expect_markup_fault(&fixture, "a[/warn]", c3d::ASSET_FORMAT_ERROR);
    expect_markup_fault(&fixture, "a [warn b", c3d::ASSET_FORMAT_ERROR);
    expect_markup_fault(&fixture, "a [] b", c3d::ASSET_FORMAT_ERROR);
    expect_markup_fault(&fixture, "[/]", c3d::ASSET_FORMAT_ERROR);
    expect_markup_fault(&fixture, "[{x}]a", c3d::ASSET_FORMAT_ERROR);
    expect_markup_fault(&fixture, "[warn][warn][warn][warn][warn]a", c3d::ASSET_FORMAT_ERROR);
    expect_markup_fault(&fixture, repeat_span(ui::UI_MAX_SPANS + 1), c3d::ASSET_FORMAT_ERROR);
    expect_markup_fault(&fixture, "[nope]a[/nope]", ui::UNKNOWN_STYLE);
    expect_markup_fault(&fixture, "[boxed]a[/boxed]", ui::UNKNOWN_PROPERTY);
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "panel", "markup": true } }`,
        expected: ui::UNKNOWN_PROPERTY,
        path:     "/root/markup",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "label", "style": "text", "markup": "yes", "text": "a" } }`,
        expected: c3d::ASSET_FORMAT_ERROR,
        path:     "/root/markup",
    );

    UiDocumentId document = fixture.ui.load_document(
        `{ "root": { "kind": "panel", "children": [
            { "kind": "label", "style": "text", "markup": true, "text": "[warn]x[/warn]" } ] } }`,
    )!!;
    fixture::expect_styles_fault(
        fixture:  &fixture,
        sheets:   { `{ "text": { "font": "ui/latin" }, "big": { "font_size": 20 } }` },
        expected: ui::UNKNOWN_STYLE,
        path:     "/root/children/0/text",
    );
    assert(c3d::same_id(fixture.ui.load_error_document, document));
    fixture::expect_styles_fault(
        fixture:  &fixture,
        sheets:   { `{ "text": { "font": "ui/latin" }, "warn": { "padding": 2 } }` },
        expected: ui::UNKNOWN_PROPERTY,
        path:     "/root/children/0/text",
    );
    assert(c3d::same_id(fixture.ui.load_error_document, document));

    fixture.ui.load_document(`{ "root": { "kind": "label", "style": "text", "text": "[nope] [[ ]" } }`)!!;
    fixture.ui.load_document(`{ "root": { "kind": "label", "style": "text", "markup": true, "text": "a [[b] c" } }`)!!;
    fixture.ui.load_document(string::tformat(MARKUP_LABEL, repeat_span(ui::UI_MAX_SPANS)))!!;
    fixture.ui.load_document(
        `{ "root": { "kind": "label", "style": "text", "markup": true,
            "text": "[warn][warn][warn][warn]a[/warn][/warn][/warn][/warn]" } }`,
    )!!;
    fixture::frame(&fixture);
    assert(fixture::has_line(&fixture, "[nope] [[ ]") && fixture::has_line(&fixture, "a [b] c"));
}
