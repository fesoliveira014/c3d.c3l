module c3d::serial;

import c3d;
import std::io;

const uint TEXT_FLOAT_EXPONENT @local = 0x7f800000;
const uint TEXT_FLOAT_SIGN @local = 0x80000000;
const ulong TEXT_DOUBLE_EXPONENT @local = 0x7ff0000000000000UL;
const ulong TEXT_DOUBLE_SIGN @local = 0x8000000000000000UL;

fn bool text_lower_hex(String value) @local {
    foreach (digit : value) {
        if (!(digit >= '0' && digit <= '9') && !(digit >= 'a' && digit <= 'f')) return false;
    }
    return true;
}

fn bool text_integer_spelling(String value, bool signed) @local {
    if (!value.len) return false;
    usz start;
    if (value[0] == '-') {
        if (!signed || value.len == 1) return false;
        start = 1;
    }
    foreach (digit : value[start..]) {
        if (digit < '0' || digit > '9') return false;
    }
    return true;
}

fn float? text_read_float(TextDocument* document, uint value, SerialDiagnostic* diagnostic) @private {
    TextValue* token = &document.values[value];
    if (token.kind == TextKind.STRING) {
        String text = token.string;
        if (text.len != 12 || text[:4] != "f32:" || !text_lower_hex(text[4..])) {
            return text_error(
                document: document,
                value: value,
                cause: c3d::ASSET_FORMAT_ERROR,
                diagnostic: diagnostic,
            )~;
        }
        uint bits;
        foreach (digit : text[4..]) bits = (bits << 4) | text_hex_digit(digit);
        if ((bits & TEXT_FLOAT_EXPONENT) != TEXT_FLOAT_EXPONENT) {
            return text_error(
                document: document,
                value: value,
                cause: c3d::ASSET_FORMAT_ERROR,
                diagnostic: diagnostic,
            )~;
        }
        return bitcast(bits, float);
    }
    if (token.kind != TextKind.NUMBER) return text_error(
        document: document,
        value: value,
        cause: c3d::ASSET_FORMAT_ERROR,
        diagnostic: diagnostic,
    )~;
    float? number = text_lexeme(document, value).to_float();
    if (catch excuse = number) return text_error(
        document: document,
        value: value,
        cause: c3d::ASSET_FORMAT_ERROR,
        diagnostic: diagnostic,
    )~;
    if ((bitcast(number, uint) & TEXT_FLOAT_EXPONENT) == TEXT_FLOAT_EXPONENT) {
        return text_error(
            document: document,
            value: value,
            cause: c3d::ASSET_FORMAT_ERROR,
            diagnostic: diagnostic,
        )~;
    }
    return number;
}

fn double? text_read_double(TextDocument* document, uint value, SerialDiagnostic* diagnostic) @private {
    TextValue* token = &document.values[value];
    if (token.kind == TextKind.STRING) {
        String text = token.string;
        if (text.len != 20 || text[:4] != "f64:" || !text_lower_hex(text[4..])) {
            return text_error(
                document: document,
                value: value,
                cause: c3d::ASSET_FORMAT_ERROR,
                diagnostic: diagnostic,
            )~;
        }
        ulong bits;
        foreach (digit : text[4..]) bits = (bits << 4) | (ulong)text_hex_digit(digit);
        if ((bits & TEXT_DOUBLE_EXPONENT) != TEXT_DOUBLE_EXPONENT) {
            return text_error(
                document: document,
                value: value,
                cause: c3d::ASSET_FORMAT_ERROR,
                diagnostic: diagnostic,
            )~;
        }
        return bitcast(bits, double);
    }
    if (token.kind != TextKind.NUMBER) return text_error(
        document: document,
        value: value,
        cause: c3d::ASSET_FORMAT_ERROR,
        diagnostic: diagnostic,
    )~;
    double? number = text_lexeme(document, value).to_double();
    if (catch excuse = number) return text_error(
        document: document,
        value: value,
        cause: c3d::ASSET_FORMAT_ERROR,
        diagnostic: diagnostic,
    )~;
    if ((bitcast(number, ulong) & TEXT_DOUBLE_EXPONENT) == TEXT_DOUBLE_EXPONENT) {
        return text_error(
            document: document,
            value: value,
            cause: c3d::ASSET_FORMAT_ERROR,
            diagnostic: diagnostic,
        )~;
    }
    return number;
}

fn long? text_read_signed(
    TextDocument* document,
    uint value,
    long minimum,
    long maximum,
    SerialDiagnostic* diagnostic,
) @private {
    TextValue* token = &document.values[value];
    String text = text_lexeme(document, value);
    if (token.kind != TextKind.NUMBER || !text_integer_spelling(text, true)) {
        return text_error(
            document: document,
            value: value,
            cause: c3d::ASSET_FORMAT_ERROR,
            diagnostic: diagnostic,
        )~;
    }
    long? number = text.to_long(10);
    if (catch excuse = number) return text_error(
        document: document,
        value: value,
        cause: c3d::ASSET_FORMAT_ERROR,
        diagnostic: diagnostic,
    )~;
    if (number < minimum || number > maximum) return text_error(
        document: document,
        value: value,
        cause: c3d::ASSET_FORMAT_ERROR,
        diagnostic: diagnostic,
    )~;
    return number;
}

fn ulong? text_read_unsigned(
    TextDocument* document,
    uint value,
    ulong maximum,
    SerialDiagnostic* diagnostic,
) @private {
    TextValue* token = &document.values[value];
    String text = text_lexeme(document, value);
    if (token.kind != TextKind.NUMBER || !text_integer_spelling(text, false)) {
        return text_error(
            document: document,
            value: value,
            cause: c3d::ASSET_FORMAT_ERROR,
            diagnostic: diagnostic,
        )~;
    }
    ulong? number = text.to_ulong(10);
    if (catch excuse = number) return text_error(
        document: document,
        value: value,
        cause: c3d::ASSET_FORMAT_ERROR,
        diagnostic: diagnostic,
    )~;
    if (number > maximum) return text_error(
        document: document,
        value: value,
        cause: c3d::ASSET_FORMAT_ERROR,
        diagnostic: diagnostic,
    )~;
    return number;
}

fn long? text_read_long(TextDocument* document, uint value, SerialDiagnostic* diagnostic) @private {
    TextValue* token = &document.values[value];
    if (token.kind != TextKind.STRING || !text_integer_spelling(token.string, true)) {
        return text_error(
            document: document,
            value: value,
            cause: c3d::ASSET_FORMAT_ERROR,
            diagnostic: diagnostic,
        )~;
    }
    long? number = token.string.to_long(10);
    if (catch excuse = number) return text_error(
        document: document,
        value: value,
        cause: c3d::ASSET_FORMAT_ERROR,
        diagnostic: diagnostic,
    )~;
    return number;
}

fn ulong? text_read_ulong(TextDocument* document, uint value, SerialDiagnostic* diagnostic) @private {
    TextValue* token = &document.values[value];
    if (token.kind != TextKind.STRING || !text_integer_spelling(token.string, false)) {
        return text_error(
            document: document,
            value: value,
            cause: c3d::ASSET_FORMAT_ERROR,
            diagnostic: diagnostic,
        )~;
    }
    ulong? number = token.string.to_ulong(10);
    if (catch excuse = number) return text_error(
        document: document,
        value: value,
        cause: c3d::ASSET_FORMAT_ERROR,
        diagnostic: diagnostic,
    )~;
    return number;
}

fn String? text_format_f32(uint bits, char[] output) @private {
    if ((bits & TEXT_FLOAT_EXPONENT) == TEXT_FLOAT_EXPONENT) {
        return (String)(io::bprintf(output, `"f32:%08x"`, bits) ?? c3d::CAPACITY_EXCEEDED~!);
    }
    if (bits == TEXT_FLOAT_SIGN) {
        return (String)(io::bprintf(output, "-0.0") ?? c3d::CAPACITY_EXCEEDED~!);
    }
    return (String)(io::bprintf(output, "%.9g", bitcast(bits, float)) ?? c3d::CAPACITY_EXCEEDED~!);
}

fn String? text_format_f64(ulong bits, char[] output) @private {
    if ((bits & TEXT_DOUBLE_EXPONENT) == TEXT_DOUBLE_EXPONENT) {
        return (String)(io::bprintf(output, `"f64:%016x"`, bits) ?? c3d::CAPACITY_EXCEEDED~!);
    }
    if (bits == TEXT_DOUBLE_SIGN) {
        return (String)(io::bprintf(output, "-0.0") ?? c3d::CAPACITY_EXCEEDED~!);
    }
    return (String)(io::bprintf(output, "%.17g", bitcast(bits, double)) ?? c3d::CAPACITY_EXCEEDED~!);
}

fn String? text_format_long(char[] output, long value) @private {
    return (String)(io::bprintf(output, `"%s"`, value) ?? c3d::CAPACITY_EXCEEDED~!);
}

fn String? text_format_ulong(char[] output, ulong value) @private {
    return (String)(io::bprintf(output, `"%s"`, value) ?? c3d::CAPACITY_EXCEEDED~!);
}
