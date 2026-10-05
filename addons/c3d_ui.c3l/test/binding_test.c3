module c3d::ui::binding_test;

import c3d;
import c3d::ui @public;
import c3d::ui::fixture;

const String COUNTED_LABEL @local = `{ "root": { "kind": "label", "style": "text", "text": "{count.value}" } }`;

struct Cargo @local {
    int   gold @tag("ui", "coins");
    float weight @tag("ui", true);
    int   hidden;
}

struct Foreign @local {
    int   gold;
    float weight;
}

struct Counter @local {
    uint value_calls;
    uint flag_calls;
}

struct Nest @local {
    UiScope cells_scope;
    UiScope name_scope;
    UiScope label_scope;
}

struct Values @local {
    long   integer;
    double number;
    double whole;
    bool   flag;
    String text;
}

fn fault bind_fault(Ui* ui, String name, String list = "") @local {
    return @catch(ui.bind(
        name:   name,
        kind:   INT,
        getter: &counted_value,
        user:   null,
        list:   list,
    ));
}

fn UiValue counted_value(void* user, UiScope* scope) @local {
    ((Counter*)user).value_calls++;
    return { .kind = INT, .integer = 7 };
}

fn UiValue counted_flag(void* user, UiScope* scope) @local {
    ((Counter*)user).flag_calls++;
    return { .kind = BOOL, .boolean = false };
}

fn UiValue rows_count(void* user, UiScope* scope) @local => { .kind = LIST, .count = 2 };

fn UiValue row_cells(void* user, UiScope* scope) @local {
    ((Nest*)user).cells_scope = *scope;
    return { .kind = LIST, .count = 3 };
}

fn UiValue row_name(void* user, UiScope* scope) @local {
    ((Nest*)user).name_scope = *scope;
    return { .kind = TEXT, .text = "row" };
}

fn UiValue cell_label(void* user, UiScope* scope) @local {
    ((Nest*)user).label_scope = *scope;
    return { .kind = TEXT, .text = string::tformat("r%dc%d", scope.indices[0], scope.indices[1]) };
}

fn UiValue values_integer(void* user, UiScope* scope) @local => { .kind = INT, .integer = ((Values*)user).integer };
fn UiValue values_number(void* user, UiScope* scope) @local => { .kind = FLOAT, .number = ((Values*)user).number };
fn UiValue values_whole(void* user, UiScope* scope) @local => { .kind = FLOAT, .number = ((Values*)user).whole };
fn UiValue values_flag(void* user, UiScope* scope) @local => { .kind = BOOL, .boolean = ((Values*)user).flag };
fn UiValue values_text(void* user, UiScope* scope) @local => { .kind = TEXT, .text = ((Values*)user).text };

fn void test_tags_expose_fields_under_document_names() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    Cargo cargo = { .gold = 12, .weight = 1.5, .hidden = 3 };
    fixture.ui.@bind_fields("cargo", Cargo, &cargo)!!;

    fixture.ui.load_document(`{ "root": {
        "kind": "label", "style": "text", "text": "{cargo.coins}/{cargo.weight}" } }`)!!;
    fixture::frame(&fixture);
    assert(fixture::has_line(&fixture, "12/1.5"));
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "label", "style": "text", "text": "{cargo.hidden}" } }`,
        expected: ui::UNKNOWN_BINDING,
        path:     "/root/text",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "label", "style": "text", "text": "{cargo.gold}" } }`,
        expected: ui::UNKNOWN_BINDING,
        path:     "/root/text",
    );
}

fn void test_name_list_exposes_foreign_fields() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    Foreign foreign = { .gold = 40, .weight = 2 };
    fixture.ui.@bind_fields(
        prefix:   "trade",
        $Type:    Foreign,
        instance: &foreign,
        $fields:  { "gold" },
    )!!;

    fixture.ui.load_document(`{ "root": { "kind": "label", "style": "text", "text": "{trade.gold}" } }`)!!;
    fixture::frame(&fixture);
    assert(fixture::has_line(&fixture, "40"));
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "label", "style": "text", "text": "{trade.weight}" } }`,
        expected: ui::UNKNOWN_BINDING,
        path:     "/root/text",
    );
}

fn void test_registration_rejects_bad_and_duplicate_names() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);

    assert(bind_fault(&fixture.ui, "Squad") == c3d::INVALID_ARGUMENT);
    assert(bind_fault(&fixture.ui, "a..b") == c3d::INVALID_ARGUMENT);
    assert(bind_fault(&fixture.ui, "") == c3d::INVALID_ARGUMENT);
    assert(!bind_fault(&fixture.ui, "a.b"));
    assert(bind_fault(&fixture.ui, "a.b") == c3d::INVALID_ARGUMENT);
    assert(bind_fault(&fixture.ui, "a.c", list: "nope") == c3d::INVALID_ARGUMENT);
    assert(bind_fault(&fixture.ui, "a.d", list: "a.b") == c3d::INVALID_ARGUMENT);
    assert(@catch(fixture.ui.on("Bad Name", &fixture::record_action, &fixture.recorder)) == c3d::INVALID_ARGUMENT);
}

fn void test_getters_run_only_for_declared_elements() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    Counter counter;
    fixture.ui.bind(
        name:   "count.value",
        kind:   INT,
        getter: &counted_value,
        user:   &counter,
    )!!;
    fixture.ui.bind(
        name:   "flag.off",
        kind:   BOOL,
        getter: &counted_flag,
        user:   &counter,
    )!!;

    fixture.ui.load_document(COUNTED_LABEL)!!;
    UiDocumentId hidden = fixture.ui.load_document(COUNTED_LABEL)!!;
    fixture.ui.set_visible(hidden, false)!!;
    fixture.ui.load_document(`{ "root": { "kind": "panel", "visible": false, "children": [
        { "kind": "label", "style": "text", "text": "{count.value}" } ] } }`)!!;
    fixture.ui.load_document(`{ "root": { "kind": "panel", "visible": "{flag.off}", "children": [
        { "kind": "label", "style": "text", "text": "{count.value}" } ] } }`)!!;

    fixture::frame(&fixture);
    assert(counter.value_calls == 1, "value getter ran %d times", counter.value_calls);
    assert(counter.flag_calls == 1);
    assert(fixture.ui.stats.getter_calls == 2);
}

fn void test_nested_lists_truncate_scopes() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    Nest nest;
    fixture.ui.bind(
        name:   "rows",
        kind:   LIST,
        getter: &rows_count,
        user:   &nest,
    )!!;
    fixture.ui.bind(
        name:   "row.cells",
        kind:   LIST,
        getter: &row_cells,
        user:   &nest,
        list:   "rows",
    )!!;
    fixture.ui.bind(
        name:   "row.name",
        kind:   TEXT,
        getter: &row_name,
        user:   &nest,
        list:   "rows",
    )!!;
    fixture.ui.bind(
        name:   "cell.label",
        kind:   TEXT,
        getter: &cell_label,
        user:   &nest,
        list:   "row.cells",
    )!!;

    fixture.ui.load_document(`{ "root": { "kind": "list", "items": "{rows}", "template": {
        "kind": "list", "items": "{row.cells}", "template": {
            "kind": "label", "style": "text", "text": "{row.name}:{cell.label}" } } } }`)!!;
    fixture::frame(&fixture);

    String[] lines = fixture::text_lines(&fixture);
    assert(lines.len == 6 && lines[0] == "row:r0c0" && lines[2] == "row:r0c2" && lines[5] == "row:r1c2");
    assert(nest.cells_scope.depth == 1 && nest.cells_scope.indices[0] == 1);
    assert(nest.name_scope.depth == 1 && nest.name_scope.indices[0] == 1);
    assert(nest.label_scope.depth == 2 && nest.label_scope.indices[0] == 1 && nest.label_scope.indices[1] == 2);
}

fn void test_templates_format_values() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    Values values = { .integer = 12, .number = 1.5, .whole = 2, .flag = true, .text = "x" };
    fixture.ui.bind(
        name:   "v.integer",
        kind:   INT,
        getter: &values_integer,
        user:   &values,
    )!!;
    fixture.ui.bind(
        name:   "v.number",
        kind:   FLOAT,
        getter: &values_number,
        user:   &values,
    )!!;
    fixture.ui.bind(
        name:   "v.whole",
        kind:   FLOAT,
        getter: &values_whole,
        user:   &values,
    )!!;
    fixture.ui.bind(
        name:   "v.flag",
        kind:   BOOL,
        getter: &values_flag,
        user:   &values,
    )!!;
    fixture.ui.bind(
        name:   "v.text",
        kind:   TEXT,
        getter: &values_text,
        user:   &values,
    )!!;

    fixture.ui.load_document(`{ "root": { "kind": "label", "style": "text",
        "text": "{v.integer}|{v.number}|{v.whole}|{v.number:3}|{v.flag}|{v.text}|{{}}|{v.integer:2}" } }`)!!;
    fixture::frame(&fixture);
    assert(fixture::has_line(&fixture, "12|1.5|2|1.500|true|x|{}|12.00"));

    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "label", "style": "text", "text": "{v.number:7}" } }`,
        expected: c3d::ASSET_FORMAT_ERROR,
        path:     "/root/text",
    );
    fixture::expect_load_fault(
        fixture:  &fixture,
        document: `{ "root": { "kind": "label", "style": "text", "text": "{v.number" } }`,
        expected: c3d::ASSET_FORMAT_ERROR,
        path:     "/root/text",
    );
}
