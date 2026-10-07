module c3d::serial;

import c3d;

<*
 @require allocator.ptr != null, diagnostic != null, diagnostic.allocator.ptr != null
*>
fn TextDocument? parse_text(
    Allocator allocator,
    String source,
    TextLimits limits,
    SerialDiagnostic* diagnostic,
) @private {
    clear_serial_diagnostic(diagnostic);
    if (!text_limits_valid(limits)) {
        diagnostic.cause = c3d::INVALID_ARGUMENT;
        return c3d::INVALID_ARGUMENT~;
    }
    TextDocument document = { .allocator = allocator, .source = source };
    defer catch destroy_text_document(&document);
    TextParser measured = { .document = &document, .limits = limits, .diagnostic = diagnostic };
    if (source.len > limits.max_bytes) {
        return text_parser_error(&measured, c3d::CAPACITY_EXCEEDED, limits.max_bytes)~;
    }
    parse_text_pass(&measured)!;
    uint[] names;
    if (catch excuse = allocate_text_storage(
        document: &document,
        values: measured.next_value,
        strings: measured.next_string,
        named_values: measured.named_values,
        names: &names,
    )) {
        return text_parser_error(&measured, excuse, 0)~;
    }
    defer alloc::free(allocator, names.ptr);
    TextParser stored = {
        .document = &document,
        .limits = limits,
        .diagnostic = diagnostic,
        .names = names,
        .storing = true,
    };
    parse_text_pass(&stored)!;
    return document;
}

fn void? allocate_text_storage(
    TextDocument* document,
    uint values,
    usz strings,
    uint named_values,
    uint[]* names,
) @local {
    if (values > sz::max / TextValue::size || strings > sz::max) return c3d::CAPACITY_EXCEEDED~;
    document.values = alloc::new_array_try(document.allocator, TextValue, (sz)values)
      ?? c3d::CAPACITY_EXCEEDED~!;
    document.strings = alloc::new_array_try(document.allocator, char, (sz)strings)
      ?? c3d::CAPACITY_EXCEEDED~!;
    if (named_values) {
        usz buckets = 1;
        while (buckets < (usz)named_values * 2) buckets *= 2;
        if (buckets > sz::max / uint::size) return c3d::CAPACITY_EXCEEDED~;
        *names = alloc::new_array_try(document.allocator, uint, (sz)buckets)
          ?? c3d::CAPACITY_EXCEEDED~!;
    }
}

fn void? parse_text_pass(TextParser* parser) @local {
    (void)parse_text_value(
        parser: parser,
        parent: TEXT_NO_PARENT,
        index: 0,
        name: {},
        name_offset: 0,
    )!;
    skip_text_space(parser)!;
    if (parser.cursor != parser.document.source.len) {
        return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
    }
}

fn uint? text_utf8_width(TextParser* parser) @local {
    String source = parser.document.source;
    usz start = parser.cursor;
    uint first = source[start];
    uint count;
    uint scalar;
    uint minimum;
    if (first >= 0xc2 && first <= 0xdf) {
        count = 2;
        scalar = first & 0x1f;
        minimum = 0x80;
    } else if (first >= 0xe0 && first <= 0xef) {
        count = 3;
        scalar = first & 0x0f;
        minimum = 0x800;
    } else if (first >= 0xf0 && first <= 0xf4) {
        count = 4;
        scalar = first & 0x07;
        minimum = 0x10000;
    } else {
        return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, start)~;
    }
    for (uint index = 1; index < count; index++) {
        usz offset = start + index;
        if (offset == source.len) return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, offset)~;
        uint next = source[offset];
        if ((next & 0xc0) != 0x80) return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, offset)~;
        scalar = (scalar << 6) | (next & 0x3f);
    }
    if (scalar < minimum || scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) {
        return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, start)~;
    }
    return count;
}

fn void? skip_text_space(TextParser* parser) @local {
    String source = parser.document.source;
    while (parser.cursor < source.len) {
        char value = source[parser.cursor];
        if (value == ' ' || value == '\t' || value == '\r' || value == '\n') {
            parser.cursor++;
            continue;
        }
        if (value != '/' || parser.cursor + 1 == source.len) return;
        char next = source[parser.cursor + 1];
        if (next == '/') {
            parser.cursor += 2;
            while (parser.cursor < source.len && source[parser.cursor] != '\r' && source[parser.cursor] != '\n') {
                parser.cursor += source[parser.cursor] < 0x80 ? 1 : text_utf8_width(parser)!;
            }
            continue;
        }
        if (next != '*') return;
        parser.cursor += 2;
        bool closed;
        while (parser.cursor < source.len) {
            if (source[parser.cursor] == '*' && parser.cursor + 1 < source.len && source[parser.cursor + 1] == '/') {
                parser.cursor += 2;
                closed = true;
                break;
            }
            parser.cursor += source[parser.cursor] < 0x80 ? 1 : text_utf8_width(parser)!;
        }
        if (!closed) return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
    }
}

fn void? text_string_limit(TextParser* parser, usz start) @local {
    if (parser.cursor - start > parser.limits.max_string_bytes) {
        return text_parser_error(parser, c3d::CAPACITY_EXCEEDED, start + parser.limits.max_string_bytes)~;
    }
}

fn uint? parse_text_hex(TextParser* parser) @local {
    String source = parser.document.source;
    uint value;
    for (uint digit = 0; digit < 4; digit++) {
        if (parser.cursor == source.len) return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
        char next = source[parser.cursor];
        if (!((next >= '0' && next <= '9') || (next >= 'a' && next <= 'f') || (next >= 'A' && next <= 'F'))) {
            return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
        }
        value = (value << 4) | text_hex_digit(next);
        parser.cursor++;
    }
    return value;
}

fn uint? parse_text_escape(TextParser* parser, usz start) @local {
    String source = parser.document.source;
    if (parser.cursor == source.len) return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
    char escape = source[parser.cursor++];
    switch (escape) {
        case '"': return '"';
        case '\\': return '\\';
        case '/': return '/';
        case 'b': return '\b';
        case 'f': return '\f';
        case 'n': return '\n';
        case 'r': return '\r';
        case 't': return '\t';
        case 'u':
            uint scalar = parse_text_hex(parser)!;
            if (scalar >= 0xdc00 && scalar <= 0xdfff) {
                return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, start)~;
            }
            if (scalar >= 0xd800 && scalar <= 0xdbff) {
                if (parser.cursor == source.len || source[parser.cursor] != '\\') {
                    return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
                }
                parser.cursor++;
                if (parser.cursor == source.len || source[parser.cursor] != 'u') {
                    return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
                }
                parser.cursor++;
                uint low = parse_text_hex(parser)!;
                if (low < 0xdc00 || low > 0xdfff) {
                    return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor - 4)~;
                }
                scalar = 0x10000 + ((scalar - 0xd800) << 10) + low - 0xdc00;
            }
            return scalar;
        default:
            return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor - 1)~;
    }
}

fn String? parse_text_string(TextParser* parser) @local {
    String source = parser.document.source;
    usz start = parser.cursor++;
    usz decoded = parser.next_string;
    TextStringWriter writer;
    if (parser.storing && parser.document.strings.len) writer.bytes = parser.document.strings.ptr + decoded;
    text_string_limit(parser, start)!;
    while (parser.cursor < source.len) {
        char next = source[parser.cursor];
        if (next == '"') {
            parser.cursor++;
            text_string_limit(parser, start)!;
            parser.next_string += writer.length;
            return parser.storing && writer.length ? (String)parser.document.strings[decoded:writer.length] : (String){};
        }
        if (next < 0x20) return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
        if (next == '\\') {
            usz escape = parser.cursor++;
            write_text_scalar(&writer, parse_text_escape(parser, escape)!);
        } else if (next < 0x80) {
            write_text_byte(&writer, next);
            parser.cursor++;
        } else {
            uint count = text_utf8_width(parser)!;
            foreach (value : source[parser.cursor:count]) write_text_byte(&writer, value);
            parser.cursor += count;
        }
        text_string_limit(parser, start)!;
    }
    return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
}

fn bool text_digit(char value) @local {
    return value >= '0' && value <= '9';
}

fn bool text_delimiter(TextParser* parser) @local {
    String source = parser.document.source;
    if (parser.cursor == source.len) return true;
    char next = source[parser.cursor];
    return next == ' ' || next == '\t' || next == '\r' || next == '\n'
        || next == ',' || next == ']' || next == '}'
        || (next == '/' && parser.cursor + 1 < source.len
            && (source[parser.cursor + 1] == '/' || source[parser.cursor + 1] == '*'));
}

fn void? text_number_limit(TextParser* parser, usz start) @local {
    if (parser.cursor - start > parser.limits.max_number_bytes) {
        return text_parser_error(parser, c3d::CAPACITY_EXCEEDED, start + parser.limits.max_number_bytes)~;
    }
}

fn void? parse_text_digits(TextParser* parser, usz start) @local {
    String source = parser.document.source;
    if (parser.cursor == source.len || !text_digit(source[parser.cursor])) {
        return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
    }
    do {
        parser.cursor++;
        text_number_limit(parser, start)!;
    } while (parser.cursor < source.len && text_digit(source[parser.cursor]));
}

fn void? parse_text_number(TextParser* parser) @local {
    String source = parser.document.source;
    usz start = parser.cursor;
    if (source[parser.cursor] == '-') {
        parser.cursor++;
        text_number_limit(parser, start)!;
    }
    if (parser.cursor == source.len || !text_digit(source[parser.cursor])) {
        return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
    }
    if (source[parser.cursor] == '0') {
        parser.cursor++;
        text_number_limit(parser, start)!;
        if (parser.cursor < source.len && text_digit(source[parser.cursor])) {
            return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
        }
    } else {
        parse_text_digits(parser, start)!;
    }
    if (parser.cursor < source.len && source[parser.cursor] == '.') {
        parser.cursor++;
        text_number_limit(parser, start)!;
        parse_text_digits(parser, start)!;
    }
    if (parser.cursor < source.len && (source[parser.cursor] == 'e' || source[parser.cursor] == 'E')) {
        parser.cursor++;
        text_number_limit(parser, start)!;
        if (parser.cursor < source.len && (source[parser.cursor] == '+' || source[parser.cursor] == '-')) {
            parser.cursor++;
            text_number_limit(parser, start)!;
        }
        parse_text_digits(parser, start)!;
    }
    if (!text_delimiter(parser)) return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
}

fn void? parse_text_literal(TextParser* parser, String literal) @local {
    String source = parser.document.source;
    foreach (value : literal) {
        if (parser.cursor == source.len || source[parser.cursor] != value) {
            return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
        }
        parser.cursor++;
    }
    if (!text_delimiter(parser)) return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
}

fn void? check_text_name(TextParser* parser, uint parent, String name, usz offset) @local {
    usz mask = parser.names.len - 1;
    usz bucket = (name.hash() ^ parent) & mask;
    while (parser.names[bucket]) {
        TextValue* previous = &parser.document.values[parser.names[bucket] - 1];
        if (previous.parent == parent && previous.name == name) {
            return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, offset)~;
        }
        bucket = (bucket + 1) & mask;
    }
    parser.names[bucket] = parser.next_value + 1;
}

fn void? parse_text_container(TextParser* parser, uint parent, bool object) @local {
    String source = parser.document.source;
    if (parser.depth == parser.limits.max_depth) {
        return text_parser_error(parser, c3d::CAPACITY_EXCEEDED, parser.cursor)~;
    }
    parser.depth++;
    defer parser.depth--;
    parser.cursor++;
    skip_text_space(parser)!;
    char close = object ? '}' : ']';
    uint count;
    if (parser.cursor < source.len && source[parser.cursor] == close) {
        parser.cursor++;
        return;
    }
    while (true) {
        if (parser.cursor == source.len || source[parser.cursor] == close) {
            return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
        }
        String name;
        usz name_offset;
        if (object) {
            if (source[parser.cursor] != '"') return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
            name_offset = parser.cursor;
            name = parse_text_string(parser)!;
            parser.named_values++;
            parser.path[parser.path_depth++] = {
                .name = source[name_offset:parser.cursor - name_offset],
                .raw = true,
            };
            if (parser.storing) check_text_name(parser, parent, name, name_offset)!;
            skip_text_space(parser)!;
            if (parser.cursor == source.len || source[parser.cursor] != ':') {
                return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
            }
            parser.cursor++;
        } else {
            parser.path[parser.path_depth++] = { .array = true, .index = count };
        }
        (void)parse_text_value(
            parser: parser,
            parent: parent,
            index: count,
            name: name,
            name_offset: (uint)name_offset,
        )!;
        parser.path_depth--;
        count++;
        skip_text_space(parser)!;
        if (parser.cursor == source.len) return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
        char next = source[parser.cursor++];
        if (next == close) break;
        if (next != ',') return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor - 1)~;
        skip_text_space(parser)!;
    }
    if (parser.storing) parser.document.values[parent].children = count;
}

fn uint? parse_text_value(
    TextParser* parser,
    uint parent,
    uint index,
    String name,
    uint name_offset,
) @local {
    skip_text_space(parser)!;
    String source = parser.document.source;
    if (parser.cursor == source.len) return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
    uint value = parser.next_value++;
    usz start = parser.cursor;
    TextValue token = { .parent = parent, .index = index, .name = name, .name_offset = name_offset, .offset = (uint)start };
    if (parser.storing) parser.document.values[value] = token;
    switch (source[parser.cursor]) {
        case '{':
            token.kind = TextKind.OBJECT;
            parse_text_container(parser, value, true)!;
        case '[':
            token.kind = TextKind.ARRAY;
            parse_text_container(parser, value, false)!;
        case '"':
            token.kind = TextKind.STRING;
            token.string = parse_text_string(parser)!;
        case '-':
        case '0'..'9':
            token.kind = TextKind.NUMBER;
            parse_text_number(parser)!;
        case 't':
            token.kind = TextKind.BOOLEAN;
            token.boolean = true;
            parse_text_literal(parser, "true")!;
        case 'f':
            token.kind = TextKind.BOOLEAN;
            parse_text_literal(parser, "false")!;
        case 'n':
            token.kind = TextKind.NIL;
            parse_text_literal(parser, "null")!;
        default:
            return text_parser_error(parser, c3d::ASSET_FORMAT_ERROR, parser.cursor)~;
    }
    if (parser.storing) {
        token.children = parser.document.values[value].children;
        token.length = (uint)(parser.cursor - start);
        token.end = parser.next_value;
        parser.document.values[value] = token;
    }
    return value;
}
