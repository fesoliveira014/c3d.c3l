module c3d::ui;

import c3d;
import c3d::platform;
import clay;
import std::math;

<*
 Offset of a window from its parent's top left, in layout units.
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
*>
fn Vec2? Ui.window_offset(&self, UiDocumentId document, String id) {
    return self.windows[find_window(self, document, id)!].offset;
}

<*
 Move a window and cancel any drag of it.
 @param offset : "Layout units from the parent's top left; not clamped."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
 @require math::is_finite(offset.x) && math::is_finite(offset.y)
*>
fn void? Ui.set_window_offset(
    &self,
    UiDocumentId document,
    String id,
    Vec2 offset,
) {
    uint slot = find_window(self, document, id)!;
    self.windows[slot].offset = offset;
    if (moving_window(self) && self.window_drag.window == slot) self.window_drag = {};
}

fn uint? find_window(Ui* ui, UiDocumentId document, String id) @private {
    UiDocument* record = ui.documents.try_get(document)!;
    uint element = find_window_element(record, id);
    if (element == UI_NONE) return c3d::INVALID_ARGUMENT~;

    return record.elements[element].window_slot;
}

fn uint count_windows(UiDocument* document) @private {
    uint count;
    foreach (&element : document.elements) {
        if (element.window) count++;
    }

    return count;
}

fn uint free_window_slots(Ui* ui) @private {
    uint count;
    foreach (&window : ui.windows) {
        if (!key_valid(&window.key)) count++;
    }

    return count;
}

fn bool has_drag_handle(UiDocument* document, uint window) @private {
    foreach (&element : document.elements) {
        if (element.drag_handle && element.window_of == window) return true;
    }

    return false;
}

fn uint find_window_element(UiDocument* document, String id) @private {
    uint index = find_id_element(document, id);
    if (index == UI_NONE || !document.elements[index].window) return UI_NONE;

    return index;
}

fn void assign_windows(Ui* ui, UiDocument* document, UiDocument* previous) @private {
    if (previous) keep_windows(ui, document, previous);

    uint slot;
    foreach (uint index, &element : document.elements) {
        if (!element.window || element.window_slot != UI_NONE) continue;

        while (key_valid(&ui.windows[slot].key)) slot++;

        ui.windows[slot] = {
            .key             = { .document = document.id, .element = index },
            .offset          = element.position,
            .instance        = UI_NONE,
            .parent_instance = UI_NONE,
        };
        element.window_slot = slot;
    }
}

fn void keep_windows(Ui* ui, UiDocument* document, UiDocument* previous) @private {
    foreach (uint slot, &window : ui.windows) {
        if (!c3d::same_id(window.key.document, document.id)) continue;

        UiElement* old_element = &previous.elements[window.key.element];
        String id = previous.strings[old_element.id_offset : old_element.id_length];
        uint element = find_window_element(document, id);
        if (element == UI_NONE) {
            if (moving_window(ui) && ui.window_drag.window == slot) ui.window_drag = {};
            *window = {};
            continue;
        }

        window.key.element = element;
        document.elements[element].window_slot = slot;

        bool dragged = moving_window(ui) && ui.window_drag.window == slot;
        if (dragged && !has_drag_handle(document, element)) cancel_window_drag(ui);
    }
}

fn void release_windows(Ui* ui, UiDocumentId document) @private {
    foreach (uint slot, &window : ui.windows) {
        if (!c3d::same_id(window.key.document, document)) continue;

        if (moving_window(ui) && ui.window_drag.window == slot) ui.window_drag = {};
        *window = {};
    }
}

fn bool moving_window(Ui* ui) @private => ui.window_drag.candidate || ui.window_drag.active;

fn void cancel_window_drag(Ui* ui) @private {
    if (!moving_window(ui)) return;

    ui.windows[ui.window_drag.window].offset = ui.window_drag.start;
    ui.window_drag = {};
    ui.press = {};
}

fn void check_window_drag(Ui* ui, UiDeclare* declare) @private {
    if (!moving_window(ui)) return;
    if (ui.windows[ui.window_drag.window].instance == UI_NONE || !declare.handle_found) cancel_window_drag(ui);
}

fn void track_drag_handle(UiDeclare* declare, UiDocument* document, UiElement* element) @private {
    Ui* ui = declare.ui;
    if (!element.drag_handle || !moving_window(ui)) return;

    UiElementKey* dragged = &ui.windows[ui.window_drag.window].key;
    if (c3d::same_id(dragged.document, document.id) && element.window_of == dragged.element) {
        declare.handle_found = true;
    }
}

fn bool claim_window_z(UiDeclare* declare, UiPlacement* placement) @private {
    int z = declare.band + UI_Z_BAND + 2 * (int)declare.windows;
    // The window's grid items draw one above it, and nothing may reach the tooltip layer.
    if (z + 1 >= UI_Z_TOOLTIP) return false;

    declare.windows++;
    declare.z = (short)z;
    placement.floating.z_index = declare.z;
    return true;
}

fn bool window_before(uint order, uint index, uint other_order, uint other_index) @private {
    return order < other_order || (order == other_order && index < other_index);
}

fn uint window_order(Ui* ui, UiDocument* document, uint element) @private {
    return ui.windows[document.elements[element].window_slot].order;
}

fn uint next_window(Ui* ui, UiDocument* document, UiElement* parent, uint declared) @private {
    uint next = UI_NONE;
    for (uint child = parent.first_child; child != UI_NONE; child = document.elements[child].next_sibling) {
        if (!document.elements[child].window) continue;

        uint order = window_order(ui, document, child);
        bool after_declared = declared == UI_NONE
            || window_before(window_order(ui, document, declared), declared, order, child);
        bool before_next = next == UI_NONE
            || window_before(order, child, window_order(ui, document, next), next);
        if (after_declared && before_next) next = child;
    }

    return next;
}

fn void declare_windows(
    UiDeclare* declare,
    UiDocument* document,
    UiElement* parent,
    uint parent_index,
    UiStateFlags inherited,
    float alpha,
    UiScope* scope,
) @private {
    Ui* ui = declare.ui;

    // A window attached to a scroll does not follow the scroll's content unless it adds the content offset.
    Vec2 child_offset;
    if (parent.kind == SCROLL) {
        clay::Vector2 scrolled = clay::get_scroll_offset();
        child_offset = { scrolled.x, scrolled.y };
    }

    uint declared = UI_NONE;
    while (!declare.failure) {
        uint next = next_window(ui, document, parent, declared);
        if (next == UI_NONE) break;

        UiWindow* window = &ui.windows[document.elements[next].window_slot];
        UiPlacement placement = {
            .floating = {
                .offset               = { window.offset.x + child_offset.x, window.offset.y + child_offset.y },
                .attach_points        = { .element = LEFT_TOP, .parent = LEFT_TOP },
                .pointer_capture_mode = CAPTURE,
                .attach_to            = PARENT,
                .clip_to              = ATTACHED_PARENT,
            },
            .hit  = true,
            .grid = UI_NONE,
            .list = UI_NONE,
        };

        uint instance_index = ui.instance_count;
        declare_element(
            declare:   declare,
            document:  document,
            index:     next,
            scope:     scope,
            inherited: inherited,
            alpha:     alpha,
            placement: &placement,
        );

        if (ui.instance_count != instance_index) {
            window.instance = instance_index;
            window.parent_instance = parent_index;
            window.child_offset = child_offset;
        }

        declared = next;
    }
}

fn Vec2 clamp_window_offset(Ui* ui, UiWindow* window, Vec2 offset) @private {
    UiElement* element = &ui.documents.get(window.key.document).elements[window.key.element];
    if (element.drag_bounds == NONE) return offset;

    UiInstance* parent = &ui.instances[window.parent_instance];
    clay::BoundingBox parent_box = clay::get_element_data(clay::id(parent.clay_id)).bounding_box;
    clay::BoundingBox box = clay::get_element_data(clay::id(ui.instances[window.instance].clay_id)).bounding_box;
    Vec2 child = window.child_offset;
    Vec2 low;
    Vec2 high;
    switch (element.drag_bounds) {
        case PARENT:
            Vec4 padding = parent.properties.padding;
            low = { padding.x - child.x, padding.y - child.y };
            high = {
                parent_box.width - padding.z - box.width - child.x,
                parent_box.height - padding.w - box.height - child.y,
            };
        case VIEWPORT:
            low = { -parent_box.x - child.x, -parent_box.y - child.y };
            high = {
                ui.layout_size.x - box.width - parent_box.x - child.x,
                ui.layout_size.y - box.height - parent_box.y - child.y,
            };
        case NONE:
            break;
    }

    // When the range is empty the lower bound wins.
    return {
        math::max(low.x, math::min(offset.x, high.x)),
        math::max(low.y, math::min(offset.y, high.y)),
    };
}

fn bool takes_press(UiDocument* document, uint index) @private {
    UiElement* element = &document.elements[index];
    if (is_interactive(element)) return true;
    if (element.parent == UI_NONE) return false;

    UiElement* parent = &document.elements[element.parent];
    return parent.kind == GRID && parent.template == index;
}

fn void raise_windows(Ui* ui, UiInstance* hit) @private {
    UiDocument* document = hit.document;
    uint window = hit.element.window_of;
    while (window != UI_NONE) {
        UiElement* element = &document.elements[window];
        ui.window_order++;
        ui.windows[element.window_slot].order = ui.window_order;
        window = element.parent == UI_NONE ? UI_NONE : document.elements[element.parent].window_of;
    }
}

fn void begin_window_drag(Ui* ui, UiInstance* hit, Vec2 pointer) @private {
    UiDocument* document = hit.document;
    uint window = hit.element.window_of;
    if (window == UI_NONE) return;

    uint index = hit.key.element;
    while (!document.elements[index].drag_handle) {
        if (takes_press(document, index) || index == window) return;
        index = document.elements[index].parent;
    }

    uint slot = document.elements[window].window_slot;
    ui.window_drag = {
        .candidate = true,
        .window    = slot,
        .start     = ui.windows[slot].offset,
        .origin    = pointer,
    };
}

fn void move_window(Ui* ui, Vec2 pointer) @private {
    UiWindowDrag* drag = &ui.window_drag;
    if (drag.candidate) {
        if ((pointer - drag.origin).length() <= UI_DRAG_THRESHOLD) return;

        drag.candidate = false;
        drag.active = true;
        ui.press = {};

        UiWindow* started = &ui.windows[drag.window];
        UiEvent event = { .kind = MOVE_START, .cell = UI_NO_CELL, .offset = started.offset };
        UiElementKey key = started.key;
        fire_action(
            ui:    ui,
            key:   &key,
            kind:  MOVE_START,
            event: &event,
        );
    }

    if (!drag.active) return;

    UiWindow* window = &ui.windows[drag.window];
    window.offset = clamp_window_offset(ui, window, drag.start + pointer - drag.origin);
}

fn bool release_window(Ui* ui, Event* event) @private {
    if (!moving_window(ui)) return false;
    if (event.button != LEFT) return true;
    if (!ui.window_drag.active) {
        ui.window_drag = {};
        return false;
    }

    if (ui.frame_ready) move_window(ui, event.position / ui.scale);

    UiWindow* window = &ui.windows[ui.window_drag.window];
    UiEvent end = { .kind = MOVE_END, .cell = UI_NO_CELL, .offset = window.offset };
    UiElementKey key = window.key;

    ui.window_drag = {};
    ui.press = {};
    fire_action(
        ui:    ui,
        key:   &key,
        kind:  MOVE_END,
        event: &end,
    );

    return true;
}
