module c3d::ui::input_test;

import c3d;
import c3d::platform;
import c3d::ui @public;
import c3d::ui::fixture;
import std::math;

const String BUTTONS @local = `{ "root": { "kind": "list", "items": "{squad.members}", "direction": "column",
    "template": { "kind": "button", "size": [100, 20], "enabled": "{member.alive}",
        "on_click": "squad.select", "on_secondary_click": "squad.select" } } }`;

const String GRIDS @local = `{ "root": { "kind": "panel", "direction": "column", "children": [
    { "kind": "grid", "items": "{stash.items}", "columns": 4, "rows": 1, "cell_size": [20, 20],
      "item_cell": "{stash_item.cell}", "item_span": ["{stash_item.width}", "{stash_item.height}"],
      "template": { "kind": "panel", "fill": "#808080ff" } },
    { "kind": "grid", "items": "{bag.items}", "columns": 4, "rows": 2, "cell_size": [20, 20],
      "item_cell": "{bag_item.cell}", "on_drop": "bag.drop",
      "template": { "kind": "panel", "fill": "#808080ff" } },
    { "kind": "button", "size": [40, 20], "on_drop": "bag.drop" }
] } }`;

const String SCROLLED @local = `{ "offset": [0, 100], "root": { "kind": "panel", "direction": "column", "children": [
    %s{ "kind": "scroll"%s, "size": [100, 40], "children": [
        { "kind": "list", "items": "{many.items}", "direction": "column",
          "template": { "kind": "panel", "fill": "#ffffffff", "size": [100, 20] } } ] } ] } }`;

const String FIELD @local = `{ "root": { "kind": "text_field", "style": "text", "size": [100, 20],
    "value": "{field.text}", "on_change": "field.change", "on_submit": "field.submit" } }`;

const String WINDOW @local = `{ "root": { "kind": "panel", "size": [200, 100], "padding": 10, "children": [
    { "kind": "panel", "id": "tool", "window": true, "position": [20, 20], "size": [60, 40], "fill": "#ffffffff",
      "drag_handle": true, "on_move_start": "tool.start", "on_move_end": "tool.end" } ] } }`;

const String WINDOW_AFTER_LABEL @local = `{ "root": { "kind": "panel", "size": [200, 100], "padding": 10, "children": [
    { "kind": "label", "style": "text", "text": "hi" },
    { "kind": "panel", "id": "tool", "window": true, "position": [20, 20], "size": [60, 40], "fill": "#ffffffff",
      "drag_handle": true, "on_move_start": "tool.start", "on_move_end": "tool.end" } ] } }`;

const String HIDEABLE_WINDOW @local = `{ "root": { "kind": "panel", "size": [200, 100], "children": [
    { "kind": "panel", "id": "tool", "window": true, "position": [20, 20], "size": [60, 40], "fill": "#ffffffff",
      "drag_handle": true, "visible": "{tool.shown}", "on_move_start": "tool.start", "on_move_end": "tool.end" } ] } }`;

const String BUTTON_ABOVE @local = `{ "layer": 1, "offset": [300, 0],
    "root": { "kind": "button", "size": [100, 100], "on_click": "other.click" } }`;

struct Many @local {
    uint count;
}

fn UiValue many_count(void* user, UiScope* scope) @local => { .kind = LIST, .count = ((Many*)user).count };

struct Item @local {
    int cell @tag("ui", true);
    int width @tag("ui", true);
    int height @tag("ui", true);
}

struct Field @local {
    String   text;
    Recorder change;
    Recorder submit;
}

fn UiValue field_text(void* user, UiScope* scope) @local => { .kind = TEXT, .text = ((Field*)user).text };

struct WindowRecorders @local {
    Recorder start;
    Recorder finish;
    Recorder other;
}

fn UiValue tool_shown(void* user, UiScope* scope) @local => { .kind = BOOL, .boolean = *(bool*)user };

fn void register_window_actions(Fixture* fixture, WindowRecorders* recorders) @local {
    fixture.ui.on("tool.start", &fixture::record_action, &recorders.start)!!;
    fixture.ui.on("tool.end", &fixture::record_action, &recorders.finish)!!;
    fixture.ui.on("other.click", &fixture::record_action, &recorders.other)!!;
}

fn void drag_to(
    Fixture* fixture,
    Vec2 from,
    Vec2 to,
    float scale = 1,
) @local {
    fixture::point(fixture, from, held: true);
    fixture::frame(fixture, { fixture::button_down(from) }, scale: scale);
    fixture::point(fixture, to, held: true);
    fixture::frame(fixture, { fixture::motion(to) }, scale: scale);
    fixture::point(fixture, to);
    fixture::frame(fixture, { fixture::button_up(to) }, scale: scale);
}

fn String scrolled_document(bool spacer, bool named) @local {
    return string::tformat(
        SCROLLED,
        spacer ? `{ "kind": "panel", "size": [100, 10] },` : "",
        named ? `, "id": "log"` : "",
    );
}

fn void load_buttons(Fixture* fixture) @local {
    fixture::register_squad(fixture);
    fixture.ui.load_document(BUTTONS)!!;
    fixture::frame(fixture);
}

fn void test_click_fires_the_action_with_its_scope() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    fixture.members[1].alive = true;
    load_buttons(&fixture);

    fixture::click(&fixture, { 50, 30 });
    assert(fixture.recorder.calls == 1 && fixture.recorder.kind == CLICK);
    assert(fixture.recorder.scope.depth == 1 && fixture.recorder.scope.indices[0] == 1);

    fixture::click(&fixture, { 50, 50 }, RIGHT);
    assert(fixture.recorder.calls == 2 && fixture.recorder.kind == SECONDARY_CLICK);
    assert(fixture.recorder.scope.indices[0] == 2);

    fixture::click(&fixture, { 300, 300 });
    assert(fixture.recorder.calls == 2);
}

fn void test_disabled_elements_fire_nothing() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    load_buttons(&fixture);

    fixture::click(&fixture, { 50, 30 });
    assert(fixture.recorder.calls == 0);
    fixture::click(&fixture, { 50, 10 });
    assert(fixture.recorder.calls == 1 && fixture.recorder.scope.indices[0] == 0);
}

fn void test_capture_flags_combine_and_never_clear() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    load_buttons(&fixture);

    fixture.gui_keyboard = true;
    fixture.gui_text_input = true;
    fixture::point(&fixture, { 50, 10 });
    fixture::frame(&fixture);
    assert(fixture.input.mouse_captured_by_gui);
    assert(fixture.input.keyboard_captured_by_gui && fixture.input.text_input_wanted_by_gui);

    fixture::point(&fixture, { 500, 500 });
    fixture::frame(&fixture);
    assert(!fixture.input.mouse_captured_by_gui);
    assert(fixture.input.keyboard_captured_by_gui && fixture.input.text_input_wanted_by_gui);
}

fn void test_imgui_capture_blocks_the_pointer() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    load_buttons(&fixture);

    fixture.gui_mouse = true;
    fixture::click(&fixture, { 50, 10 });
    assert(fixture.recorder.calls == 0 && fixture.input.mouse_captured_by_gui);

    fixture.gui_mouse = false;
    fixture::click(&fixture, { 50, 10 });
    assert(fixture.recorder.calls == 1);
}

fn void test_upper_layer_takes_the_click() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    Recorder lower;
    Recorder upper;
    fixture.ui.on("a.click", &fixture::record_action, &lower)!!;
    fixture.ui.on("b.click", &fixture::record_action, &upper)!!;
    fixture.ui.load_document(`{ "layer": 1, "root": { "kind": "button", "size": [50, 50], "on_click": "b.click" } }`)!!;
    fixture.ui.load_document(`{ "root": { "kind": "button", "size": [200, 200], "on_click": "a.click" } }`)!!;
    fixture::frame(&fixture);

    fixture::click(&fixture, { 10, 10 });
    assert(upper.calls == 1 && lower.calls == 0);
    fixture::click(&fixture, { 100, 100 });
    assert(upper.calls == 1 && lower.calls == 1);
}

fn void test_field_focus_edit_change_and_submit() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    Field field = { .text = "ab" };
    fixture.ui.bind(
        name:   "field.text",
        kind:   TEXT,
        getter: &field_text,
        user:   &field,
    )!!;
    fixture.ui.on("field.change", &fixture::record_action, &field.change)!!;
    fixture.ui.on("field.submit", &fixture::record_action, &field.submit)!!;
    fixture.ui.load_document(FIELD)!!;
    fixture::frame(&fixture);

    fixture::click(&fixture, { 10, 10 });
    assert(fixture.ui.wants_text_input);
    assert(fixture.input.keyboard_captured_by_gui && fixture.input.text_input_wanted_by_gui);

    fixture::frame(&fixture, { fixture::typed("c") });
    assert(field.change.calls == 1 && field.change.kind == CHANGE && field.change.text() == "abc");
    fixture::frame(&fixture, { fixture::key(Scancode.LEFT), fixture::key(Scancode.BACKSPACE), fixture::typed("€") });
    assert(field.change.text() == "a€c");
    assert(fixture::has_line(&fixture, "a€c"));

    fixture::frame(&fixture, { fixture::key(Scancode.RETURN) });
    assert(field.submit.calls == 1 && field.submit.kind == SUBMIT && field.submit.text() == "a€c");
    assert(!fixture.ui.wants_text_input);
    fixture::frame(&fixture);
    assert(fixture::has_line(&fixture, "ab"));
}

fn void test_edits_of_a_full_field_stay_in_bounds() @test {
    UiDesc desc = ui::default_ui_desc();
    desc.field_bytes = 8;
    Fixture fixture;
    fixture::create_fixture(&fixture, desc);
    defer fixture::destroy_fixture(&fixture);
    Field field = { .text = "abcdefgh" };
    fixture.ui.bind(
        name:   "field.text",
        kind:   TEXT,
        getter: &field_text,
        user:   &field,
    )!!;
    fixture.ui.on("field.change", &fixture::record_action, &field.change)!!;
    fixture.ui.on("field.submit", &fixture::record_action, &field.submit)!!;
    fixture.ui.load_document(FIELD)!!;
    fixture::frame(&fixture);

    fixture::click(&fixture, { 10, 10 });
    fixture::frame(&fixture, { fixture::key(Scancode.BACKSPACE) });
    assert(field.change.text() == "abcdefg");
    fixture::frame(&fixture, { fixture::typed("h") });
    assert(field.change.text() == "abcdefgh");
    fixture::frame(&fixture, { fixture::typed("i") });
    assert(field.change.calls == 2);
    fixture::frame(&fixture, { fixture::key(Scancode.HOME), fixture::key(Scancode.DELETE) });
    assert(field.change.text() == "bcdefgh");
}

fn void test_escape_blurs_without_submit() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    Field field = { .text = "ab" };
    fixture.ui.bind(
        name:   "field.text",
        kind:   TEXT,
        getter: &field_text,
        user:   &field,
    )!!;
    fixture.ui.on("field.change", &fixture::record_action, &field.change)!!;
    fixture.ui.on("field.submit", &fixture::record_action, &field.submit)!!;
    fixture.ui.load_document(FIELD)!!;
    fixture::frame(&fixture);

    fixture::click(&fixture, { 10, 10 });
    fixture::frame(&fixture, { fixture::typed("x"), fixture::key(Scancode.ESCAPE) });
    assert(field.change.calls == 1 && field.submit.calls == 0);
    assert(!fixture.ui.wants_text_input);
    fixture::frame(&fixture);
    assert(fixture::has_line(&fixture, "ab") && !fixture::has_line(&fixture, "abx"));
}

fn void test_wheel_scrolls_the_hovered_scroll_area() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    Many many = { .count = 10 };
    fixture.ui.bind(
        name:   "many.items",
        kind:   LIST,
        getter: &many_count,
        user:   &many,
    )!!;
    fixture.ui.load_document(`{ "offset": [0, 100], "root": { "kind": "scroll", "size": [100, 40], "children": [
        { "kind": "list", "items": "{many.items}", "direction": "column",
          "template": { "kind": "panel", "fill": "#ffffffff", "size": [100, 20] } } ] } }`)!!;
    fixture::frame(&fixture);
    assert(fixture.list.entries[0].rect.min.y == 100);

    fixture::point(&fixture, { 50, 120 });
    fixture.wheel = -1;
    fixture::frame(&fixture);
    fixture.wheel = 0;
    assert(fixture.list.entries[0].rect.min.y == 60, "one notch scrolls 40 layout units");

    fixture::point(&fixture, { 300, 300 });
    fixture.wheel = -1;
    fixture::frame(&fixture);
    assert(fixture.list.entries[0].rect.min.y == 60, "the wheel scrolls only the hovered area");
}

fn void test_scroll_offset_survives_reload_by_id() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    Many many = { .count = 10 };
    fixture.ui.bind(
        name:   "many.items",
        kind:   LIST,
        getter: &many_count,
        user:   &many,
    )!!;
    UiDocumentId document = fixture.ui.load_document(scrolled_document(spacer: false, named: true))!!;
    fixture::frame(&fixture);

    fixture::point(&fixture, { 50, 120 });
    fixture.wheel = -1;
    fixture::frame(&fixture);
    fixture.wheel = 0;
    assert(fixture.list.entries[0].rect.min.y == 60, "one notch scrolls 40 layout units");

    fixture.ui.reload_document(document, scrolled_document(spacer: true, named: true))!!;
    fixture::frame(&fixture);
    assert(fixture.list.entries[0].rect.min.y == 70, "the scroll keeps its offset below the inserted panel");

    fixture.ui.reload_document(document, scrolled_document(spacer: true, named: false))!!;
    fixture::frame(&fixture);
    assert(fixture.list.entries[0].rect.min.y == 110, "a scroll without an id starts at the top");
}

fn void test_drag_cancels_when_its_item_disappears() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    Item[2] stash_items = { { .cell = 0, .width = 1, .height = 1 }, { .cell = 2, .width = 1, .height = 1 } };
    Item[] stash = stash_items[..];
    Item[] bag;
    fixture.ui.@bind_list(name: "stash.items", item: "stash_item", $Type: Item, items: &stash)!!;
    fixture.ui.@bind_list(name: "bag.items", item: "bag_item", $Type: Item, items: &bag)!!;
    fixture.ui.on("bag.drop", &fixture::record_action, &fixture.recorder)!!;
    fixture.ui.load_document(GRIDS)!!;
    fixture::frame(&fixture);

    fixture::point(&fixture, { 50, 10 }, held: true);
    fixture::frame(&fixture, { fixture::button_down({ 50, 10 }) });
    fixture::point(&fixture, { 30, 50 }, held: true);
    fixture::frame(&fixture, { fixture::motion({ 30, 50 }) });
    stash = stash_items[:1];
    fixture::frame(&fixture, { fixture::button_down({ 30, 50 }, RIGHT), fixture::button_up({ 30, 50 }, RIGHT) });
    fixture::point(&fixture, { 30, 50 });
    fixture::frame(&fixture, { fixture::button_up({ 30, 50 }) });
    assert(fixture.recorder.calls == 0);
}

fn void test_hovering_an_empty_cell_shows_no_item_tooltip() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    Item[1] stash_items = { { .cell = 2, .width = 1, .height = 1 } };
    Item[] stash = stash_items[..];
    fixture.ui.@bind_list(name: "stash.items", item: "stash_item", $Type: Item, items: &stash)!!;
    fixture.ui.on("bag.drop", &fixture::record_action, &fixture.recorder)!!;
    fixture.ui.load_document(`{ "root": { "kind": "grid", "items": "{stash.items}", "columns": 4, "rows": 1,
        "cell_size": [20, 20], "item_cell": "{stash_item.cell}", "on_drop": "bag.drop",
        "template": { "kind": "panel", "fill": "#808080ff", "children": [
            { "kind": "tooltip", "children": [ { "kind": "label", "style": "text", "text": "tip" } ] } ] } } }`)!!;
    fixture::frame(&fixture);

    fixture::point(&fixture, { 10, 10 });
    fixture::frame(&fixture);
    assert(!fixture::has_line(&fixture, "tip"));
    fixture::point(&fixture, { 50, 10 });
    fixture::frame(&fixture);
    assert(fixture::has_line(&fixture, "tip"));
}

fn void test_drop_reports_source_scope_list_and_cell() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    Item[2] stash_items = { { .cell = 0, .width = 1, .height = 1 }, { .cell = 2, .width = 1, .height = 1 } };
    Item[] stash = stash_items[..];
    Item[] bag;
    fixture.ui.@bind_list(
        name:  "stash.items",
        item:  "stash_item",
        $Type: Item,
        items: &stash,
    )!!;
    fixture.ui.@bind_list(
        name:  "bag.items",
        item:  "bag_item",
        $Type: Item,
        items: &bag,
    )!!;
    fixture.ui.on("bag.drop", &fixture::record_action, &fixture.recorder)!!;
    fixture.ui.load_document(GRIDS)!!;
    fixture::frame(&fixture);

    fixture::point(&fixture, { 50, 10 }, held: true);
    fixture::frame(&fixture, { fixture::button_down({ 50, 10 }) });
    fixture::point(&fixture, { 30, 50 }, held: true);
    fixture::frame(&fixture, { fixture::motion({ 30, 50 }) });
    fixture::point(&fixture, { 30, 50 });
    fixture::frame(&fixture, { fixture::button_up({ 30, 50 }) });

    assert(fixture.recorder.calls == 1 && fixture.recorder.kind == DROP);
    assert(fixture.recorder.source.depth == 1 && fixture.recorder.source.indices[0] == 1);
    assert(fixture.recorder.source_list == "stash.items");
    assert(fixture.recorder.cell == 5);
    assert(fixture.recorder.scope.depth == 0);

    fixture::point(&fixture, { 10, 10 }, held: true);
    fixture::frame(&fixture, { fixture::button_down({ 10, 10 }) });
    fixture::point(&fixture, { 20, 70 }, held: true);
    fixture::frame(&fixture, { fixture::motion({ 20, 70 }) });
    fixture::point(&fixture, { 20, 70 });
    fixture::frame(&fixture, { fixture::button_up({ 20, 70 }) });
    assert(fixture.recorder.calls == 2 && fixture.recorder.source.indices[0] == 0);
    assert(fixture.recorder.cell == ui::UI_NO_CELL);
}

fn void test_window_drag_holds_capture_over_controls() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    WindowRecorders recorders;
    register_window_actions(&fixture, &recorders);
    UiDocumentId window = fixture.ui.load_document(WINDOW)!!;
    fixture.ui.load_document(BUTTON_ABOVE)!!;
    fixture::frame(&fixture);

    fixture::point(&fixture, { 50, 40 }, held: true);
    fixture::frame(&fixture, { fixture::button_down({ 50, 40 }) });
    fixture::point(&fixture, { 90, 40 }, held: true);
    fixture::frame(&fixture, { fixture::motion({ 90, 40 }) });
    assert(recorders.start.calls == 1 && recorders.start.offset == (Vec2){ 20, 20 });
    assert(fixture.ui.window_offset(window, "tool")!! == (Vec2){ 60, 20 });

    fixture.gui_mouse = true;
    fixture::point(&fixture, { 350, 50 }, held: true);
    fixture::frame(&fixture, { fixture::motion({ 350, 50 }) });
    fixture.gui_mouse = false;
    assert(fixture.input.mouse_captured_by_gui && fixture.input.keyboard_captured_by_gui);
    assert(fixture.ui.window_offset(window, "tool")!! == (Vec2){ 130, 30 }, "the offset stays inside the parent");

    fixture::frame(&fixture);
    assert(!ui::key_valid(&fixture.ui.hover) && !ui::key_valid(&fixture.ui.press));
    fixture::point(&fixture, { 350, 50 });
    fixture::frame(&fixture, { fixture::button_up({ 350, 50 }) });
    assert(recorders.finish.calls == 1 && recorders.finish.offset == (Vec2){ 130, 30 });
    assert(recorders.other.calls == 0 && recorders.start.calls == 1);

    fixture::click(&fixture, { 350, 50 });
    assert(recorders.other.calls == 1, "the button works again after the drag");
}

fn void test_window_drag_clamps_to_parent_bounds() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    WindowRecorders recorders;
    register_window_actions(&fixture, &recorders);
    UiDocumentId window = fixture.ui.load_document(WINDOW)!!;
    fixture::frame(&fixture, scale: 2);

    drag_to(&fixture, { 100, 80 }, { 2000, 2000 }, scale: 2);
    assert(fixture.ui.window_offset(window, "tool")!! == (Vec2){ 130, 50 }, "right and bottom edges keep the padding");
    assert(recorders.finish.calls == 1 && recorders.finish.offset == (Vec2){ 130, 50 });

    drag_to(&fixture, { 320, 140 }, { -2000, -2000 }, scale: 2);
    assert(fixture.ui.window_offset(window, "tool")!! == (Vec2){ 10, 10 }, "left and top edges keep the padding");
    assert(recorders.finish.calls == 2);
}

fn void test_window_drag_cancels_when_window_disappears() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    WindowRecorders recorders;
    register_window_actions(&fixture, &recorders);
    bool shown = true;
    fixture.ui.bind(
        name:   "tool.shown",
        kind:   BOOL,
        getter: &tool_shown,
        user:   &shown,
    )!!;
    UiDocumentId window = fixture.ui.load_document(HIDEABLE_WINDOW)!!;
    fixture::frame(&fixture);

    fixture::point(&fixture, { 50, 40 }, held: true);
    fixture::frame(&fixture, { fixture::button_down({ 50, 40 }) });
    fixture::point(&fixture, { 90, 40 }, held: true);
    fixture::frame(&fixture, { fixture::motion({ 90, 40 }) });
    assert(fixture.ui.window_offset(window, "tool")!! == (Vec2){ 60, 20 });

    shown = false;
    fixture::frame(&fixture);
    assert(fixture.ui.window_offset(window, "tool")!! == (Vec2){ 20, 20 }, "the offset returns to the start");

    shown = true;
    fixture::point(&fixture, { 90, 40 });
    fixture::frame(&fixture, { fixture::button_up({ 90, 40 }) });
    assert(recorders.start.calls == 1 && recorders.finish.calls == 0);
    assert(fixture.ui.window_offset(window, "tool")!! == (Vec2){ 20, 20 });
}

fn void test_window_drag_continues_across_reload_by_id() @test {
    Fixture fixture;
    fixture::create_fixture(&fixture);
    defer fixture::destroy_fixture(&fixture);
    WindowRecorders recorders;
    register_window_actions(&fixture, &recorders);
    UiDocumentId window = fixture.ui.load_document(WINDOW)!!;
    fixture::frame(&fixture);

    fixture::point(&fixture, { 50, 40 }, held: true);
    fixture::frame(&fixture, { fixture::button_down({ 50, 40 }) });
    fixture::point(&fixture, { 90, 40 }, held: true);
    fixture::frame(&fixture, { fixture::motion({ 90, 40 }) });

    fixture.ui.reload_document(window, WINDOW_AFTER_LABEL)!!;
    fixture::frame(&fixture);
    assert(fixture.ui.window_offset(window, "tool")!! == (Vec2){ 60, 20 }, "the offset is kept by id");
    assert(recorders.start.calls == 1);

    fixture::point(&fixture, { 130, 40 }, held: true);
    fixture::frame(&fixture, { fixture::motion({ 130, 40 }) });
    assert(fixture.ui.window_offset(window, "tool")!! == (Vec2){ 100, 20 }, "the drag continues from its press");

    fixture.ui.reload_document(window, WINDOW)!!;
    fixture.input.begin_frame();
    fixture.ui.route_input(&fixture.input, { fixture::button_up({ 130, 40 }) });
    assert(recorders.finish.calls == 1 && recorders.finish.offset == (Vec2){ 100, 20 });
    assert(fixture.input.mouse_captured_by_gui, "the release is handled before the first update");
}
