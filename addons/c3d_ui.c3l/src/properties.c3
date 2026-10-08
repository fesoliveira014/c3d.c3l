module c3d::ui;

import c3d;
import c3d::asset;
import std::collections::object;
import std::math;

const uint UI_DEFAULT_FONT_SIZE @private = 16;

const UiProperties UI_PROPERTIES_DEFAULT @private = {
    .text_color = { 1, 1, 1, 1 },
    .font_size  = UI_DEFAULT_FONT_SIZE,
    .max_width  = float::max,
    .max_height = float::max,
    .font_set   = UI_NONE,
};

enum UiSizing @private {
    FIT,
    GROW,
    FIXED,
    PERCENT,
}

enum UiDirection @private {
    ROW,
    COLUMN,
}

enum UiAlign @private {
    START,
    CENTER,
    END,
}

enum UiWrap @private {
    WORDS,
    NEWLINES,
    NONE,
}

enum UiTextAlign @private {
    LEFT,
    CENTER,
    RIGHT,
}

enum UiProperty @private {
    FILL,
    BORDER_WIDTHS,
    BORDER_COLOR,
    CORNER_RADII,
    PADDING,
    GAP,
    WIDTH,
    HEIGHT,
    MIN_WIDTH,
    MIN_HEIGHT,
    MAX_WIDTH,
    MAX_HEIGHT,
    DIRECTION,
    ALIGN_X,
    ALIGN_Y,
    FONT_SET,
    FONT_SIZE,
    TEXT_COLOR,
    LINE_HEIGHT,
    WRAP,
    TEXT_ALIGN,
    SKIN,
    BAR_FILL,
    BAR_SKIN,
    HIGHLIGHT,
}

struct UiSize @private {
    UiSizing sizing;
    float    value;  // layout units for FIXED, a fraction for PERCENT
}

struct UiSkin @private {
    TextureId image; // zero: no skin
    Vec4      slice; // texels: left, top, right, bottom
}

struct UiProperties @private {
    Vec4        fill;          // sRGB, straight alpha
    Vec4        border_widths; // layout units: left, top, right, bottom
    Vec4        border_color;
    Vec4        corner_radii;  // layout units: top left, top right, bottom right, bottom left
    Vec4        padding;       // layout units: left, top, right, bottom
    float       gap;
    UiSize      width;
    UiSize      height;
    float       min_width;
    float       min_height;
    float       max_width;
    float       max_height;
    UiDirection direction;
    UiAlign     align_x;
    UiAlign     align_y;
    uint        font_set;      // index in Ui.font_sets, UI_NONE without a font
    float       font_size;     // whole layout units
    Vec4        text_color;
    float       line_height;   // zero: the first font's
    UiWrap      wrap;
    UiTextAlign text_align;
    UiSkin      skin;
    Vec4        bar_fill;
    UiSkin      bar_skin;
    Vec4        highlight;
}

macro ulong @property_bit(UiProperty property) @private => 1ul << property.ordinal;

fn bool has_property(ulong mask, UiProperty property) @private => (mask & @property_bit(property)) != 0;

fn void apply_properties(
    UiProperties* target,
    ulong* target_mask,
    UiProperties* source,
    ulong source_mask,
) @private {
    for (usz index = 0; index < UiProperty::len; index++) {
        UiProperty property = UiProperty::from_ordinal(index);
        if (!has_property(source_mask, property)) continue;
        switch (property) {
            case FILL: target.fill = source.fill;
            case BORDER_WIDTHS: target.border_widths = source.border_widths;
            case BORDER_COLOR: target.border_color = source.border_color;
            case CORNER_RADII: target.corner_radii = source.corner_radii;
            case PADDING: target.padding = source.padding;
            case GAP: target.gap = source.gap;
            case WIDTH: target.width = source.width;
            case HEIGHT: target.height = source.height;
            case MIN_WIDTH: target.min_width = source.min_width;
            case MIN_HEIGHT: target.min_height = source.min_height;
            case MAX_WIDTH: target.max_width = source.max_width;
            case MAX_HEIGHT: target.max_height = source.max_height;
            case DIRECTION: target.direction = source.direction;
            case ALIGN_X: target.align_x = source.align_x;
            case ALIGN_Y: target.align_y = source.align_y;
            case FONT_SET: target.font_set = source.font_set;
            case FONT_SIZE: target.font_size = source.font_size;
            case TEXT_COLOR: target.text_color = source.text_color;
            case LINE_HEIGHT: target.line_height = source.line_height;
            case WRAP: target.wrap = source.wrap;
            case TEXT_ALIGN: target.text_align = source.text_align;
            case SKIN: target.skin = source.skin;
            case BAR_FILL: target.bar_fill = source.bar_fill;
            case BAR_SKIN: target.bar_skin = source.bar_skin;
            case HIGHLIGHT: target.highlight = source.highlight;
        }
    }
    *target_mask |= source_mask;
}

fn bool? read_property(
    UiLoad* load,
    String key,
    Object* value,
    UiProperties* target,
    ulong* mask,
) @private {
    switch (key) {
        case "fill":
            target.fill = read_color(load, value)!;
            *mask |= @property_bit(FILL);
        case "text_color":
            target.text_color = read_color(load, value)!;
            *mask |= @property_bit(TEXT_COLOR);
        case "bar_fill":
            target.bar_fill = read_color(load, value)!;
            *mask |= @property_bit(BAR_FILL);
        case "highlight":
            target.highlight = read_color(load, value)!;
            *mask |= @property_bit(HIGHLIGHT);
        case "border":
            read_border(
                load:   load,
                value:  value,
                target: target,
                mask:   mask,
            )!;
        case "radius":
            target.corner_radii = read_sides(load, value, false)!;
            *mask |= @property_bit(CORNER_RADII);
        case "padding":
            target.padding = read_sides(load, value, true)!;
            *mask |= @property_bit(PADDING);
        case "gap":
            target.gap = read_length(load, value)!;
            *mask |= @property_bit(GAP);
        case "width":
            target.width = read_size(load, value)!;
            *mask |= @property_bit(WIDTH);
        case "height":
            target.height = read_size(load, value)!;
            *mask |= @property_bit(HEIGHT);
        case "size":
            if (!value.is_array() || value.get_len() != 2) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
            target.width = read_size(load, value.get_at(0), "0")!;
            target.height = read_size(load, value.get_at(1), "1")!;
            *mask |= @property_bit(WIDTH) | @property_bit(HEIGHT);
        case "min_width":
            target.min_width = read_length(load, value)!;
            *mask |= @property_bit(MIN_WIDTH);
        case "min_height":
            target.min_height = read_length(load, value)!;
            *mask |= @property_bit(MIN_HEIGHT);
        case "max_width":
            target.max_width = read_length(load, value)!;
            *mask |= @property_bit(MAX_WIDTH);
        case "max_height":
            target.max_height = read_length(load, value)!;
            *mask |= @property_bit(MAX_HEIGHT);
        case "direction":
            switch (read_word(load, value)!) {
                case "row": target.direction = ROW;
                case "column": target.direction = COLUMN;
                default: return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
            }
            *mask |= @property_bit(DIRECTION);
        case "align":
            read_align(load, value, target)!;
            *mask |= @property_bit(ALIGN_X) | @property_bit(ALIGN_Y);
        case "font":
            target.font_set = read_font_set(load, value)!;
            *mask |= @property_bit(FONT_SET);
        case "font_size":
            target.font_size = math::round(read_length(load, value)!);
            *mask |= @property_bit(FONT_SIZE);
        case "line_height":
            target.line_height = read_length(load, value)!;
            *mask |= @property_bit(LINE_HEIGHT);
        case "wrap":
            switch (read_word(load, value)!) {
                case "words": target.wrap = WORDS;
                case "newlines": target.wrap = NEWLINES;
                case "none": target.wrap = NONE;
                default: return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
            }
            *mask |= @property_bit(WRAP);
        case "text_align":
            switch (read_word(load, value)!) {
                case "left": target.text_align = LEFT;
                case "center": target.text_align = CENTER;
                case "right": target.text_align = RIGHT;
                default: return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
            }
            *mask |= @property_bit(TEXT_ALIGN);
        case "skin":
            target.skin = read_skin(load, value)!;
            *mask |= @property_bit(SKIN);
        case "bar_skin":
            target.bar_skin = read_skin(load, value)!;
            *mask |= @property_bit(BAR_SKIN);
        default:
            return false;
    }
    return true;
}

fn double? read_number(UiLoad* load, Object* value) @private {
    if (value.is_int()) return (double)value.i;
    if (value.is_float()) return value.f;
    return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
}

fn float? read_length(UiLoad* load, Object* value) @private {
    double number = read_number(load, value)!;
    if (number < 0 || !math::is_finite(number)) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    return (float)number;
}

fn String? read_word(UiLoad* load, Object* value) @private {
    if (!value.is_string()) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    return value.s;
}

fn Vec4? read_color(UiLoad* load, Object* value) @private {
    String text = read_word(load, value)!;
    if ((text.len != 7 && text.len != 9) || text[0] != '#') return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    float[4] channels = { 0, 0, 0, 1 };
    for (usz channel = 0; channel < (text.len - 1) / 2; channel++) {
        int high = hex_digit(text[1 + 2 * channel]);
        int low = hex_digit(text[2 + 2 * channel]);
        if (high < 0 || low < 0) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
        channels[channel] = (float)(high * 16 + low) / 255;
    }
    return { channels[0], channels[1], channels[2], channels[3] };
}

fn int hex_digit(char digit) @private {
    switch {
        case digit >= '0' && digit <= '9': return digit - '0';
        case digit >= 'a' && digit <= 'f': return digit - 'a' + 10;
        case digit >= 'A' && digit <= 'F': return digit - 'A' + 10;
        default: return -1;
    }
}

fn Vec4? read_sides(UiLoad* load, Object* value, bool allow_pair) @private {
    if (!value.is_array()) {
        float all = read_length(load, value)!;
        return { all, all, all, all };
    }
    float[4] lengths;
    usz count = (usz)value.get_len();
    if (count != 4 && !(allow_pair && count == 2)) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    for (usz index = 0; index < count; index++) {
        push_index(load, index);
        lengths[index] = read_length(load, value.get_at((sz)index))!;
        pop_token(load);
    }
    if (count == 2) return { lengths[0], lengths[1], lengths[0], lengths[1] };
    return { lengths[0], lengths[1], lengths[2], lengths[3] };
}

fn UiSize? read_size(UiLoad* load, Object* value, String token = "") @private {
    if (token.len) push_token(load, token);
    defer if (token.len) pop_token(load);
    if (!value.is_string()) return { .sizing = FIXED, .value = read_length(load, value)! };
    String word = value.s;
    if (word == "fit") return { .sizing = FIT };
    if (word == "grow") return { .sizing = GROW };
    if (word.len < 2 || word[^1] != '%') return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    double percent = word[:word.len - 1].to_double() ?? -1;
    if (percent < 0 || percent > 100) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    return { .sizing = PERCENT, .value = (float)(percent / 100) };
}

fn void? read_border(
    UiLoad* load,
    Object* value,
    UiProperties* target,
    ulong* mask,
) @private {
    if (!value.is_map()) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    String[] keys = sorted_keys(value);
    foreach (key : keys) {
        push_token(load, key);
        Object* entry = value.get(key)!!;
        switch (key) {
            case "width":
                target.border_widths = read_sides(load, entry, false)!;
                *mask |= @property_bit(BORDER_WIDTHS);
            case "color":
                target.border_color = read_color(load, entry)!;
                *mask |= @property_bit(BORDER_COLOR);
            default:
                return fail_load(load, UNKNOWN_PROPERTY)~;
        }
        pop_token(load);
    }
}

fn void? read_align(UiLoad* load, Object* value, UiProperties* target) @private {
    if (!value.is_array() || value.get_len() != 2) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    push_index(load, 0);
    switch (read_word(load, value.get_at(0))!) {
        case "left": target.align_x = START;
        case "center": target.align_x = CENTER;
        case "right": target.align_x = END;
        default: return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    }
    pop_token(load);
    push_index(load, 1);
    switch (read_word(load, value.get_at(1))!) {
        case "top": target.align_y = START;
        case "center": target.align_y = CENTER;
        case "bottom": target.align_y = END;
        default: return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    }
    pop_token(load);
}

fn uint? read_font_set(UiLoad* load, Object* value) @private {
    UiFontSet set;
    if (value.is_string()) {
        set.fonts[0] = find_font_key(load, value.s)!;
        set.count = 1;
    } else {
        if (!value.is_array() || !value.get_len() || (usz)value.get_len() > UI_FONT_FALLBACKS) {
            return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
        }
        for (usz index = 0; index < (usz)value.get_len(); index++) {
            push_index(load, index);
            set.fonts[index] = find_font_key(load, read_word(load, value.get_at((sz)index))!)!;
            pop_token(load);
        }
        set.count = (uint)value.get_len();
    }
    return intern_font_set(load.ui, &set) ?? fail_load(load, c3d::CAPACITY_EXCEEDED)~;
}

fn FontId? find_font_key(UiLoad* load, String key) @private {
    return load.ui.assets.find_font(key) ?? fail_load(load, UNKNOWN_ASSET)~;
}

fn TextureId? find_texture_key(UiLoad* load, String key) @private {
    return load.ui.assets.find_texture(key) ?? fail_load(load, UNKNOWN_ASSET)~;
}

fn UiSkin? read_skin(UiLoad* load, Object* value) @private {
    if (!value.is_map()) return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    UiSkin skin;
    bool has_image;
    foreach (key : sorted_keys(value)) {
        push_token(load, key);
        Object* entry = value.get(key)!!;
        switch (key) {
            case "image":
                skin.image = find_texture_key(load, read_word(load, entry)!)!;
                has_image = true;
            case "slice":
                skin.slice = read_sides(load, entry, false)!;
            default:
                return fail_load(load, UNKNOWN_PROPERTY)~;
        }
        pop_token(load);
    }
    if (!has_image) {
        push_token(load, "image");
        return fail_load(load, c3d::ASSET_FORMAT_ERROR)~;
    }
    return skin;
}

fn uint? intern_font_set(Ui* ui, UiFontSet* set) @private {
    for (uint index = 0; index < ui.font_set_count; index++) {
        UiFontSet* known = &ui.font_sets[index];
        if (known.count != set.count) continue;
        bool equal = true;
        for (uint font = 0; font < set.count; font++) {
            if (!c3d::same_id(known.fonts[font], set.fonts[font])) equal = false;
        }
        if (equal) return index;
    }
    if (ui.font_set_count == ui.font_sets.len) return c3d::CAPACITY_EXCEEDED~;
    ui.font_sets[ui.font_set_count] = *set;
    for (uint font = 0; font < set.count; font++) {
        ui.cache.font_replacements[ui.font_set_count * UI_FONT_FALLBACKS + font] =
            ui.assets.font(set.fonts[font]).header.replaced_revision;
    }
    ui.font_set_count++;
    return ui.font_set_count - 1;
}
