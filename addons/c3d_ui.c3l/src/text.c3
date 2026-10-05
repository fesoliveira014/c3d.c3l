module c3d::ui;

import c3d;
import c3d::asset;
import clay;
import std::core::string;
import std::io;
import std::math;

const uint UI_CACHE_SEGMENTS_PER_LINE @private = 4;
const uint UI_CACHE_BYTES_PER_LINE @private = 32; // HUD lines average well below; long lines borrow from short ones
const uint UI_FLOAT_DECIMALS @private = 2;
const usz UI_NUMBER_BYTES @private = 64;
const String[UI_MAX_TEMPLATE_DECIMALS + 1] UI_FIXED_FORMATS @private = {
    "%.0f",
    "%.1f",
    "%.2f",
    "%.3f",
    "%.4f",
    "%.5f",
    "%.6f",
};

struct UiPlacementLine @private {
    ulong hash;
    uint  font_set;
    uint  offset;        // bytes in the cache's text arena
    uint  length;
    uint  first_segment;
    uint  segment_count;
}

struct UiPlacementSegment @private {
    FontId font;
    uint   first;  // placements in the cache's glyph arena
    uint   count;
    float  x_em;   // pen offset of the segment at size 1
}

struct UiPlacementCache @private {
    UiPlacementLine[]    lines;
    uint                 line_count;
    uint[]               slots;     // open addressing: line index plus one, zero when empty
    UiPlacementSegment[] segments;
    uint                 segment_count;
    GlyphPlacement[]     glyphs;
    uint                 glyph_count;
    char[]               bytes;
    uint                 byte_count;
}

fn String? expand_template(
    Ui* ui,
    UiDocument* document,
    uint first,
    uint count,
    UiScope* scope,
) @private {
    uint start = ui.text_used;
    for (uint index = first; index < first + count; index++) {
        UiSegment* segment = &document.segments[index];
        if (segment.binding == UI_NONE) {
            append_text(ui, document.strings[segment.offset : segment.length])!;
            continue;
        }
        UiValue value = call_getter(ui, segment.binding, scope);
        append_value(ui, value, segment.decimals)!;
    }
    String text = (String)ui.text[start : ui.text_used - start];
    if (!valid_utf8(text)) return c3d::INVALID_ARGUMENT~;
    return text;
}

fn String? copy_text(Ui* ui, String text) @private {
    uint start = ui.text_used;
    append_text(ui, text)!;
    String copy = (String)ui.text[start : text.len];
    if (!valid_utf8(copy)) return c3d::INVALID_ARGUMENT~;
    return copy;
}

fn UiValue call_getter(Ui* ui, uint binding_index, UiScope* scope) @private {
    UiBinding* binding = &ui.bindings[binding_index];
    UiScope truncated = *scope;
    truncated.depth = binding.level;
    ui.stats.getter_calls++;
    return binding.getter(binding.user, &truncated);
}

fn void? append_text(Ui* ui, String text) @private {
    if (text.len > ui.text.len - ui.text_used) return c3d::CAPACITY_EXCEEDED~;
    ui.text[ui.text_used : text.len] = text[..];
    ui.text_used += (uint)text.len;
    ui.stats.text_bytes = ui.text_used;
}

fn void? append_value(Ui* ui, UiValue value, uint decimals) @private {
    char[UI_NUMBER_BYTES] buffer;
    switch (value.kind) {
        case BOOL:
            append_text(ui, value.boolean ? "true" : "false")!;
        case TEXT:
            append_text(ui, value.text)!;
        case INT:
            if (decimals == UI_DEFAULT_DECIMALS) {
                append_text(ui, (String)io::bprintf(buffer[..], "%d", value.integer)!!)!;
            } else {
                append_text(ui, format_fixed(buffer[..], (double)value.integer, decimals))!;
            }
        case FLOAT:
            if (decimals == UI_DEFAULT_DECIMALS) {
                append_text(ui, trim_decimals(format_fixed(buffer[..], value.number, UI_FLOAT_DECIMALS)))!;
            } else {
                append_text(ui, format_fixed(buffer[..], value.number, decimals))!;
            }
        case IMAGE:
        case LIST:
            break;
    }
}

fn String format_fixed(char[] buffer, double number, uint decimals) @private {
    return (String)io::bprintf(buffer, UI_FIXED_FORMATS[decimals], number)!!;
}

fn String trim_decimals(String text) @private {
    if (!text.contains(".")) return text;
    usz end = text.len;
    while (end > 0 && text[end - 1] == '0') end--;
    if (end > 0 && text[end - 1] == '.') end--;
    return text[:end];
}

fn bool valid_utf8(String text) @private {
    usz offset;
    while (offset < text.len) {
        sz size = (sz)(text.len - offset);
        if (catch conv::utf8_to_char32(&text[offset], &size)) return false;
        offset += (usz)size;
    }
    return true;
}

fn Char32 decode_at(String text, usz* offset) @private {
    sz size = (sz)(text.len - *offset);
    Char32 code_point = conv::utf8_to_char32(&text[*offset], &size) ?? 0xFFFD;
    *offset += (usz)size;
    return code_point;
}

fn FontId segment_font(Ui* ui, UiFontSet* set, Char32 code_point) @private {
    for (uint index = 0; index < set.count; index++) {
        if (@ok(ui.assets.find_glyph(set.fonts[index], code_point))) return set.fonts[index];
    }
    return set.fonts[0];
}

<*
 Call body once per run of code points that share a font.
*>
macro void @each_segment(Ui* ui, UiFontSet* set, String text; @body(FontId font, String segment)) @private {
    usz start;
    usz offset;
    FontId current;
    while (offset < text.len) {
        usz at = offset;
        FontId font = segment_font(ui, set, decode_at(text, &offset));
        if (at > start && !c3d::same_id(font, current)) {
            @body(current, text[start : at - start]);
            start = at;
        }
        current = font;
    }
    if (offset > start) @body(current, text[start : offset - start]);
}

fn float measure_line(Ui* ui, uint font_set, String text, float font_size) @private {
    UiFontSet* set = &ui.font_sets[font_set];
    float width;
    @each_segment(ui, set, text; FontId font, String segment) {
        width += (ui.assets.measure_text(font, segment, font_size) ?? (TextExtent){}).width;
    };
    return width;
}

fn float line_height(Ui* ui, UiProperties* properties) @private {
    if (properties.line_height > 0) return math::round(properties.line_height);
    FontMetrics metrics = ui.assets.font_metrics(ui.font_sets[properties.font_set].fonts[0]);
    return math::round((metrics.ascent - metrics.descent + metrics.line_gap) * properties.font_size);
}

fn clay::Dimensions measure_clay_text(clay::CharsSlice text, clay::TextElementConfig* config, void* user) @private {
    Ui* ui = user;
    return {
        .width  = measure_line(
            ui:        ui,
            font_set:  config.font_id,
            text:      text.str(),
            font_size: config.font_size,
        ),
        .height = config.line_height,
    };
}

fn fault place_segment(Ui* ui, FontId font, String segment, float* x_em) @private {
    UiPlacementCache* cache = &ui.cache;
    if (cache.segment_count == cache.segments.len) return c3d::CAPACITY_EXCEEDED;
    usz? placed = ui.assets.place_text(font, segment, cache.glyphs[cache.glyph_count..]);
    if (catch excuse = placed) return excuse;
    cache.segments[cache.segment_count] = {
        .font  = font,
        .first = cache.glyph_count,
        .count = (uint)placed,
        .x_em  = *x_em,
    };
    cache.segment_count++;
    cache.glyph_count += (uint)placed;
    *x_em += (ui.assets.measure_text(font, segment, 1) ?? (TextExtent){}).width;
    return {};
}

fn ulong line_hash(uint font_set, String text) @private {
    ulong hash = 0xcbf2_9ce4_8422_2325;
    hash = (hash ^ font_set) * 0x100_0000_01b3;
    foreach (character : text) hash = (hash ^ character) * 0x100_0000_01b3;
    return hash;
}

fn void clear_cache(UiPlacementCache* cache) @private {
    cache.line_count = 0;
    cache.segment_count = 0;
    cache.glyph_count = 0;
    cache.byte_count = 0;
    cache.slots[..] = 0;
}

fn UiPlacementLine*? cached_line(Ui* ui, uint font_set, String text) @private {
    UiPlacementCache* cache = &ui.cache;
    ulong hash = line_hash(font_set, text);
    usz slot = (usz)(hash % (usz)cache.slots.len);
    while (cache.slots[slot]) {
        UiPlacementLine* line = &cache.lines[cache.slots[slot] - 1];
        if (line.hash == hash && line.font_set == font_set && cache_bytes(cache, line) == text) {
            ui.stats.placement_hits++;
            return line;
        }
        slot = (slot + 1) % (usz)cache.slots.len;
    }
    ui.stats.placement_misses++;
    if (try line = insert_line(
        ui:       ui,
        font_set: font_set,
        text:     text,
        hash:     hash,
    )) return line;
    clear_cache(cache);
    ui.stats.placement_clears++;
    return insert_line(
        ui:       ui,
        font_set: font_set,
        text:     text,
        hash:     hash,
    );
}

fn String cache_bytes(UiPlacementCache* cache, UiPlacementLine* line) @private {
    return (String)cache.bytes[line.offset : line.length];
}

fn UiPlacementLine*? insert_line(Ui* ui, uint font_set, String text, ulong hash) @private {
    UiPlacementCache* cache = &ui.cache;
    if (cache.line_count == cache.lines.len || text.len > cache.bytes.len - cache.byte_count) {
        return c3d::CAPACITY_EXCEEDED~;
    }
    if (text.len > cache.glyphs.len - cache.glyph_count) return c3d::CAPACITY_EXCEEDED~;

    UiPlacementLine line = {
        .hash          = hash,
        .font_set      = font_set,
        .offset        = cache.byte_count,
        .length        = (uint)text.len,
        .first_segment = cache.segment_count,
    };
    float x_em;
    UiFontSet* set = &ui.font_sets[font_set];
    fault failure;
    @each_segment(ui, set, text; FontId font, String segment) {
        if (!failure) failure = place_segment(
            ui:      ui,
            font:    font,
            segment: segment,
            x_em:    &x_em,
        );
    };
    if (failure) return failure~;

    line.segment_count = cache.segment_count - line.first_segment;
    cache.bytes[cache.byte_count : text.len] = text[..];
    cache.byte_count += (uint)text.len;
    cache.lines[cache.line_count] = line;
    cache.line_count++;
    usz slot = (usz)(hash % (usz)cache.slots.len);
    while (cache.slots[slot]) slot = (slot + 1) % (usz)cache.slots.len;
    cache.slots[slot] = cache.line_count;
    return &cache.lines[cache.line_count - 1];
}
