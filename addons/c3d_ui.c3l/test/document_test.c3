module c3d::ui::document_test;

import c3d;
import c3d::ui @public;
import c3d::ui::fixture;
import std::encoding::json;

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
    fixture::expect_styles_fault(
        fixture:  &fixture,
        sheets:   { `{ "title": { "font": ["ui/latin", "ui/gothic"] } }` },
        expected: ui::UNKNOWN_ASSET,
        path:     "/0/title/font/1",
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
