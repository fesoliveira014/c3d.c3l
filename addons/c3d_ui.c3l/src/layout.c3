module c3d::ui;

import c3d;
import c3d::asset;
import c3d::material;
import clay;
import std::math;

const float UI_PLACEHOLDER_ALPHA @private = 0.5;
const float UI_MAX_PADDING @private = 65535; // Clay stores padding and gaps as u16

struct UiDeclare @private {
    Ui*   ui;
    fault failure;
    short band;              // z of the document being declared
    bool  drag_source_found; // the dragged item is still declared this frame
}

struct UiPlacement @private {
    clay::FloatingElementConfig floating;
    bool                        fixed_size;
    Vec2                        size;
    bool                        hit;         // false for tooltips and the drag ghost
    uint                        grid;        // owning grid instance of a grid item
    uint                        list;        // LIST binding a grid item came from
    uint                        span_width;
    uint                        span_height;
}

<*
 Evaluate bindings and lay out every visible document.
 @param scale : "Output pixels per layout unit, including pixel density."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
 @require scale > 0
*>
fn void? Ui.update(
    &self,
    uint width,
    uint height,
    float scale,
) {
    clay::set_current_context(self.context);
    clay::set_measure_text_function(&measure_clay_text, self);
    self.stats.instances = 0;
    self.stats.getter_calls = 0;
    self.stats.text_bytes = 0;
    self.text_used = 0;
    self.instance_count = 0;
    self.instance_lookup[..] = {};
    self.clay_error.raised = false;
    self.frame_ready = false;
    self.scale = scale;

    clay::set_layout_dimensions({ (float)width / scale, (float)height / scale });
    clay::begin_layout();
    UiDeclare declare = { .ui = self };
    uint stack_count = stack_documents(self);
    for (uint rank = 0; rank < stack_count; rank++) {
        UiDocument* document = self.document_stack[rank];
        declare.band = (short)rank * UI_Z_BAND;
        clay::AttachPoint anchor = attach_point(document.anchor);
        UiPlacement placement = {
            .floating = {
                .offset               = { document.offset.x, document.offset.y },
                .z_index              = declare.band,
                .attach_points        = { .element = anchor, .parent = anchor },
                .pointer_capture_mode = CAPTURE,
                .attach_to            = ROOT,
            },
            .hit  = true,
            .grid = UI_NONE,
            .list = UI_NONE,
        };
        UiScope root_scope;
        declare_element(
            declare:   &declare,
            document:  document,
            index:     0,
            scope:     &root_scope,
            inherited: {},
            placement: &placement,
        );
    }
    if (self.drag.active && !declare.drag_source_found) self.drag = {};
    declare_ghost(&declare);
    clay::RenderCommandArray commands = clay::end_layout(0);
    self.stats.instances = self.instance_count;

    if (declare.failure) return declare.failure~;
    if (self.clay_error.raised) {
        switch (self.clay_error.type) {
            case ARENA_CAPACITY_EXCEEDED:
            case ELEMENTS_CAPACITY_EXCEEDED:
            case TEXT_MEASUREMENT_CAPACITY_EXCEEDED:
            case HASH_MAP_CAPACITY_EXCEEDED:
                return c3d::CAPACITY_EXCEEDED~;
            default:
                return c3d::INVALID_ARGUMENT~;
        }
    }
    self.commands = commands;
    self.frame_ready = true;
}

fn uint stack_documents(Ui* ui) @private {
    uint count;
    foreach (&document : ui.documents.items) {
        if (!document.live || !document.visible) continue;
        uint at = count;
        while (at > 0 && stacks_above(ui.document_stack[at - 1], document)) {
            ui.document_stack[at] = ui.document_stack[at - 1];
            at--;
        }
        ui.document_stack[at] = document;
        count++;
    }
    return count;
}

fn bool stacks_above(UiDocument* first, UiDocument* second) @private {
    if (first.layer != second.layer) return first.layer > second.layer;
    return first.order > second.order;
}

fn clay::AttachPoint attach_point(UiAnchor anchor) @private {
    switch (anchor) {
        case TOP_LEFT: return LEFT_TOP;
        case TOP: return CENTER_TOP;
        case TOP_RIGHT: return RIGHT_TOP;
        case LEFT: return LEFT_CENTER;
        case CENTER: return CENTER_CENTER;
        case RIGHT: return RIGHT_CENTER;
        case BOTTOM_LEFT: return LEFT_BOTTOM;
        case BOTTOM: return CENTER_BOTTOM;
        case BOTTOM_RIGHT: return RIGHT_BOTTOM;
    }
}

fn void declare_ghost(UiDeclare* declare) @private {
    Ui* ui = declare.ui;
    if (!ui.drag.active) return;
    UiDocument*? document = ui.documents.try_get(ui.drag.source.document);
    if (catch document) return;
    UiPlacement placement = {
        .floating = {
            .offset               = { ui.pointer.x - ui.drag.grab.x, ui.pointer.y - ui.drag.grab.y },
            .z_index              = UI_Z_GHOST,
            .attach_points        = { .element = LEFT_TOP, .parent = LEFT_TOP },
            .pointer_capture_mode = PASSTHROUGH,
            .attach_to            = ROOT,
        },
        .fixed_size = true,
        .size       = ui.drag.size,
        .grid       = UI_NONE,
        .list       = UI_NONE,
    };
    declare_element(
        declare:   declare,
        document:  document,
        index:     ui.drag.source.element,
        scope:     &ui.drag.source.scope,
        inherited: {},
        placement: &placement,
    );
}

fn UiProperties effective_properties(Ui* ui, UiElement* element, UiStateFlags state) @private {
    UiProperties properties = UI_PROPERTIES_DEFAULT;
    if (element.style != UI_NONE) properties = style_properties(&ui.styles.styles[element.style], state);
    ulong mask;
    apply_properties(
        target:      &properties,
        target_mask: &mask,
        source:      &element.properties,
        source_mask: element.mask,
    );
    return properties;
}

fn bool ref_bool(Ui* ui, UiRef* reference, UiScope* scope) @private {
    if (reference.binding == UI_NONE) return reference.literal != 0;
    return call_getter(ui, reference.binding, scope).boolean;
}

fn float ref_number(Ui* ui, UiRef* reference, UiScope* scope) @private {
    if (reference.binding == UI_NONE) return reference.literal;
    UiValue value = call_getter(ui, reference.binding, scope);
    return value.kind == INT ? (float)value.integer : (float)value.number;
}

fn bool is_interactive(UiElement* element) @private {
    if (element.kind == BUTTON || element.kind == TEXT_FIELD) return true;
    foreach (action : element.actions) {
        if (action != UI_NONE) return true;
    }
    return false;
}

fn bool pointer_over(Ui* ui, UiElementKey* key) @private {
    for (uint index = 0; index < ui.tooltip_host_count; index++) {
        if (same_key(&ui.tooltip_hosts[index], key)) return true;
    }
    return false;
}

fn bool instance_draws(UiInstance* instance) @private {
    UiProperties* properties = &instance.properties;
    if (properties.fill.w > 0 || properties.skin.image.generation) return true;
    Vec4 widths = properties.border_widths;
    if (properties.border_color.w > 0 && (widths.x > 0 || widths.y > 0 || widths.z > 0 || widths.w > 0)) return true;
    switch (instance.element.kind) {
        case IMAGE:
        case BAR:
        case GRID:
            return true;
        case TEXT_FIELD:
            return instance.state.focused;
        default:
            return false;
    }
}

fn uint key_hash(UiElementKey* key) @private {
    uint hash = 0x811c_9dc5;
    uint[4] words = { key.document.index, key.document.generation, key.element, key.scope.depth };
    foreach (word : words) hash = (hash ^ word) * 0x0100_0193;
    for (uint level = 0; level < key.scope.depth; level++) hash = (hash ^ key.scope.indices[level]) * 0x0100_0193;
    return hash;
}

fn uint lookup_instance(Ui* ui, uint clay_id) @private {
    usz slot = clay_id % (usz)ui.instance_lookup.len;
    while (ui.instance_lookup[slot].clay_id) {
        if (ui.instance_lookup[slot].clay_id == clay_id) return ui.instance_lookup[slot].instance;
        slot = (slot + 1) % (usz)ui.instance_lookup.len;
    }
    return UI_NONE;
}

fn uint assign_clay_id(Ui* ui, UiElementKey* key, uint instance) @private {
    uint clay_id = key_hash(key);
    while (!clay_id || lookup_instance(ui, clay_id) != UI_NONE) clay_id += UI_ID_PROBE;
    usz slot = clay_id % (usz)ui.instance_lookup.len;
    while (ui.instance_lookup[slot].clay_id) slot = (slot + 1) % (usz)ui.instance_lookup.len;
    ui.instance_lookup[slot] = { .clay_id = clay_id, .instance = instance };
    return clay_id;
}

fn clay::SizingAxis sizing_axis(UiSize size, float min, float max) @private {
    switch (size.sizing) {
        case FIT: return clay::fit(min, max);
        case GROW: return clay::grow(min, max);
        case FIXED: return clay::fixed(size.value);
        case PERCENT: return clay::percent(size.value);
    }
}

fn ushort clay_units(float length) @private => (ushort)math::round(math::min(length, UI_MAX_PADDING));

fn clay::AlignX clay_align_x(UiAlign align) @private {
    switch (align) {
        case START: return LEFT;
        case CENTER: return CENTER;
        case END: return RIGHT;
    }
}

fn clay::AlignY clay_align_y(UiAlign align) @private {
    switch (align) {
        case START: return TOP;
        case CENTER: return CENTER;
        case END: return BOTTOM;
    }
}

fn clay::LayoutConfig layout_config(UiProperties* properties) @private {
    return {
        .sizing = {
            sizing_axis(properties.width, properties.min_width, properties.max_width),
            sizing_axis(properties.height, properties.min_height, properties.max_height),
        },
        .padding = {
            clay_units(properties.padding.x),
            clay_units(properties.padding.z),
            clay_units(properties.padding.y),
            clay_units(properties.padding.w),
        },
        .child_gap        = clay_units(properties.gap),
        .child_alignment  = { .x = clay_align_x(properties.align_x), .y = clay_align_y(properties.align_y) },
        .layout_direction = properties.direction == COLUMN ? TOP_TO_BOTTOM : LEFT_TO_RIGHT,
    };
}

fn clay::TextElementConfig text_config(Ui* ui, UiProperties* properties, float alpha = 1) @private {
    Vec4 color = properties.text_color;
    clay::TextWrap wrap;
    switch (properties.wrap) {
        case WORDS: wrap = WORDS;
        case NEWLINES: wrap = NEWLINES;
        case NONE: wrap = NONE;
    }
    clay::TextAlign align;
    switch (properties.text_align) {
        case LEFT: align = LEFT;
        case CENTER: align = CENTER;
        case RIGHT: align = RIGHT;
    }
    return {
        .text_color     = { color.x, color.y, color.z, color.w * alpha },
        .font_id        = (ushort)properties.font_set,
        .font_size      = (ushort)properties.font_size,
        .line_height    = (ushort)line_height(ui, properties),
        .wrap_mode      = wrap,
        .text_alignment = align,
    };
}

fn void fail_declare(UiDeclare* declare, fault excuse) @private {
    if (!declare.failure) declare.failure = excuse;
}

fn void declare_element(
    UiDeclare* declare,
    UiDocument* document,
    uint index,
    UiScope* scope,
    UiStateFlags inherited,
    UiPlacement* placement,
) @private {
    if (declare.failure) return;
    Ui* ui = declare.ui;
    UiElement* element = &document.elements[index];
    if (!ref_bool(ui, &element.visible, scope)) return;

    UiElementKey key = { .document = document.id, .element = index, .scope = *scope };
    bool interactive = is_interactive(element) || placement.list != UI_NONE;
    if (placement.hit && ui.drag.active && same_key(&key, &ui.drag.source)) declare.drag_source_found = true;
    UiStateFlags state = inherited;
    // An interactive element takes its own hover and press, not its ancestor's.
    if (interactive) {
        state.hovered = false;
        state.pressed = false;
    }
    state.focused = same_key(&key, &ui.focus);
    if (same_key(&key, &ui.hover)) state.hovered = true;
    if (same_key(&key, &ui.press)) state.pressed = true;
    if (!ref_bool(ui, &element.enabled, scope)) state.disabled = true;

    if (ui.instance_count == ui.instances.len) return fail_declare(declare, c3d::CAPACITY_EXCEEDED);
    uint instance_index = ui.instance_count;
    ui.instance_count++;
    UiInstance* instance = &ui.instances[instance_index];
    *instance = {
        .key         = key,
        .document    = document,
        .element     = element,
        .properties  = effective_properties(ui, element, state),
        .state       = state,
        .grid        = placement.grid,
        .list        = placement.list,
        .span_width  = placement.span_width,
        .span_height = placement.span_height,
        .interactive = interactive,
        .hit         = placement.hit,
        .enabled     = !state.disabled,
    };
    instance.clay_id = assign_clay_id(ui, &key, instance_index);
    if (catch excuse = prepare_instance(ui, instance, scope)) return fail_declare(declare, excuse);

    clay::open_element(clay::id(instance.clay_id));
    clay::ElementDeclaration declaration = {
        .layout   = layout_config(&instance.properties),
        .floating = placement.floating,
    };
    if (placement.fixed_size) {
        declaration.layout.sizing = { clay::fixed(placement.size.x), clay::fixed(placement.size.y) };
    }
    switch (element.kind) {
        case IMAGE:
            size_image(ui, instance, &declaration.layout.sizing);
        case SCROLL:
            declaration.clip = {
                .horizontal   = element.scroll != VERTICAL,
                .vertical     = element.scroll != HORIZONTAL,
                .child_offset = clay::get_scroll_offset(),
            };
        case TEXT_FIELD:
            declaration.clip = { .horizontal = true };
        case GRID:
            Vec4 padding = instance.properties.padding;
            declaration.layout.sizing = {
                clay::fixed(element.cell_size.x * element.columns + padding.x + padding.z),
                clay::fixed(element.cell_size.y * element.rows + padding.y + padding.w),
            };
        default:
            break;
    }
    if (instance_draws(instance)) declaration.custom = { .custom_data = instance };
    clay::configure_element(&declaration);

    declare_contents(
        declare:        declare,
        document:       document,
        element:        element,
        instance:       instance,
        instance_index: instance_index,
        scope:          scope,
    );
    clay::close_element();
}

fn void? prepare_instance(Ui* ui, UiInstance* instance, UiScope* scope) @private {
    UiElement* element = instance.element;
    UiDocument* document = instance.document;
    switch (element.kind) {
        case LABEL:
            instance.text = expand_template(
                ui:       ui,
                document: document,
                first:    element.text_first,
                count:    element.text_count,
                scope:    scope,
            )!;
        case TEXT_FIELD:
            if (instance.state.focused) {
                instance.text = copy_text(ui, (String)ui.field[:ui.field_length])!;
            } else if (element.value.binding != UI_NONE) {
                instance.text = copy_text(ui, call_getter(ui, element.value.binding, scope).text)!;
            }
        case IMAGE:
            instance.image = element.image;
            if (element.image_binding != UI_NONE) instance.image = call_getter(ui, element.image_binding, scope).image;
        case BAR:
            instance.value = math::clamp(ref_number(ui, &element.value, scope), 0.0f, 1.0f);
        default:
            break;
    }
}

fn void size_image(Ui* ui, UiInstance* instance, clay::Sizing* sizing) @private {
    TextureRef image = instance.image;
    if (image.kind != ASSET || !image.asset.generation || !ui.assets.textures.is_live(image.asset)) return;
    TextureDesc desc = ui.assets.texture(image.asset).desc;
    if (instance.properties.width.sizing == FIT) sizing.width = clay::fixed((float)desc.width);
    if (instance.properties.height.sizing == FIT) sizing.height = clay::fixed((float)desc.height);
}

fn void declare_contents(
    UiDeclare* declare,
    UiDocument* document,
    UiElement* element,
    UiInstance* instance,
    uint instance_index,
    UiScope* scope,
) @private {
    Ui* ui = declare.ui;
    UiStateFlags inherited = instance.state;
    inherited.focused = false;
    switch (element.kind) {
        case LABEL:
            clay::text(instance.text, text_config(ui, &instance.properties));
        case TEXT_FIELD:
            if (instance.text.len) {
                clay::text(instance.text, text_config(ui, &instance.properties));
            } else if (element.placeholder_count) {
                String? placeholder = expand_template(
                    ui:       ui,
                    document: document,
                    first:    element.placeholder_first,
                    count:    element.placeholder_count,
                    scope:    scope,
                );
                if (catch excuse = placeholder) return fail_declare(declare, excuse);
                clay::text(placeholder, text_config(ui, &instance.properties, UI_PLACEHOLDER_ALPHA));
            }
        case LIST:
            uint count = call_getter(ui, element.items, scope).count;
            for (uint item = 0; item < count; item++) {
                UiScope item_scope = *scope;
                item_scope.indices[item_scope.depth] = item;
                item_scope.depth++;
                UiPlacement placement = { .hit = true, .grid = UI_NONE, .list = UI_NONE };
                declare_element(
                    declare:   declare,
                    document:  document,
                    index:     element.template,
                    scope:     &item_scope,
                    inherited: inherited,
                    placement: &placement,
                );
            }
        case GRID:
            declare_grid_items(
                declare:        declare,
                document:       document,
                grid:           element,
                instance:       instance,
                instance_index: instance_index,
                scope:          scope,
            );
        case PANEL:
        case BUTTON:
        case SCROLL:
        case TOOLTIP:
            for (uint child = element.first_child; child != UI_NONE; child = document.elements[child].next_sibling) {
                UiPlacement placement = { .hit = true, .grid = UI_NONE, .list = UI_NONE };
                if (document.elements[child].kind == TOOLTIP) {
                    if (!pointer_over(ui, &instance.key)) continue;
                    placement.hit = false;
                    placement.floating = {
                        .z_index              = UI_Z_TOOLTIP,
                        .attach_points        = { .element = LEFT_TOP, .parent = LEFT_BOTTOM },
                        .pointer_capture_mode = PASSTHROUGH,
                        .attach_to            = PARENT,
                    };
                }
                declare_element(
                    declare:   declare,
                    document:  document,
                    index:     child,
                    scope:     scope,
                    inherited: inherited,
                    placement: &placement,
                );
            }
        case IMAGE:
        case BAR:
            break;
    }
}

fn void declare_grid_items(
    UiDeclare* declare,
    UiDocument* document,
    UiElement* grid,
    UiInstance* instance,
    uint instance_index,
    UiScope* scope,
) @private {
    Ui* ui = declare.ui;
    UiStateFlags inherited = instance.state;
    inherited.focused = false;
    uint count = call_getter(ui, grid.items, scope).count;
    for (uint item = 0; item < count; item++) {
        UiScope item_scope = *scope;
        item_scope.indices[item_scope.depth] = item;
        item_scope.depth++;
        float cell = ref_number(ui, &grid.item_cell, &item_scope);
        float width = ref_number(ui, &grid.span_width, &item_scope);
        float height = ref_number(ui, &grid.span_height, &item_scope);
        if (cell < 0 || width < 1 || height < 1) continue;
        uint column = (uint)cell % grid.columns;
        uint row = (uint)cell / grid.columns;
        if (column + (uint)width > grid.columns || row + (uint)height > grid.rows) continue;

        Vec4 padding = instance.properties.padding;
        UiPlacement placement = {
            .floating = {
                .offset               = {
                    padding.x + column * grid.cell_size.x,
                    padding.y + row * grid.cell_size.y,
                },
                .z_index              = declare.band + 1,
                .attach_points        = { .element = LEFT_TOP, .parent = LEFT_TOP },
                .pointer_capture_mode = CAPTURE,
                .attach_to            = PARENT,
                .clip_to              = ATTACHED_PARENT,
            },
            .fixed_size  = true,
            .size        = { width * grid.cell_size.x, height * grid.cell_size.y },
            .hit         = true,
            .grid        = instance_index,
            .list        = grid.items,
            .span_width  = (uint)width,
            .span_height = (uint)height,
        };
        declare_element(
            declare:   declare,
            document:  document,
            index:     grid.template,
            scope:     &item_scope,
            inherited: inherited,
            placement: &placement,
        );
    }
}
