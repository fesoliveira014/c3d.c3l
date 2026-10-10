module c3d::asset;

import c3d;
import c3d::anim;
import std::collections::list;
import std::collections::map;
import std::collections::object;
import std::encoding::json;
import std::math;
import std::sort;

alias EventKeys @private = HashMap{String, bool};
alias EventFrames @private = List{EventJsonPhase};
alias ImportedEvents @private = List{ImportedEvent};

const uint IMPORTED_ID_DIGITS @private = 10; // Uint32 range; exponent handling never expands more digits.

enum EventJsonPhase @private {
    OBJECT_FIRST,
    OBJECT_KEY,
    OBJECT_VALUE,
    OBJECT_NEXT,
    ARRAY_FIRST,
    ARRAY_VALUE,
    ARRAY_NEXT,
}

struct EventJsonReader @private {
    String source;
    sz cursor;
}

struct EventInteger @private {
    uint value;
    bool integral;
    bool negative;
    bool overflow;
}

struct ImportedEvent @private {
    double time;
    uint id;
    sz ordinal;
}

<*
 Import event metadata from animation extras, ignoring unrelated fields.
 @param extras : "Raw animation extras JSON."
 @param duration : "Track-derived clip duration in seconds."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn ClipEvent[]? parse_gltf_clip_events(Allocator allocator, String extras, float duration) {
    @pool() {
        EventJsonReader reader = { .source = extras };
        event_json_space(&reader);
        if (event_json_peek(&reader) != '{') return {};
        reader.cursor++;
        String metadata;
        bool found;
        event_json_space(&reader);
        if (event_json_take(&reader, '}')) return {};

        while (true) {
            String key = event_json_key(&reader)!;
            event_json_expect(&reader, ':')!;
            sz start = reader.cursor;
            event_json_skip(&reader)!;
            if (key == "c3d_events") {
                if (found) return c3d::ASSET_FORMAT_ERROR~;
                metadata = extras[start:reader.cursor - start];
                found = true;
            }

            if (event_json_take(&reader, '}')) break;
            event_json_expect(&reader, ',')!;
        }
        event_json_end(&reader)!;

        if (!found) return {};
        return parse_clip_events(allocator, metadata, duration);
    };
}

<*
 Import a versioned event table with exact IDs and stable time order.
 @param source : "Raw inner event-schema JSON object."
 @param duration : "Track-derived clip duration in seconds."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn ClipEvent[]? parse_clip_events(Allocator allocator, String source, float duration) {
    @pool() {
        EventJsonReader reader = { .source = source };
        EventKeys keys;
        keys.tinit();
        bool has_version;
        bool unsupported;
        bool has_events;
        String events;

        event_json_expect(&reader, '{')!;
        if (!event_json_take(&reader, '}')) {
            while (true) {
                String key = event_schema_key(&reader, &keys)!;
                event_json_expect(&reader, ':')!;
                if (key == "version") {
                    EventInteger version = event_integer(event_json_number(&reader)!);
                    if (!version.integral) return c3d::ASSET_FORMAT_ERROR~;
                    unsupported = version.negative || version.overflow || version.value != 1;
                    has_version = true;
                } else {
                    sz start = reader.cursor;
                    event_json_skip(&reader)!;
                    if (key == "events") {
                        events = source[start:reader.cursor - start];
                        has_events = true;
                    }
                }

                if (event_json_take(&reader, '}')) break;
                event_json_expect(&reader, ',')!;
            }
        }
        event_json_end(&reader)!;

        if (!has_version) return c3d::ASSET_FORMAT_ERROR~;
        if (unsupported) return c3d::UNSUPPORTED~;
        if (!has_events || !math::is_finite(duration) || duration < 0) return c3d::ASSET_FORMAT_ERROR~;

        return parse_event_array(allocator, events, duration);
    };
}

fn ClipEvent[]? parse_event_array(Allocator allocator, String source, float duration) @local {
    EventJsonReader reader = { .source = source };
    ImportedEvents events;
    events.tinit();
    event_json_expect(&reader, '[')!;
    if (!event_json_take(&reader, ']')) {
        while (true) {
            ImportedEvent event = parse_event_entry(&reader, duration)!;
            event.ordinal = events.size;
            events.push(event);

            if (event_json_take(&reader, ']')) break;
            event_json_expect(&reader, ',')!;
        }
    }
    event_json_end(&reader)!;

    sort::quicksort(events.entries[:events.size], &compare_imported_events);
    ClipEvent[] result = alloc::new_array_try(allocator, ClipEvent, events.size)
      ?? c3d::CAPACITY_EXCEEDED~!;
    foreach (index, event : events.entries[:events.size]) {
        result[index] = { .time = (float)event.time, .id = event.id };
    }

    return result;
}

fn ImportedEvent? parse_event_entry(EventJsonReader* reader, float duration) @local {
    EventKeys keys;
    keys.tinit();
    ImportedEvent event;
    bool has_time;
    bool has_id;
    event_json_expect(reader, '{')!;
    if (!event_json_take(reader, '}')) {
        while (true) {
            String key = event_schema_key(reader, &keys)!;
            event_json_expect(reader, ':')!;
            if (key == "time") {
                String token = event_json_number(reader)!;
                double time = token.to_double() ?? c3d::ASSET_FORMAT_ERROR~!;
                if (!math::is_finite(time) || time < 0 || time > duration) return c3d::ASSET_FORMAT_ERROR~;
                event.time = time;
                has_time = true;
            } else if (key == "id") {
                EventInteger id = event_integer(event_json_number(reader)!);
                if (!id.integral || id.negative || id.overflow) return c3d::ASSET_FORMAT_ERROR~;
                event.id = id.value;
                has_id = true;
            } else {
                event_json_skip(reader)!;
            }

            if (event_json_take(reader, '}')) break;
            event_json_expect(reader, ',')!;
        }
    }

    if (!has_time || !has_id) return c3d::ASSET_FORMAT_ERROR~;
    return event;
}

fn int compare_imported_events(ImportedEvent first, ImportedEvent second) @local {
    if (first.time < second.time) return -1;
    if (first.time > second.time) return 1;
    if (first.ordinal < second.ordinal) return -1;
    return first.ordinal > second.ordinal ? 1 : 0;
}

fn EventInteger event_integer(String token) @local {
    bool negative = token[0] == '-';
    sz cursor = negative ? 1 : 0;
    sz digits;
    sz fractional;
    sz first_nonzero = token.len;
    sz last_nonzero;
    bool after_point;

    while (cursor < token.len && token[cursor] != 'e' && token[cursor] != 'E') {
        char value = token[cursor++];
        if (value == '.') {
            after_point = true;
            continue;
        }
        if (value != '0') {
            if (first_nonzero == token.len) first_nonzero = digits;
            last_nonzero = digits;
        }
        digits++;
        if (after_point) fractional++;
    }

    if (first_nonzero == token.len) return { .integral = true };

    sz exponent;
    bool exponent_negative;
    sz exponent_limit = token.len + IMPORTED_ID_DIGITS;
    if (cursor < token.len) {
        cursor++;
        if (token[cursor] == '+' || token[cursor] == '-') exponent_negative = token[cursor++] == '-';
        while (cursor < token.len) {
            uint digit = token[cursor++] - '0';
            exponent = exponent > (exponent_limit - digit) / 10
              ? exponent_limit : exponent * 10 + digit;
        }
    }
    if (exponent_negative) exponent = -exponent;

    int128 end = (int128)digits + exponent - fractional;
    if (end <= last_nonzero) return {};
    if (end - first_nonzero > IMPORTED_ID_DIGITS) {
        return { .integral = true, .negative = negative, .overflow = true };
    }

    ulong value;
    sz position;
    cursor = negative ? 1 : 0;
    while (position < digits && position < end) {
        char digit = token[cursor++];
        if (digit == '.') continue;
        if (position++ >= first_nonzero) value = value * 10 + digit - '0';
    }
    while (position++ < end) value *= 10;

    return {
        .value = (uint)value,
        .integral = true,
        .negative = negative,
        .overflow = value > uint::max,
    };
}

fn String? event_schema_key(EventJsonReader* reader, EventKeys* keys) @local {
    String key = event_json_key(reader)!;
    if (keys.has_key(key)) return c3d::ASSET_FORMAT_ERROR~;
    keys.set(key, true);
    return key;
}

fn String? event_json_key(EventJsonReader* reader) @local {
    event_json_space(reader);
    if (event_json_peek(reader) != '"') return c3d::ASSET_FORMAT_ERROR~;
    sz start = reader.cursor++;
    bool escaped;
    while (reader.cursor < reader.source.len) {
        char value = reader.source[reader.cursor++];
        if (escaped) {
            escaped = false;
        } else if (value == '\\') {
            escaped = true;
        } else if (value == '"') {
            String token = reader.source[start:reader.cursor - start];
            Object* parsed = json::tparse(token, JsonFlavor.JSON) ?? c3d::ASSET_FORMAT_ERROR~!;
            return parsed.s;
        }
    }
    return c3d::ASSET_FORMAT_ERROR~;
}

fn String? event_json_number(EventJsonReader* reader) @local {
    event_json_space(reader);
    sz start = reader.cursor;
    event_json_take_raw(reader, '-');
    if (event_json_take_raw(reader, '0')) {
        if (event_json_digit(event_json_peek(reader))) return c3d::ASSET_FORMAT_ERROR~;
    } else {
        if (!event_json_digit(event_json_peek(reader))) return c3d::ASSET_FORMAT_ERROR~;
        while (event_json_digit(event_json_peek(reader))) reader.cursor++;
    }
    if (event_json_take_raw(reader, '.')) {
        if (!event_json_digit(event_json_peek(reader))) return c3d::ASSET_FORMAT_ERROR~;
        while (event_json_digit(event_json_peek(reader))) reader.cursor++;
    }
    char next = event_json_peek(reader);
    if (next == 'e' || next == 'E') {
        reader.cursor++;
        next = event_json_peek(reader);
        if (next == '+' || next == '-') reader.cursor++;
        if (!event_json_digit(event_json_peek(reader))) return c3d::ASSET_FORMAT_ERROR~;
        while (event_json_digit(event_json_peek(reader))) reader.cursor++;
    }
    return reader.source[start:reader.cursor - start];
}

fn void? event_json_skip(EventJsonReader* reader) @local {
    EventFrames frames;
    frames.tinit();
    event_json_value(reader, &frames)!;

    while (frames.size) {
        EventJsonPhase* phase = &frames.entries[frames.size - 1];

        switch (*phase) {
            case OBJECT_FIRST:
                if (event_json_take(reader, '}')) {
                    frames.pop()!!;
                    continue;
                }

                *phase = OBJECT_KEY;
            case OBJECT_KEY:
                (void)event_json_key(reader)!;
                event_json_expect(reader, ':')!;

                *phase = OBJECT_VALUE;
            case OBJECT_VALUE:
                *phase = OBJECT_NEXT;

                event_json_value(reader, &frames)!;
            case OBJECT_NEXT:
                if (event_json_take(reader, '}')) {
                    frames.pop()!!;
                } else {
                    event_json_expect(reader, ',')!;
                    *phase = OBJECT_KEY;
                }
            case ARRAY_FIRST:
                if (event_json_take(reader, ']')) {
                    frames.pop()!!;
                    continue;
                }

                *phase = ARRAY_VALUE;
            case ARRAY_VALUE:
                *phase = ARRAY_NEXT;

                event_json_value(reader, &frames)!;
            case ARRAY_NEXT:
                if (event_json_take(reader, ']')) {
                    frames.pop()!!;
                } else {
                    event_json_expect(reader, ',')!;
                    *phase = ARRAY_VALUE;
                }
        }
    }
}

fn void? event_json_value(EventJsonReader* reader, EventFrames* frames) @local {
    event_json_space(reader);
    char value = event_json_peek(reader);
    switch (value) {
        case '{':
            reader.cursor++;
            frames.push(OBJECT_FIRST);
        case '[':
            reader.cursor++;
            frames.push(ARRAY_FIRST);
        case '"':
            (void)event_json_key(reader)!;
        case 't':
            event_json_literal(reader, "true")!;
        case 'f':
            event_json_literal(reader, "false")!;
        case 'n':
            event_json_literal(reader, "null")!;
        default:
            (void)event_json_number(reader)!;
    }
}

fn void? event_json_literal(EventJsonReader* reader, String literal) @local {
    if (reader.source.len - reader.cursor < literal.len
      || reader.source[reader.cursor:literal.len] != literal) return c3d::ASSET_FORMAT_ERROR~;
    reader.cursor += literal.len;
}

fn void event_json_space(EventJsonReader* reader) @local {
    while (reader.cursor < reader.source.len) {
        char value = reader.source[reader.cursor];
        if (value != ' ' && value != '\r' && value != '\n' && value != '\t') return;
        reader.cursor++;
    }
}

fn char event_json_peek(EventJsonReader* reader) @local {
    return reader.cursor < reader.source.len ? reader.source[reader.cursor] : 0;
}

fn bool event_json_take_raw(EventJsonReader* reader, char value) @local {
    if (event_json_peek(reader) != value) return false;
    reader.cursor++;
    return true;
}

fn bool event_json_take(EventJsonReader* reader, char value) @local {
    event_json_space(reader);
    if (event_json_peek(reader) != value) return false;
    reader.cursor++;
    return true;
}

fn void? event_json_expect(EventJsonReader* reader, char value) @local {
    if (!event_json_take(reader, value)) return c3d::ASSET_FORMAT_ERROR~;
}

fn bool event_json_digit(char value) @local => value >= '0' && value <= '9';

fn void? event_json_end(EventJsonReader* reader) @local {
    event_json_space(reader);
    if (reader.cursor != reader.source.len) return c3d::ASSET_FORMAT_ERROR~;
}
