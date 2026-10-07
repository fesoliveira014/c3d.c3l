module c3d::serial::text_numbers_test;

import c3d;
import c3d::serial @public;
import std::io;

const usz FLOAT_EXPONENTS @private = 256;
const usz DOUBLE_EXPONENTS @private = 2048;

fn void test_text_float_bits_round_trip_through_binary_and_canonical_text() @test {
    uint[*] cases = {
        0x00000000, 0x80000000, 0x00000001, 0x80000001,
        0x007fffff, 0x00800000, 0x7f7fffff, 0xff7fffff,
        0x3f7fffff, 0x3f800000, 0x3f800001, 0x3f800002, 0x3dcccccd,
        0x3eaaaaab, 0x34000000,
        0x7f800000, 0xff800000, 0x7fc00001, 0xffc12345, 0x7f800001, 0xff812345,
    };
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    for (usz sample = 0; sample < cases.len + 2 * FLOAT_EXPONENTS; sample++) {
        uint bits = sample < cases.len ? cases[sample] : ((uint)((sample - cases.len) / 2) << 23) | 0x012345U;
        if (sample >= cases.len && (sample - cases.len) % 2) bits |= 0x80000000U;
        char[serial::TEXT_NUMBER_FORMAT_BYTES] first;
        String text = serial::text_format_f32(bits, first[..])!!;
        if (bits == 0x80000000) assert(text == "-0.0");
        TextDocument document = serial::parse_text(
            allocator: mem,
            source: text,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        float value = serial::text_read_float(&document, 0, &diagnostic)!!;
        assert(bitcast(value, uint) == bits);
        char[uint::size] wire;
        Writer writer = serial::writer_over(wire[..]);
        writer.write_float(value);
        writer.finish()!!;
        Reader reader = serial::reader_over(wire[..]);
        float recovered = reader.read_float()!!;
        assert(bitcast(recovered, uint) == bits && reader.remaining() == 0);
        char[serial::TEXT_NUMBER_FORMAT_BYTES] second;
        String rewritten = serial::text_format_f32(bitcast(recovered, uint), second[..])!!;
        assert(rewritten == text);
    }
}

fn void test_text_double_bits_round_trip_through_binary_and_canonical_text() @test {
    ulong[*] cases = {
        0x0000000000000000UL, 0x8000000000000000UL, 0x0000000000000001UL, 0x8000000000000001UL,
        0x000fffffffffffffUL, 0x0010000000000000UL, 0x7fefffffffffffffUL, 0xffefffffffffffffUL,
        0x3fefffffffffffffUL, 0x3ff0000000000000UL, 0x3ff0000000000001UL, 0x3ff0000000000002UL, 0x3fb999999999999aUL,
        0x3fd5555555555555UL, 0x3e80000000000000UL,
        0x7ff0000000000000UL, 0xfff0000000000000UL, 0x7ff8000000000001UL,
        0xfff8123456789abcUL, 0x7ff0000000000001UL, 0xfff0123456789abcUL,
    };
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    for (usz sample = 0; sample < cases.len + 2 * DOUBLE_EXPONENTS; sample++) {
        ulong bits = sample < cases.len ? cases[sample] : ((ulong)((sample - cases.len) / 2) << 52) | 0x0123456789abcUL;
        if (sample >= cases.len && (sample - cases.len) % 2) bits |= 0x8000000000000000UL;
        char[serial::TEXT_NUMBER_FORMAT_BYTES] first;
        String text = serial::text_format_f64(bits, first[..])!!;
        if (bits == 0x8000000000000000UL) assert(text == "-0.0");
        TextDocument document = serial::parse_text(
            allocator: mem,
            source: text,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        double value = serial::text_read_double(&document, 0, &diagnostic)!!;
        assert(bitcast(value, ulong) == bits);
        char[ulong::size] wire;
        Writer writer = serial::writer_over(wire[..]);
        writer.write_ulong(bitcast(value, ulong));
        writer.finish()!!;
        Reader reader = serial::reader_over(wire[..]);
        ulong recovered = reader.read_ulong()!!;
        assert(recovered == bits && reader.remaining() == 0);
        char[serial::TEXT_NUMBER_FORMAT_BYTES] second;
        String rewritten = serial::text_format_f64(recovered, second[..])!!;
        assert(rewritten == text);
    }
}

fn void test_text_float_conversion_uses_the_original_decimal_lexeme() @test {
    String[4] cases = {
        "1.00000005960464477539062582718061255302767487140869206996285356581211090087890625",
        "1.00000017881393432617187417281938744697232512859130793003714643418788909912109375",
        "1.000000059604644775390625",
        "1.000000178813934326171875",
    };
    uint[4] expected = { 0x3f800001, 0x3f800001, 0x3f800000, 0x3f800002 };
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    foreach (index, source : cases) {
        TextDocument document = serial::parse_text(
            allocator: mem,
            source: source,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        assert(serial::text_lexeme(&document, 0) == source);
        float value = serial::text_read_float(&document, 0, &diagnostic)!!;
        assert(bitcast(value, uint) == expected[index]);
        double wider = source.to_double()!!;
        float narrowed = (float)wider;
        if (index < 2) assert(bitcast(narrowed, uint) != bitcast(value, uint));
    }
    String[3] wide = {
        "1.000000000000000111022302462515654043115483193608295255099991383822237233803945956334136013765601092018187046051025390625",
        "1.00000000000000011102230246251565404236316680908203125",
        "1.00000000000000033306690738754696212708950042724609375",
    };
    ulong[3] wide_expected = { 0x3ff0000000000001UL, 0x3ff0000000000000UL, 0x3ff0000000000002UL };
    foreach (index, source : wide) {
        TextDocument document = serial::parse_text(
            allocator: mem,
            source: source,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        double value = serial::text_read_double(&document, 0, &diagnostic)!!;
        assert(bitcast(value, ulong) == wide_expected[index]);
    }
}

fn void test_text_nonfinite_tokens_require_matching_width_and_nonfinite_bits() @test {
    String[*] bad_float = {
        `"f32:7fc0000"`, `"f32:7FC00001"`, `"f64:7fc00001"`, `"f32:3f800000"`,
        `"nan"`, `"f32:7fc0000g"`, "true", "null", "3.4028236e38",
    };
    String[*] bad_double = {
        `"f64:7ff800000000001"`, `"f64:7FF8000000000001"`,
        `"f32:7ff8000000000001"`, `"f64:3ff0000000000000"`, "1e999",
    };
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    foreach (token : bad_float) {
        char[180] buffer;
        String source = (String)io::bprintf(buffer[..], `{"value":%s}`, token)!!;
        TextDocument document = serial::parse_text(
            allocator: mem,
            source: source,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        assert(@catch(serial::text_read_float(&document, 1, &diagnostic)) == c3d::ASSET_FORMAT_ERROR);
        assert(diagnostic.cause == c3d::ASSET_FORMAT_ERROR && diagnostic.pointer == "/value");
        assert(diagnostic.byte_offset == 9 && diagnostic.line == 1 && diagnostic.byte_column == 10);
    }
    foreach (token : bad_double) {
        char[180] buffer;
        String source = (String)io::bprintf(buffer[..], `{"value":%s}`, token)!!;
        TextDocument document = serial::parse_text(
            allocator: mem,
            source: source,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        assert(@catch(serial::text_read_double(&document, 1, &diagnostic)) == c3d::ASSET_FORMAT_ERROR);
        assert(diagnostic.pointer == "/value");
    }
}

fn void test_text_vector_components_use_the_same_float_rules() @test {
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    String source = `["f32:7f800001",-0.0,0.1,"f32:ff800000"]`;
    uint[4] expected = { 0x7f800001, 0x80000000, 0x3dcccccd, 0xff800000 };
    TextDocument document = serial::parse_text(
        allocator: mem,
        source: source,
        limits: serial::TEXT_LIMITS_DEFAULT,
        diagnostic: &diagnostic,
    )!!;
    defer serial::destroy_text_document(&document);
    assert(document.values[0].children == expected.len);
    foreach (uint index, bits : expected) {
        float value = serial::text_read_float(&document, index + 1, &diagnostic)!!;
        assert(bitcast(value, uint) == bits);
    }
}

fn void test_text_wide_integers_require_quoted_decimal_and_keep_full_range() @test {
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    foreach (value : (long[]){ long::min, -1, 0, long::max }) {
        char[serial::TEXT_NUMBER_FORMAT_BYTES] buffer;
        String text = serial::text_format_long(buffer[..], value)!!;
        assert(text[0] == '"' && text[text.len - 1] == '"');
        TextDocument document = serial::parse_text(
            allocator: mem,
            source: text,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        assert(serial::text_read_long(&document, 0, &diagnostic)!! == value);
    }
    foreach (value : (ulong[]){ 0, (ulong)long::max + 1, ulong::max }) {
        char[serial::TEXT_NUMBER_FORMAT_BYTES] buffer;
        String text = serial::text_format_ulong(buffer[..], value)!!;
        TextDocument document = serial::parse_text(
            allocator: mem,
            source: text,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        assert(serial::text_read_ulong(&document, 0, &diagnostic)!! == value);
    }
    String[*] rejected = { "0", `"1e2"`, `"1.0"`, `"+1"`, `" 1"`, `"9223372036854775808"`, `"007"`, `"00"`, `"-0"`, `"-00"` };
    foreach (source : rejected) {
        TextDocument document = serial::parse_text(
            allocator: mem,
            source: source,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        assert(@catch(serial::text_read_long(&document, 0, &diagnostic)) == c3d::ASSET_FORMAT_ERROR);
        assert(diagnostic.has_text_position && diagnostic.pointer.len == 0 && diagnostic.byte_offset == 0);
    }
    foreach (source : (String[]){ "0", `"-1"`, `"18446744073709551616"`, `"007"`, `"00"`, `"-0"`, `"-00"` }) {
        TextDocument document = serial::parse_text(
            allocator: mem,
            source: source,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        assert(@catch(serial::text_read_ulong(&document, 0, &diagnostic)) == c3d::ASSET_FORMAT_ERROR);
    }
}

fn void test_text_narrow_integers_reject_fractions_exponents_and_overflow() @test {
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    String[*] rejected = { `"1"`, "1.0", "1e0", "2147483648", "-2147483649" };
    foreach (token : rejected) {
        char[80] buffer;
        String source = (String)io::bprintf(buffer[..], `{"number":%s}`, token)!!;
        TextDocument document = serial::parse_text(
            allocator: mem,
            source: source,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        assert(@catch(serial::text_read_signed(
            document: &document,
            value: 1,
            minimum: int::min,
            maximum: int::max,
            diagnostic: &diagnostic,
        )) == c3d::ASSET_FORMAT_ERROR);
        assert(diagnostic.pointer == "/number" && diagnostic.byte_offset == 10);
    }
    foreach (source : (String[]){ "-1", "4294967296", "1.2", "2e0" }) {
        TextDocument document = serial::parse_text(
            allocator: mem,
            source: source,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        assert(@catch(serial::text_read_unsigned(
            document: &document,
            value: 0,
            maximum: uint::max,
            diagnostic: &diagnostic,
        )) == c3d::ASSET_FORMAT_ERROR);
    }
    TextDocument maximum = serial::parse_text(
        allocator: mem,
        source: "4294967295",
        limits: serial::TEXT_LIMITS_DEFAULT,
        diagnostic: &diagnostic,
    )!!;
    defer serial::destroy_text_document(&maximum);
    assert(serial::text_read_unsigned(
        document: &maximum,
        value: 0,
        maximum: uint::max,
        diagnostic: &diagnostic,
    )!! == uint::max);
    TextDocument small = serial::parse_text(
        allocator: mem,
        source: "256",
        limits: serial::TEXT_LIMITS_DEFAULT,
        diagnostic: &diagnostic,
    )!!;
    defer serial::destroy_text_document(&small);
    assert(@catch(serial::text_read_unsigned(
        document: &small,
        value: 0,
        maximum: char::max,
        diagnostic: &diagnostic,
    )) == c3d::ASSET_FORMAT_ERROR);
}

fn void test_text_numeric_formatters_report_short_output_capacity() @test {
    char[1] output;
    assert(@catch(serial::text_format_f32(0x7f800000, output[..])) == c3d::CAPACITY_EXCEEDED);
    assert(@catch(serial::text_format_f64(0x7ff0000000000000UL, output[..])) == c3d::CAPACITY_EXCEEDED);
    assert(@catch(serial::text_format_long(output[..], long::min)) == c3d::CAPACITY_EXCEEDED);
    assert(@catch(serial::text_format_ulong(output[..], ulong::max)) == c3d::CAPACITY_EXCEEDED);
}
