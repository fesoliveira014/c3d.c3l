module c3d::serial;

import c3d;

const usz TEXT_INDEX_DIGITS @local = 10;

fn void write_text_byte(TextStringWriter* writer, char value) @private {
    if (writer.bytes) writer.bytes[writer.length] = value;
    writer.length++;
}

fn void write_text_scalar(TextStringWriter* writer, uint scalar) @private {
    if (scalar <= 0x7f) {
        write_text_byte(writer, (char)scalar);
    } else if (scalar <= 0x7ff) {
        write_text_byte(writer, (char)(0xc0 | (scalar >> 6)));
        write_text_byte(writer, (char)(0x80 | (scalar & 0x3f)));
    } else if (scalar <= 0xffff) {
        write_text_byte(writer, (char)(0xe0 | (scalar >> 12)));
        write_text_byte(writer, (char)(0x80 | ((scalar >> 6) & 0x3f)));
        write_text_byte(writer, (char)(0x80 | (scalar & 0x3f)));
    } else {
        write_text_byte(writer, (char)(0xf0 | (scalar >> 18)));
        write_text_byte(writer, (char)(0x80 | ((scalar >> 12) & 0x3f)));
        write_text_byte(writer, (char)(0x80 | ((scalar >> 6) & 0x3f)));
        write_text_byte(writer, (char)(0x80 | (scalar & 0x3f)));
    }
}

fn uint text_hex_digit(char value) @private {
    if (value <= '9') return (uint)(value - '0');
    return (uint)((value | 32) - 'a') + 10;
}

fn void write_pointer_byte(TextStringWriter* writer, char value) @local {
    if (value == '~' || value == '/') {
        write_text_byte(writer, '~');
        write_text_byte(writer, value == '~' ? '0' : '1');
    } else {
        write_text_byte(writer, value);
    }
}

fn void write_pointer_scalar(TextStringWriter* writer, uint scalar) @local {
    char[4] encoded;
    TextStringWriter temporary = { .bytes = &encoded[0] };
    write_text_scalar(&temporary, scalar);
    foreach (value : encoded[:temporary.length]) write_pointer_byte(writer, value);
}

fn uint trusted_text_hex(String text, usz* index) @local {
    uint value;
    for (uint digit = 0; digit < 4; digit++) value = (value << 4) | text_hex_digit(text[(*index)++]);
    return value;
}

fn void write_pointer_name(TextStringWriter* writer, TextPathPart part) @local {
    if (!part.raw) {
        foreach (value : part.name) write_pointer_byte(writer, value);
        return;
    }
    usz index = 1;
    while (index + 1 < part.name.len) {
        char value = part.name[index++];
        if (value != '\\') {
            write_pointer_byte(writer, value);
            continue;
        }
        char escape = part.name[index++];
        switch (escape) {
            case '"': write_pointer_byte(writer, '"');
            case '\\': write_pointer_byte(writer, '\\');
            case '/': write_pointer_byte(writer, '/');
            case 'b': write_pointer_byte(writer, '\b');
            case 'f': write_pointer_byte(writer, '\f');
            case 'n': write_pointer_byte(writer, '\n');
            case 'r': write_pointer_byte(writer, '\r');
            case 't': write_pointer_byte(writer, '\t');
            case 'u':
                uint scalar = trusted_text_hex(part.name, &index);
                if (scalar >= 0xd800 && scalar <= 0xdbff) {
                    index += 2;
                    uint low = trusted_text_hex(part.name, &index);
                    scalar = 0x10000 + ((scalar - 0xd800) << 10) + low - 0xdc00;
                }
                write_pointer_scalar(writer, scalar);
            default: unreachable();
        }
    }
}

fn void write_text_pointer(TextStringWriter* writer, TextPathPart[] path) @local {
    foreach (part : path) {
        write_text_byte(writer, '/');
        if (!part.array) {
            write_pointer_name(writer, part);
            continue;
        }
        char[TEXT_INDEX_DIGITS] digits;
        usz start = digits.len;
        uint index = part.index;
        do {
            digits[--start] = (char)('0' + index % 10);
            index /= 10;
        } while (index);
        foreach (value : digits[start..]) write_text_byte(writer, value);
    }
}

fn fault report_text_error(
    String source,
    TextPathPart[] path,
    usz offset,
    fault cause,
    SerialDiagnostic* diagnostic,
) @private {
    clear_serial_diagnostic(diagnostic);
    diagnostic.cause = cause;
    TextStringWriter measured;
    write_text_pointer(&measured, path);
    if (measured.length > sz::max) {
        diagnostic.cause = c3d::CAPACITY_EXCEEDED;
        return c3d::CAPACITY_EXCEEDED;
    }
    if (measured.length) {
        if (try storage = alloc::new_array_try(diagnostic.allocator, char, (sz)measured.length)) {
            diagnostic.pointer = (String)storage;
        } else {
            diagnostic.cause = c3d::CAPACITY_EXCEEDED;
            return c3d::CAPACITY_EXCEEDED;
        }
    }
    TextStringWriter written = { .bytes = diagnostic.pointer.ptr };
    write_text_pointer(&written, path);
    diagnostic.byte_offset = offset;
    diagnostic.line = 1;
    diagnostic.byte_column = 1;
    for (usz index = 0; index < offset; index++) {
        if (source[index] == '\r') {
            diagnostic.line++;
            diagnostic.byte_column = 1;
            if (index + 1 < offset && source[index + 1] == '\n') index++;
        } else if (source[index] == '\n') {
            diagnostic.line++;
            diagnostic.byte_column = 1;
        } else {
            diagnostic.byte_column++;
        }
    }
    diagnostic.has_text_position = true;
    return cause;
}

fn fault text_parser_error(TextParser* parser, fault cause, usz offset) @private {
    return report_text_error(
        source: parser.document.source,
        path: parser.path[:parser.path_depth],
        offset: offset,
        cause: cause,
        diagnostic: parser.diagnostic,
    );
}
