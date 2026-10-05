module c3d::ui;

import c3d;
import c3d::platform;
import clay;
import std::math;

<*
 Route pointer, wheel, keys and text against the previous layout; fire actions.
 ORs the GUI capture and text input flags; never clears them.
 @param [&inout] input : "Polled this frame, after the ImGui frame began."
 @param events : "The window's events of this frame."
*>
fn void Ui.route_input(&self, Input* input, Event[] events) {
    if (self.frame_ready) route_pointer(self, input, events);
    if (key_valid(&self.focus)) {
        foreach (&event : events) route_key(self, event);
    }
    if (key_valid(&self.focus)) {
        input.keyboard_captured_by_gui = true;
        input.text_input_wanted_by_gui = true;
    }
    self.wants_text_input = key_valid(&self.focus);
}

fn void route_pointer(Ui* ui, Input* input, Event[] events) @private {
    clay::set_current_context(ui.context);
    bool blocked = input.mouse_captured_by_gui;
    Vec2 pointer = input.mouse_position / ui.scale;
    ui.pointer = pointer;
    clay::set_pointer_state(
        blocked ? (clay::Vector2){ -float::max, -float::max } : (clay::Vector2){ pointer.x, pointer.y },
        !blocked && input.mouse_buttons[(usz)MouseButton.LEFT],
    );
    clay::ElementId[] over = clay::get_pointer_over_ids().ids();

    uint hover = UI_NONE;
    bool over_ui;
    ui.tooltip_host_count = 0;
    foreach (element_id : over) {
        uint index = lookup_instance(ui, element_id.id);
        if (index == UI_NONE || !ui.instances[index].hit) continue;
        over_ui = true;
        if (ui.instances[index].interactive) hover = index;
        if (ui.instances[index].element.has_tooltip && ui.tooltip_host_count < UI_TOOLTIP_HOSTS) {
            ui.tooltip_hosts[ui.tooltip_host_count] = ui.instances[index].key;
            ui.tooltip_host_count++;
        }
    }
    ui.hover = hover == UI_NONE ? (UiElementKey){} : ui.instances[hover].key;

    foreach (&event : events) {
        switch (event.kind) {
            case MOUSE_BUTTON_DOWN:
                press(
                    ui:      ui,
                    button:  event.button,
                    blocked: blocked,
                    hover:   hover,
                    pointer: pointer,
                );
            case MOUSE_MOTION:
                if (ui.drag.candidate && !ui.drag.active && input.mouse_buttons[(usz)MouseButton.LEFT]) {
                    Vec2 travel = event.position / ui.scale - ui.drag.origin;
                    if (travel.length() > UI_DRAG_THRESHOLD) ui.drag.active = true;
                }
            case MOUSE_BUTTON_UP:
                release(
                    ui:      ui,
                    button:  event.button,
                    hover:   hover,
                    over:    over,
                    pointer: pointer,
                );
            default:
                break;
        }
    }
    if (ui.drag.active) track_drop_target(ui, over, pointer);
    clay::update_scroll_containers(false, { 0, blocked ? 0 : input.wheel * UI_WHEEL_STEP }, 0);

    if (!blocked && (over_ui || key_valid(&ui.press) || ui.drag.active)) input.mouse_captured_by_gui = true;
}

fn void press(
    Ui* ui,
    MouseButton button,
    bool blocked,
    uint hover,
    Vec2 pointer,
) @private {
    if (button != LEFT && button != RIGHT) return;
    if (ui.drag.active) return;
    UiInstance* target = hover == UI_NONE || blocked ? null : &ui.instances[hover];
    if (!target || !same_key(&target.key, &ui.focus)) ui.focus = {};
    if (!target) return;

    ui.press = target.key;
    ui.press_button = button;
    if (!target.enabled || button != LEFT) return;
    if (target.element.kind == TEXT_FIELD) {
        focus_field(ui, target);
        return;
    }
    if (target.list == UI_NONE) return;
    clay::BoundingBox box = clay::get_element_data(clay::id(target.clay_id)).bounding_box;
    ui.drag = {
        .candidate   = true,
        .source      = target.key,
        .list        = target.list,
        .span_width  = target.span_width,
        .span_height = target.span_height,
        .size        = { box.width, box.height },
        .origin      = pointer,
        .grab        = { pointer.x - box.x, pointer.y - box.y },
        .cell        = UI_NO_CELL,
    };
}

fn void release(
    Ui* ui,
    MouseButton button,
    uint hover,
    clay::ElementId[] over,
    Vec2 pointer,
) @private {
    if (button != LEFT && button != RIGHT) return;
    if (button == LEFT && ui.drag.active) {
        track_drop_target(ui, over, pointer);
        UiDrag drag = ui.drag;
        ui.drag = {};
        ui.press = {};
        if (!key_valid(&drag.target)) return;
        UiEvent event = {
            .kind        = DROP,
            .source      = drag.source.scope,
            .source_list = ui.bindings[drag.list].name,
            .cell        = drag.cell,
        };
        fire_action(
            ui:    ui,
            key:   &drag.target,
            kind:  DROP,
            event: &event,
        );
        return;
    }
    if (button == LEFT) ui.drag = {};
    bool clicked = key_valid(&ui.press) && ui.press_button == button && hover != UI_NONE;
    UiElementKey pressed = ui.press;
    ui.press = {};
    if (!clicked || !same_key(&pressed, &ui.instances[hover].key) || !ui.instances[hover].enabled) return;
    UiEventKind kind = button == LEFT ? UiEventKind.CLICK : UiEventKind.SECONDARY_CLICK;
    UiEvent event = { .kind = kind, .cell = UI_NO_CELL };
    fire_action(
        ui:    ui,
        key:   &pressed,
        kind:  kind,
        event: &event,
    );
}

fn void track_drop_target(Ui* ui, clay::ElementId[] over, Vec2 pointer) @private {
    ui.drag.target = {};
    ui.drag.cell = UI_NO_CELL;
    for (usz position = over.len; position > 0; position--) {
        uint index = lookup_instance(ui, over[position - 1].id);
        if (index == UI_NONE || !ui.instances[index].hit) continue;
        UiInstance* instance = &ui.instances[index];
        if (instance.grid != UI_NONE && instance.element.actions[UiEventKind.DROP.ordinal] == UI_NONE) {
            instance = &ui.instances[instance.grid];
        }
        if (instance.element.actions[UiEventKind.DROP.ordinal] == UI_NONE || !instance.enabled) continue;
        ui.drag.target = instance.key;
        if (instance.element.kind == GRID) ui.drag.cell = grid_cell(ui, instance, pointer);
        return;
    }
}

fn uint grid_cell(Ui* ui, UiInstance* grid, Vec2 pointer) @private {
    clay::BoundingBox box = clay::get_element_data(clay::id(grid.clay_id)).bounding_box;
    UiElement* element = grid.element;
    Vec4 padding = grid.properties.padding;
    float column = math::floor((pointer.x - box.x - padding.x) / element.cell_size.x);
    float row = math::floor((pointer.y - box.y - padding.y) / element.cell_size.y);
    column = math::clamp(column, 0.0f, (float)(element.columns - ui.drag.span_width));
    row = math::clamp(row, 0.0f, (float)(element.rows - ui.drag.span_height));
    return (uint)row * element.columns + (uint)column;
}

fn void focus_field(Ui* ui, UiInstance* field) @private {
    ui.focus = field.key;
    usz length = field.text.len < ui.field.len ? field.text.len : ui.field.len;
    while (length > 0 && length < field.text.len && (field.text[length] & 0xC0) == 0x80) length--;
    ui.field[:length] = field.text[:length];
    ui.field_length = (uint)length;
    ui.caret = (uint)length;
}

fn void route_key(Ui* ui, Event* event) @private {
    String before = (String)ui.field[:ui.field_length];
    uint length = ui.field_length;
    switch (event.kind) {
        case TEXT_INPUT:
            insert_text(ui, event.text);
        case KEY_DOWN:
            switch (event.scancode) {
                case Scancode.BACKSPACE:
                    if (ui.caret > 0) remove_bytes(ui, previous_boundary(ui, ui.caret), ui.caret);
                case Scancode.DELETE:
                    if (ui.caret < ui.field_length) remove_bytes(ui, ui.caret, next_boundary(ui, ui.caret));
                case Scancode.LEFT:
                    if (ui.caret > 0) ui.caret = previous_boundary(ui, ui.caret);
                case Scancode.RIGHT:
                    if (ui.caret < ui.field_length) ui.caret = next_boundary(ui, ui.caret);
                case Scancode.HOME:
                    ui.caret = 0;
                case Scancode.END:
                    ui.caret = ui.field_length;
                case Scancode.RETURN:
                case Scancode.KP_ENTER:
                    UiElementKey field = ui.focus;
                    UiEvent submit = { .kind = SUBMIT, .cell = UI_NO_CELL, .text = (String)ui.field[:ui.field_length] };
                    ui.focus = {};
                    fire_action(
                        ui:    ui,
                        key:   &field,
                        kind:  SUBMIT,
                        event: &submit,
                    );
                    return;
                case Scancode.ESCAPE:
                    ui.focus = {};
                    return;
                case Scancode.V:
                    if (event.modifiers.ctrl) insert_text(ui, (String)platform::clipboard_text().str_view());
                default:
                    break;
            }
        default:
            return;
    }
    if (ui.field_length == length && (String)ui.field[:ui.field_length] == before) return;
    UiEvent change = { .kind = CHANGE, .cell = UI_NO_CELL, .text = (String)ui.field[:ui.field_length] };
    UiElementKey field = ui.focus;
    fire_action(
        ui:    ui,
        key:   &field,
        kind:  CHANGE,
        event: &change,
    );
}

fn void insert_text(Ui* ui, String text) @private {
    if (!valid_utf8(text)) return;
    usz room = ui.field.len - ui.field_length;
    usz length = text.len < room ? text.len : room;
    while (length > 0 && length < text.len && (text[length] & 0xC0) == 0x80) length--;
    if (!length) return;
    mem::move(&ui.field[ui.caret + length], &ui.field[ui.caret], (sz)(ui.field_length - ui.caret));
    ui.field[ui.caret : length] = text[:length];
    ui.field_length += (uint)length;
    ui.caret += (uint)length;
}

fn void remove_bytes(Ui* ui, uint start, uint end) @private {
    mem::move(&ui.field[start], &ui.field[end], (sz)(ui.field_length - end));
    ui.field_length -= end - start;
    ui.caret = start;
}

fn uint previous_boundary(Ui* ui, uint offset) @private {
    uint at = offset - 1;
    while (at > 0 && (ui.field[at] & 0xC0) == 0x80) at--;
    return at;
}

fn uint next_boundary(Ui* ui, uint offset) @private {
    uint at = offset + 1;
    while (at < ui.field_length && (ui.field[at] & 0xC0) == 0x80) at++;
    return at;
}

fn void fire_action(Ui* ui, UiElementKey* key, UiEventKind kind, UiEvent* event) @private {
    UiDocument*? document = ui.documents.try_get(key.document);
    if (catch document) return;
    uint action = document.elements[key.element].actions[kind.ordinal];
    if (action == UI_NONE) return;
    UiScope scope = key.scope;
    ui.actions[action].handler(ui.actions[action].user, &scope, event);
}
