module c3d::ui;

import c3d;
import std::collections::list;
import std::collections::object;
import std::encoding::json;
import std::io;
import std::math;
import std::sort;

const usz UI_STATE_BLOCKS @private = 4;
const String[UI_STATE_BLOCKS] UI_STATE_KEYS @private = { "focused", "hover", "pressed", "disabled" };

enum UiStyleVisit @private {
    UNSEEN,
    IN_PROGRESS,
    DONE,
}

struct UiStyle @private {
    String                         name;
    UiProperties                   base;
    ulong                          base_mask;
    UiProperties[UI_STATE_BLOCKS]  blocks;      // focused, hover, pressed, disabled
    ulong[UI_STATE_BLOCKS]         block_masks;
}

struct UiStyleSet @private {
    char[]    storage; // one allocation: styles, then names
    UiStyle[] styles;  // sorted by name
}

struct UiStyleSource @private {
    String        name;
    Object*       value;
    uint          sheet;
    UiStyleVisit  visit;
}

<*
 Replace the style set with ordered sheets, flattening inheritance.
 Later sheets override earlier styles of the same name; loaded documents re-resolve.
 @return? c3d::ASSET_FORMAT_ERROR, c3d::CAPACITY_EXCEEDED
 @return? UNKNOWN_PROPERTY, UNKNOWN_STYLE, STYLE_CYCLE, UNKNOWN_ASSET
 @return? json::UNEXPECTED_CHARACTER, json::INVALID_ESCAPE_SEQUENCE, json::INVALID_NUMBER
 @return? json::MAX_DEPTH_REACHED, io::EOF
*>
fn void? Ui.load_styles(&self, String[] sheets) {
    begin_load(self);
    @pool() {
        UiLoad load = { .ui = self };
        List{UiStyleSource} sources;
        sources.tinit();
        foreach (uint sheet_index, sheet : sheets) {
            Object* root = json::tparse(sheet, JSONC)!;
            push_index(&load, sheet_index);
            if (!root.is_map()) return fail_load(&load, c3d::ASSET_FORMAT_ERROR)~;
            foreach (name : sorted_keys(root)) {
                UiStyleSource source = { .name = name, .value = root.get(name)!!, .sheet = sheet_index };
                usz found = find_source(sources.array_view(), name);
                if (found == (usz)sources.len()) {
                    sources.push(source);
                } else {
                    sources[(sz)found] = source;
                }
            }
            pop_token(&load);
        }
        if ((usz)sources.len() > self.desc.max_styles) return c3d::CAPACITY_EXCEEDED~;
        UiStyleSource[] ordered = sources.array_view();
        sort::quicksort(ordered, &by_source_name);

        UiStyle[] flattened = mem::temp_array(UiStyle, ordered.len);
        foreach (usz index, &source : ordered) {
            visit_style(
                load:      &load,
                ordered:   ordered,
                flattened: flattened,
                index:     index,
            )!;
        }

        UiStyleSet set = build_style_set(self, flattened);
        if (catch excuse = rebind_documents(self, &set)) {
            free_style_set(self, &set);
            return excuse~;
        }
        free_style_set(self, &self.styles);
        self.styles = set;
    };
}

fn UiStyle*? find_style(Ui* ui, String name) @private {
    usz low = 0;
    usz high = ui.styles.styles.len;
    while (low < high) {
        usz middle = (low + high) / 2;
        int order = ui.styles.styles[middle].name.compare_to(name);
        if (order == 0) return &ui.styles.styles[middle];
        if (order < 0) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return NOT_FOUND~;
}

fn UiProperties style_properties(UiStyle* style, UiStateFlags state) @private {
    UiProperties properties = style.base;
    ulong mask = style.base_mask;
    bool[UI_STATE_BLOCKS] active = { state.focused, state.hovered, state.pressed, state.disabled };
    for (usz block = 0; block < UI_STATE_BLOCKS; block++) {
        if (active[block]) apply_properties(
            target:      &properties,
            target_mask: &mask,
            source:      &style.blocks[block],
            source_mask: style.block_masks[block],
        );
    }
    return properties;
}

fn void free_style_set(Ui* ui, UiStyleSet* set) @private {
    if (set.storage.ptr) alloc::free(ui.allocator, set.storage.ptr);
    *set = {};
}

fn usz find_source(UiStyleSource[] sources, String name) @private {
    foreach (usz index, source : sources) {
        if (source.name == name) return index;
    }
    return sources.len;
}

fn int by_source_name(UiStyleSource first, UiStyleSource second) @private => first.name.compare_to(second.name);

fn usz find_ordered(UiStyleSource[] ordered, String name) @private {
    foreach (usz index, source : ordered) {
        if (source.name == name) return index;
    }
    return ordered.len;
}

fn void? visit_style(
    UiLoad* load,
    UiStyleSource[] ordered,
    UiStyle[] flattened,
    usz index,
) @private {
    UiStyleSource* source = &ordered[index];
    if (source.visit == DONE) return;
    load.depth = 0;
    push_index(load, source.sheet);
    push_token(load, source.name);
    if (!source.value.is_map()) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    source.visit = IN_PROGRESS;

    UiStyle style = { .name = source.name, .base = UI_PROPERTIES_DEFAULT };
    if (try parent_value = source.value.get("extends")) {
        push_token(load, "extends");
        String parent_name = read_word(load, parent_value)!;
        usz parent = find_ordered(ordered, parent_name);
        if (parent == ordered.len) return fail_load(load, UNKNOWN_STYLE)~;
        if (ordered[parent].visit == IN_PROGRESS) return fail_load(load, STYLE_CYCLE)~;
        visit_style(
            load:      load,
            ordered:   ordered,
            flattened: flattened,
            index:     parent,
        )!;
        style = flattened[parent];
        style.name = source.name;
        load.depth = 0;
        push_index(load, source.sheet);
        push_token(load, source.name);
    }

    foreach (key : sorted_keys(source.value)) {
        if (key == "extends") continue;
        Object* value = source.value.get(key)!!;
        push_token(load, key);
        usz block = state_block(key);
        if (block < UI_STATE_BLOCKS) {
            read_state_block(
                load:   load,
                value:  value,
                target: &style.blocks[block],
                mask:   &style.block_masks[block],
            )!;
        } else if (!read_property(
            load:   load,
            key:    key,
            value:  value,
            target: &style.base,
            mask:   &style.base_mask,
        )!) {
            return fail_load(load, UNKNOWN_PROPERTY)~;
        }
        pop_token(load);
    }
    flattened[index] = style;
    source.visit = DONE;
}

fn usz state_block(String key) @private {
    foreach (usz block, name : UI_STATE_KEYS) {
        if (key == name) return block;
    }
    return UI_STATE_BLOCKS;
}

fn void? read_state_block(
    UiLoad* load,
    Object* value,
    UiProperties* target,
    ulong* mask,
) @private {
    if (!value.is_map()) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    UiProperties own;
    ulong own_mask;
    foreach (key : sorted_keys(value)) {
        push_token(load, key);
        if (!read_property(
            load:   load,
            key:    key,
            value:  value.get(key)!!,
            target: &own,
            mask:   &own_mask,
        )!) return fail_load(load, UNKNOWN_PROPERTY)~;
        pop_token(load);
    }
    apply_properties(
        target:      target,
        target_mask: mask,
        source:      &own,
        source_mask: own_mask,
    );
}

fn UiStyleSet build_style_set(Ui* ui, UiStyle[] flattened) @private {
    usz name_bytes;
    foreach (&style : flattened) name_bytes += style.name.len;
    usz names_at = flattened.len * UiStyle::size;
    usz total = names_at + name_bytes;
    if (!total) return {};

    Vec4[] block = alloc::new_array(ui.allocator, Vec4, (sz)((total + Vec4::size - 1) / Vec4::size));
    char[] storage = ((char*)block.ptr)[:block.len * Vec4::size];
    UiStyle[] styles = ((UiStyle*)storage.ptr)[:flattened.len];
    usz cursor = names_at;
    foreach (usz index, &style : flattened) {
        styles[index] = *style;
        storage[cursor : style.name.len] = style.name[..];
        styles[index].name = (String)storage[cursor : style.name.len];
        cursor += style.name.len;
    }
    return { .storage = storage, .styles = styles };
}
