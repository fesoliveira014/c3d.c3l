module c3d::ui;

import c3d;
import c3d::asset;
import c3d::material;
import std::collections::list;
import std::collections::object;
import std::core::string;
import std::encoding::json;
import std::io;
import std::math;
import std::sort;

const usz UI_LOAD_TOKENS @private = 96;     // JSON nesting is capped at 64 by the parser
const uint UI_MAX_TEMPLATE_DECIMALS @private = 6;
const uint UI_DEFAULT_DECIMALS @private = uint::max;
const int UI_MAX_LAYER @private = 1000;        // z bands are per visible document, so the layer only orders documents
const double UI_MAX_GRID_SIDE @private = 256;  // cells per side; inventories stay far below

enum UiBarDirection @private {
    LEFT_TO_RIGHT,
    RIGHT_TO_LEFT,
    BOTTOM_TO_TOP,
    TOP_TO_BOTTOM,
}

enum UiScrollAxes @private {
    VERTICAL,
    HORIZONTAL,
    BOTH,
}

struct UiRef @private {
    uint  binding; // UI_NONE: the literal
    float literal; // booleans as 0 or 1
}

struct UiSegment @private {
    uint binding;  // UI_NONE: literal bytes
    uint offset;   // literal bytes in the document's strings
    uint length;
    uint decimals; // UI_DEFAULT_DECIMALS: the kind's default format
}

struct UiElement @private {
    UiElementKind  kind;
    uint           parent;
    uint           first_child;
    uint           next_sibling;
    uint           template;
    uint           level;          // enclosing lists: the scope depth of this element
    uint           style;          // index in the style set, UI_NONE without a style
    uint           style_offset;   // style name in the document's strings
    uint           style_length;
    UiProperties   properties;     // inline
    ulong          mask;
    uint           text_first;
    uint           text_count;
    uint           placeholder_first;
    uint           placeholder_count;
    UiRef          visible;
    UiRef          enabled;
    UiRef          value;          // bar value; a text field's TEXT binding
    UiRef          item_cell;
    UiRef          span_width;
    UiRef          span_height;
    uint           items;          // LIST binding of a list or grid
    uint           image_binding;  // UI_NONE: the literal image
    TextureRef     image;
    Vec4           uv;
    UiBarDirection bar_direction;
    UiScrollAxes   scroll;
    uint           columns;
    uint           rows;
    Vec2           cell_size;
    bool           has_tooltip;    // a tooltip child shows while the pointer is over this element
    uint[UiEventKind::len] actions; // indices in Ui.actions, UI_NONE without one
}

struct UiDocument @private {
    bool         live;
    UiDocumentId id;
    char[]       storage;   // one allocation: elements, segments, strings
    UiElement[]  elements;  // depth-first preorder, root first
    UiSegment[]  segments;
    String       strings;
    bool         visible;
    uint         order;
    UiAnchor     anchor;
    Vec2         offset;
    int          layer;
}

struct UiLoad @private {
    Ui*                     ui;
    String[UI_LOAD_TOKENS]  tokens;
    uint                    depth;
    uint[UI_SCOPE_DEPTH]    lists;      // LIST bindings of the enclosing lists, outermost first
    uint                    list_depth;
    List{UiElement}         elements;
    List{UiSegment}         segments;
    DString                 strings;
}

<*
 Load a document after checking every name it references.
 @return? c3d::ASSET_FORMAT_ERROR, c3d::CAPACITY_EXCEEDED
 @return? UNKNOWN_ELEMENT_KIND, UNKNOWN_PROPERTY, UNKNOWN_STYLE, UNKNOWN_BINDING
 @return? BINDING_KIND_MISMATCH, UNKNOWN_ACTION, UNKNOWN_ASSET
 @return? json::UNEXPECTED_CHARACTER, json::INVALID_ESCAPE_SEQUENCE, json::INVALID_NUMBER
 @return? json::MAX_DEPTH_REACHED, io::EOF
*>
fn UiDocumentId? Ui.load_document(&self, String jsonc) {
    begin_load(self);
    if (!self.documents.free_count) return c3d::CAPACITY_EXCEEDED~;
    UiDocument document = build_document(self, jsonc)!;
    UiDocumentId id = self.documents.add(document)!;
    UiDocument* record = self.documents.get(id);
    record.id = id;
    record.order = self.next_order++;
    invalidate_frame(self);
    return id;
}

<*
 Replace a document's tree; on a fault the old tree stays.
 Resets the document's focus, press and drag state; scroll offsets stay.
 @return? c3d::INVALID_ID, Ui.load_document!
*>
fn void? Ui.reload_document(&self, UiDocumentId document, String jsonc) {
    begin_load(self);
    UiDocument* record = self.documents.try_get(document)!;
    UiDocument replacement = build_document(self, jsonc)!;
    free_document(self, record);
    replacement.id = document;
    replacement.order = record.order;
    replacement.visible = record.visible;
    *record = replacement;
    forget_document(self, document);
    invalidate_frame(self);
}

<*
 JSON pointer of the value that failed the last load.
*>
fn String Ui.load_error_path(&self) => (String)self.error_path[:self.error_path_length];

<*
 Remove a document and its element state.
 @return? c3d::INVALID_ID
*>
fn void? Ui.unload_document(&self, UiDocumentId document) {
    UiDocument* record = self.documents.try_get(document)!;
    free_document(self, record);
    *record = {};
    self.documents.remove(document);
    forget_document(self, document);
    invalidate_frame(self);
}

<*
 Show or hide a document; hidden documents evaluate nothing.
 @return? c3d::INVALID_ID
*>
fn void? Ui.set_visible(&self, UiDocumentId document, bool visible) {
    UiDocument* record = self.documents.try_get(document)!;
    record.visible = visible;
    if (!visible && c3d::same_id(self.focus.document, document)) self.focus = {};
}

fn void free_document(Ui* ui, UiDocument* document) @private {
    if (document.storage.ptr) alloc::free(ui.allocator, document.storage.ptr);
    document.storage = {};
}

fn void forget_document(Ui* ui, UiDocumentId document) @private {
    if (c3d::same_id(ui.focus.document, document)) ui.focus = {};
}

fn void begin_load(Ui* ui) @private {
    ui.error_path_length = 0;
    ui.load_error_document = {};
}

fn void push_token(UiLoad* load, String token) @private {
    load.tokens[load.depth] = token;
    load.depth++;
}

fn void push_index(UiLoad* load, usz index) @private => push_token(load, string::tformat("%d", index));

fn void pop_token(UiLoad* load) @private => load.depth--;

fn fault fail_load(UiLoad* load, fault excuse) @private {
    Ui* ui = load.ui;
    usz length;
    for (uint index = 0; index < load.depth; index++) {
        DString token;
        token.tinit();
        token.append_char('/');
        foreach (character : load.tokens[index]) {
            switch (character) {
                case '~': token.append("~0");
                case '/': token.append("~1");
                default: token.append_char(character);
            }
        }
        usz token_length = (usz)token.len();
        if (length + token_length > ui.error_path.len) break;
        ui.error_path[length : token_length] = token.str_view()[..];
        length += token_length;
    }
    ui.error_path_length = (uint)length;
    return excuse;
}

fn String[] sorted_keys(Object* value) @private {
    List{String} keys;
    keys.tinit();
    value.@each_entry(; String key, Object* entry) {
        keys.push(key);
    };
    String[] view = keys.array_view();
    sort::quicksort(view, &by_text);
    return view;
}

fn int by_text(String first, String second) @private => first.compare_to(second);

fn UiDocument? build_document(Ui* ui, String jsonc) @private {
    UiDocument document;
    @pool() {
        UiLoad load = { .ui = ui };
        load.elements.tinit();
        load.segments.tinit();
        load.strings.tinit();
        Object* root = json::tparse(jsonc, JSONC)!;
        if (!root.is_map()) return fail_load(&load, c3d::ASSET_FORMAT_ERROR)~;

        UiAnchor anchor = TOP_LEFT;
        Vec2 offset;
        int layer;
        bool has_root;
        foreach (key : sorted_keys(root)) {
            Object* value = root.get(key)!!;
            push_token(&load, key);
            switch (key) {
                case "root":
                    load_element(
                        load:        &load,
                        value:       value,
                        parent:      UI_NONE,
                        is_template: false,
                    )!;
                    has_root = true;
                case "anchor":
                    anchor = read_anchor(&load, value)!;
                case "offset":
                    offset = read_pair(&load, value, true)!;
                case "layer":
                    double number = read_number(&load, value)!;
                    if (number != math::floor(number) || math::abs(number) > UI_MAX_LAYER) {
                        return fail_load(&load, c3d::ASSET_FORMAT_ERROR)~;
                    }
                    layer = (int)number;
                default:
                    return fail_load(&load, UNKNOWN_PROPERTY)~;
            }
            pop_token(&load);
        }
        if (!has_root) {
            push_token(&load, "root");
            return fail_load(&load, c3d::ASSET_FORMAT_ERROR)~;
        }

        usz elements_bytes = (usz)load.elements.len() * UiElement::size;
        usz segments_at = elements_bytes;
        usz strings_at = segments_at + (usz)load.segments.len() * UiSegment::size;
        usz total = strings_at + (usz)load.strings.len();
        Vec4[] block = alloc::new_array(ui.allocator, Vec4, (sz)((total + Vec4::size - 1) / Vec4::size));
        char[] storage = ((char*)block.ptr)[:block.len * Vec4::size];
        UiElement[] elements = ((UiElement*)storage.ptr)[:load.elements.len()];
        UiSegment[] segments = ((UiSegment*)(storage.ptr + segments_at))[:load.segments.len()];
        elements[..] = load.elements.array_view()[..];
        segments[..] = load.segments.array_view()[..];
        storage[strings_at : load.strings.len()] = load.strings.str_view()[..];
        document = {
            .live     = true,
            .storage  = storage,
            .elements = elements,
            .segments = segments,
            .strings  = (String)storage[strings_at : load.strings.len()],
            .visible  = true,
            .anchor   = anchor,
            .offset   = offset,
            .layer    = layer,
        };
    };
    return document;
}

fn UiAnchor? read_anchor(UiLoad* load, Object* value) @private {
    switch (read_word(load, value)!) {
        case "top_left": return TOP_LEFT;
        case "top": return TOP;
        case "top_right": return TOP_RIGHT;
        case "left": return LEFT;
        case "center": return CENTER;
        case "right": return RIGHT;
        case "bottom_left": return BOTTOM_LEFT;
        case "bottom": return BOTTOM;
        case "bottom_right": return BOTTOM_RIGHT;
        default: return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    }
}

fn Vec2? read_pair(UiLoad* load, Object* value, bool signed) @private {
    if (!value.is_array() || value.get_len() != 2) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    float[2] pair;
    for (usz index = 0; index < 2; index++) {
        push_index(load, index);
        if (signed) {
            double number = read_number(load, value.get_at((sz)index))!;
            if (!math::is_finite(number)) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
            pair[index] = (float)number;
        } else {
            pair[index] = read_length(load, value.get_at((sz)index))!;
        }
        pop_token(load);
    }
    return { pair[0], pair[1] };
}

fn UiElementKind? read_kind(UiLoad* load, Object* element) @private {
    push_token(load, "kind");
    Object* value = element.get("kind") ?? fail_load(load, UNKNOWN_ELEMENT_KIND)~!;
    if (!value.is_string()) return fail_load(load, UNKNOWN_ELEMENT_KIND)~;
    UiElementKind kind;
    switch (value.s) {
        case "panel": kind = PANEL;
        case "label": kind = LABEL;
        case "image": kind = IMAGE;
        case "button": kind = BUTTON;
        case "bar": kind = BAR;
        case "list": kind = LIST;
        case "scroll": kind = SCROLL;
        case "text_field": kind = TEXT_FIELD;
        case "tooltip": kind = TOOLTIP;
        case "grid": kind = GRID;
        default: return fail_load(load, UNKNOWN_ELEMENT_KIND)~;
    }
    pop_token(load);
    return kind;
}

fn uint? load_element(
    UiLoad* load,
    Object* value,
    uint parent,
    bool is_template,
) @private {
    if (!value.is_map()) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    UiElementKind kind = read_kind(load, value)!;
    if (kind == TOOLTIP && (parent == UI_NONE || is_template)) {
        push_token(load, "kind");
        return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    }
    uint index = (uint)load.elements.len();
    UiElement element = {
        .kind              = kind,
        .parent            = parent,
        .first_child       = UI_NONE,
        .next_sibling      = UI_NONE,
        .template          = UI_NONE,
        .level             = load.list_depth,
        .style             = UI_NONE,
        .visible           = { .binding = UI_NONE, .literal = 1 },
        .enabled           = { .binding = UI_NONE, .literal = 1 },
        .value             = { .binding = UI_NONE },
        .item_cell         = { .binding = UI_NONE },
        .span_width        = { .binding = UI_NONE, .literal = 1 },
        .span_height       = { .binding = UI_NONE, .literal = 1 },
        .items             = UI_NONE,
        .image_binding     = UI_NONE,
        .uv                = { 0, 0, 1, 1 },
    };
    element.actions[..] = UI_NONE;
    load.elements.push(element);

    bool is_list = kind == LIST || kind == GRID;
    if (is_list) {
        if (load.list_depth == UI_SCOPE_DEPTH) return fail_load(load, c3d::CAPACITY_EXCEEDED)~;
        push_token(load, "items");
        Object* items = value.get("items") ?? fail_load(load, c3d::ASSET_FORMAT_ERROR)~!;
        load.elements[index].items = read_binding(load, items, LIST)!;
        pop_token(load);
    }

    uint last_child = UI_NONE;
    foreach (key : sorted_keys(value)) {
        switch (key) {
            case "kind":
            case "items":
            case "template":
            case "item_cell":
            case "item_span":
                if (!is_list && key != "kind") {
                    push_token(load, key);
                    return fail_load(load, UNKNOWN_PROPERTY)~;
                }
                if (kind == LIST && (key == "item_cell" || key == "item_span")) {
                    push_token(load, key);
                    return fail_load(load, UNKNOWN_PROPERTY)~;
                }
                continue;
        }
        Object* entry = value.get(key)!!;
        push_token(load, key);
        switch (key) {
            case "children":
                if (kind != PANEL && kind != BUTTON && kind != SCROLL && kind != TOOLTIP) {
                    return fail_load(load, UNKNOWN_PROPERTY)~;
                }
                if (!entry.is_array()) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
                for (usz child_index = 0; child_index < (usz)entry.get_len(); child_index++) {
                    push_index(load, child_index);
                    uint child = load_element(
                        load:        load,
                        value:       entry.get_at((sz)child_index),
                        parent:      index,
                        is_template: false,
                    )!;
                    if (load.elements[child].kind == TOOLTIP) load.elements[index].has_tooltip = true;
                    if (last_child == UI_NONE) {
                        load.elements[index].first_child = child;
                    } else {
                        load.elements[last_child].next_sibling = child;
                    }
                    last_child = child;
                    pop_token(load);
                }
            default:
                read_element_key(
                    load:  load,
                    index: index,
                    key:   key,
                    entry: entry,
                )!;
        }
        pop_token(load);
    }

    if (is_list) {
        load.lists[load.list_depth] = load.elements[index].items;
        load.list_depth++;
        if (kind == GRID) read_grid_items(load, index, value)!;
        push_token(load, "template");
        Object* template = value.get("template") ?? fail_load(load, c3d::ASSET_FORMAT_ERROR)~!;
        uint root = load_element(
            load:        load,
            value:       template,
            parent:      index,
            is_template: true,
        )!;
        load.elements[index].template = root;
        pop_token(load);
        load.list_depth--;
        if (kind == GRID) check_grid_shape(load, index)!;
    }

    if (kind == LABEL || kind == TEXT_FIELD) check_font(load, &load.elements[index])!;
    return index;
}

fn void? read_element_key(
    UiLoad* load,
    uint index,
    String key,
    Object* entry,
) @private {
    UiElement* element = &load.elements[index];
    UiElementKind kind = element.kind;
    switch (key) {
        case "style":
            String name = read_word(load, entry)!;
            if (find_style_index(&load.ui.styles, name) == load.ui.styles.styles.len) {
                return fail_load(load, UNKNOWN_STYLE)~;
            }
            element.style = (uint)find_style_index(&load.ui.styles, name);
            element.style_offset = (uint)load.strings.len();
            element.style_length = (uint)name.len;
            load.strings.append(name);
        case "text":
            if (kind != LABEL) return fail_load(load, UNKNOWN_PROPERTY)~;
            read_template(
                load:  load,
                value: entry,
                first: &element.text_first,
                count: &element.text_count,
            )!;
        case "placeholder":
            if (kind != TEXT_FIELD) return fail_load(load, UNKNOWN_PROPERTY)~;
            read_template(
                load:  load,
                value: entry,
                first: &element.placeholder_first,
                count: &element.placeholder_count,
            )!;
        case "value":
            if (kind == BAR) {
                element.value = read_number_ref(load, entry)!;
            } else if (kind == TEXT_FIELD) {
                element.value = { .binding = read_binding(load, entry, TEXT)! };
            } else {
                return fail_load(load, UNKNOWN_PROPERTY)~;
            }
        case "image":
            if (kind != IMAGE) return fail_load(load, UNKNOWN_PROPERTY)~;
            String text = read_word(load, entry)!;
            if (binding_name(text).len) {
                element.image_binding = read_binding(load, entry, IMAGE)!;
            } else {
                element.image = { .kind = ASSET, .asset = find_texture_key(load, text)! };
            }
        case "uv":
            if (kind != IMAGE) return fail_load(load, UNKNOWN_PROPERTY)~;
            element.uv = read_uv(load, entry)!;
        case "visible":
            element.visible = read_bool_ref(load, entry)!;
        case "enabled":
            element.enabled = read_bool_ref(load, entry)!;
        case "bar_direction":
            if (kind != BAR) return fail_load(load, UNKNOWN_PROPERTY)~;
            switch (read_word(load, entry)!) {
                case "left_to_right": element.bar_direction = LEFT_TO_RIGHT;
                case "right_to_left": element.bar_direction = RIGHT_TO_LEFT;
                case "bottom_to_top": element.bar_direction = BOTTOM_TO_TOP;
                case "top_to_bottom": element.bar_direction = TOP_TO_BOTTOM;
                default: return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
            }
        case "scroll":
            if (kind != SCROLL) return fail_load(load, UNKNOWN_PROPERTY)~;
            switch (read_word(load, entry)!) {
                case "vertical": element.scroll = VERTICAL;
                case "horizontal": element.scroll = HORIZONTAL;
                case "both": element.scroll = BOTH;
                default: return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
            }
        case "columns":
        case "rows":
            if (kind != GRID) return fail_load(load, UNKNOWN_PROPERTY)~;
            double number = read_number(load, entry)!;
            if (number < 1 || number != math::floor(number) || number > UI_MAX_GRID_SIDE) {
                return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
            }
            if (key == "columns") {
                element.columns = (uint)number;
            } else {
                element.rows = (uint)number;
            }
        case "cell_size":
            if (kind != GRID) return fail_load(load, UNKNOWN_PROPERTY)~;
            element.cell_size = read_pair(load, entry, false)!;
        case "on_click": element.actions[UiEventKind.CLICK.ordinal] = read_action(load, entry)!;
        case "on_secondary_click": element.actions[UiEventKind.SECONDARY_CLICK.ordinal] = read_action(load, entry)!;
        case "on_drop": element.actions[UiEventKind.DROP.ordinal] = read_action(load, entry)!;
        case "on_change":
            if (kind != TEXT_FIELD) return fail_load(load, UNKNOWN_PROPERTY)~;
            element.actions[UiEventKind.CHANGE.ordinal] = read_action(load, entry)!;
        case "on_submit":
            if (kind != TEXT_FIELD) return fail_load(load, UNKNOWN_PROPERTY)~;
            element.actions[UiEventKind.SUBMIT.ordinal] = read_action(load, entry)!;
        default:
            if (!read_property(
                load:   load,
                key:    key,
                value:  entry,
                target: &element.properties,
                mask:   &element.mask,
            )!) {
                return fail_load(load, UNKNOWN_PROPERTY)~;
            }
    }
}

fn void? read_grid_items(UiLoad* load, uint index, Object* value) @private {
    if (try cell = value.get("item_cell")) {
        push_token(load, "item_cell");
        load.elements[index].item_cell = read_number_ref(load, cell, INT)!;
        pop_token(load);
    }
    if (try span = value.get("item_span")) {
        push_token(load, "item_span");
        if (!span.is_array() || span.get_len() != 2) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
        push_index(load, 0);
        load.elements[index].span_width = read_number_ref(load, span.get_at(0), INT)!;
        pop_token(load);
        push_index(load, 1);
        load.elements[index].span_height = read_number_ref(load, span.get_at(1), INT)!;
        pop_token(load);
        pop_token(load);
    }
}

fn void? check_grid_shape(UiLoad* load, uint index) @private {
    UiElement* grid = &load.elements[index];
    if (!grid.columns) return fail_at(load, "columns", c3d::ASSET_FORMAT_ERROR)~;
    if (!grid.rows) return fail_at(load, "rows", c3d::ASSET_FORMAT_ERROR)~;
    if (grid.cell_size.x <= 0 || grid.cell_size.y <= 0) return fail_at(load, "cell_size", c3d::ASSET_FORMAT_ERROR)~;
}

fn fault fail_at(UiLoad* load, String token, fault excuse) @private {
    push_token(load, token);
    return fail_load(load, excuse);
}

fn void? check_font(UiLoad* load, UiElement* element) @private {
    if (element_font_set(load.ui, element) == UI_NONE) return fail_at(load, "font", UNKNOWN_ASSET)~;
}

fn uint element_font_set(Ui* ui, UiElement* element) @private {
    if (has_property(element.mask, FONT_SET)) return element.properties.font_set;
    if (element.style == UI_NONE) return UI_NONE;
    return ui.styles.styles[element.style].base.font_set;
}

fn uint? read_action(UiLoad* load, Object* value) @private {
    String name = read_word(load, value)!;
    for (uint index = 0; index < load.ui.action_count; index++) {
        if (load.ui.actions[index].name == name) return index;
    }
    return fail_load(load, UNKNOWN_ACTION)~;
}

fn Vec4? read_uv(UiLoad* load, Object* value) @private {
    if (!value.is_array() || value.get_len() != 4) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    float[4] uv;
    for (usz index = 0; index < 4; index++) {
        push_index(load, index);
        uv[index] = (float)read_number(load, value.get_at((sz)index))!;
        pop_token(load);
    }
    return { uv[0], uv[1], uv[2], uv[3] };
}

fn String binding_name(String text) @private {
    if (text.len < 3 || text[0] != '{' || text[^1] != '}') return "";
    String name = text[1 : text.len - 2];
    foreach (character : name) {
        if (character == '{' || character == '}' || character == ':') return "";
    }
    return name;
}

fn uint? read_binding(UiLoad* load, Object* value, UiValueKind kind) @private {
    String name = binding_name(read_word(load, value)!);
    if (!name.len) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    uint binding = resolve_binding(load, name)!;
    if (load.ui.bindings[binding].kind != kind) return fail_load(load, BINDING_KIND_MISMATCH)~;
    return binding;
}

fn UiRef? read_bool_ref(UiLoad* load, Object* value) @private {
    if (value.is_bool()) return { .binding = UI_NONE, .literal = value.b ? 1 : 0 };
    return { .binding = read_binding(load, value, BOOL)! };
}

fn UiRef? read_number_ref(UiLoad* load, Object* value, UiValueKind only = FLOAT) @private {
    if (!value.is_string()) {
        double number = read_number(load, value)!;
        if (!math::is_finite(number)) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
        if (only == INT && number != math::floor(number)) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
        return { .binding = UI_NONE, .literal = (float)number };
    }
    String name = binding_name(value.s);
    if (!name.len) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    uint binding = resolve_binding(load, name)!;
    UiValueKind kind = load.ui.bindings[binding].kind;
    if (kind != INT && (only == INT || kind != FLOAT)) return fail_load(load, BINDING_KIND_MISMATCH)~;
    return { .binding = binding };
}

fn uint? resolve_binding(UiLoad* load, String name) @private {
    Ui* ui = load.ui;
    for (uint index = 0; index < ui.binding_count; index++) {
        UiBinding* binding = &ui.bindings[index];
        if (binding.name != name) continue;
        if (binding.list == UI_NONE) return index;
        uint level = binding.level - 1;
        if (level < load.list_depth && load.lists[level] == binding.list) return index;
        break;
    }
    return fail_load(load, UNKNOWN_BINDING)~;
}

fn void? read_template(
    UiLoad* load,
    Object* value,
    uint* first,
    uint* count,
) @private {
    String text = read_word(load, value)!;
    *first = (uint)load.segments.len();
    usz literal_start;
    usz cursor;
    while (cursor < text.len) {
        char character = text[cursor];
        bool doubled = cursor + 1 < text.len && text[cursor + 1] == character;
        if (character == '}' && doubled) {
            push_literal(load, text[literal_start : cursor + 1 - literal_start]);
            cursor += 2;
            literal_start = cursor;
            continue;
        }
        if (character != '{') {
            cursor++;
            continue;
        }
        if (doubled) {
            push_literal(load, text[literal_start : cursor + 1 - literal_start]);
            cursor += 2;
            literal_start = cursor;
            continue;
        }
        push_literal(load, text[literal_start : cursor - literal_start]);
        usz close = cursor + 1;
        while (close < text.len && text[close] != '}') close++;
        if (close == text.len) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
        String inner = text[cursor + 1 : close - cursor - 1];
        uint decimals = UI_DEFAULT_DECIMALS;
        usz colon = (usz)(inner.index_of_char(':') ?? (sz)inner.len);
        if (colon < inner.len) {
            String digits = inner[colon + 1..];
            if (digits.len != 1 || digits[0] < '0' || digits[0] > '0' + UI_MAX_TEMPLATE_DECIMALS) {
                return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
            }
            decimals = digits[0] - '0';
        }
        uint binding = resolve_binding(load, inner[:colon])!;
        UiValueKind kind = load.ui.bindings[binding].kind;
        if (kind == IMAGE || kind == LIST) return fail_load(load, BINDING_KIND_MISMATCH)~;
        load.segments.push({ .binding = binding, .decimals = decimals });
        cursor = close + 1;
        literal_start = cursor;
    }
    push_literal(load, text[literal_start : text.len - literal_start]);
    *count = (uint)load.segments.len() - *first;
}

fn void push_literal(UiLoad* load, String bytes) @private {
    if (!bytes.len) return;
    load.segments.push({
        .binding  = UI_NONE,
        .offset   = (uint)load.strings.len(),
        .length   = (uint)bytes.len,
        .decimals = UI_DEFAULT_DECIMALS,
    });
    load.strings.append(bytes);
}

fn usz find_style_index(UiStyleSet* set, String name) @private {
    usz low = 0;
    usz high = set.styles.len;
    while (low < high) {
        usz middle = (low + high) / 2;
        int order = set.styles[middle].name.compare_to(name);
        if (order == 0) return middle;
        if (order < 0) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return set.styles.len;
}

fn void? rebind_documents(Ui* ui, UiStyleSet* set) @private {
    UiStyleSet old = ui.styles;
    foreach (&document : ui.documents.items) {
        if (!document.live) continue;
        foreach (uint index, &element : document.elements) {
            if (!element.style_length) continue;
            String name = document.strings[element.style_offset : element.style_length];
            if (find_style_index(set, name) == set.styles.len) {
                return fail_in_document(
                    ui:       ui,
                    document: document,
                    element:  index,
                    key:      "style",
                    excuse:   UNKNOWN_STYLE,
                )~;
            }
        }
    }
    foreach (&document : ui.documents.items) {
        if (!document.live) continue;
        foreach (uint index, &element : document.elements) {
            if (!element.style_length) continue;
            String name = document.strings[element.style_offset : element.style_length];
            element.style = (uint)find_style_index(set, name);
        }
    }
    ui.styles = *set;
    foreach (&document : ui.documents.items) {
        if (!document.live) continue;
        foreach (uint index, &element : document.elements) {
            if ((element.kind == LABEL || element.kind == TEXT_FIELD) && element_font_set(ui, element) == UI_NONE) {
                restore_styles(ui, &old);
                return fail_in_document(
                    ui:       ui,
                    document: document,
                    element:  index,
                    key:      "font",
                    excuse:   UNKNOWN_ASSET,
                )~;
            }
        }
    }
    ui.styles = old;
    invalidate_frame(ui);
}

fn void restore_styles(Ui* ui, UiStyleSet* old) @private {
    ui.styles = *old;
    foreach (&document : ui.documents.items) {
        if (!document.live) continue;
        foreach (&element : document.elements) {
            if (!element.style_length) continue;
            String name = document.strings[element.style_offset : element.style_length];
            element.style = (uint)find_style_index(old, name);
        }
    }
}

fn fault fail_in_document(
    Ui* ui,
    UiDocument* document,
    uint element,
    String key,
    fault excuse,
) @private {
    UiLoad load = { .ui = ui };
    element_pointer(&load, document, element);
    push_token(&load, key);
    ui.load_error_document = document.id;
    return fail_load(&load, excuse);
}

fn void element_pointer(UiLoad* load, UiDocument* document, uint element) @private {
    UiElement* record = &document.elements[element];
    if (record.parent == UI_NONE) {
        push_token(load, "root");
        return;
    }
    element_pointer(load, document, record.parent);
    UiElement* parent = &document.elements[record.parent];
    if (parent.template == element) {
        push_token(load, "template");
        return;
    }
    usz child_index;
    for (uint child = parent.first_child; child != element; child = document.elements[child].next_sibling) {
        child_index++;
    }
    push_token(load, "children");
    push_index(load, child_index);
}
