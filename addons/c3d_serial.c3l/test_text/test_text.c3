module c3d::serial::text_test;

import c3d;
import c3d::serial @public;
import std::core::mem;
import std::core::mem::alloc;


struct ExpectedError @private {
    fault cause;
    String pointer;
    usz offset;
    usz line;
    usz column;
}

fn void assert_text_error(
    String source,
    ExpectedError expected,
    TextLimits limits = serial::TEXT_LIMITS_DEFAULT,
) @private {
    FailingAllocator allocator = { .backing = mem };
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    TextDocument? outcome = serial::parse_text(
        allocator: &allocator,
        source: source,
        limits: limits,
        diagnostic: &diagnostic,
    );
    if (catch excuse = outcome) {
        assert(excuse == expected.cause);
        assert(diagnostic.cause == expected.cause);
        assert(diagnostic.pointer == expected.pointer);
        assert(diagnostic.has_text_position);
        assert(diagnostic.byte_offset == expected.offset);
        assert(diagnostic.line == expected.line && diagnostic.byte_column == expected.column);
    } else {
        TextDocument document = outcome;
        serial::destroy_text_document(&document);
        unreachable("Expected a parser fault.");
    }
    assert(allocator.live == 0);
}

fn void assert_text_valid(String source, TextLimits limits = serial::TEXT_LIMITS_DEFAULT) @private {
    FailingAllocator allocator = { .backing = mem };
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    TextDocument document = serial::parse_text(
        allocator: &allocator,
        source: source,
        limits: limits,
        diagnostic: &diagnostic,
    )!!;
    serial::destroy_text_document(&document);
    assert(allocator.live == 0 && !diagnostic.cause);
}
fn void test_text_comments_and_empty_names_are_valid() @test {
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    String source = `/*before*/{"":0,// line
"b"/*key*/:/*value*/[/*empty*/]}//tail`;
    TextDocument document = serial::parse_text(
        allocator: mem,
        source: source,
        limits: serial::TEXT_LIMITS_DEFAULT,
        diagnostic: &diagnostic,
    )!!;
    defer serial::destroy_text_document(&document);
    assert(document.values.len == 3 && document.values[0].children == 2);
    assert(document.values[1].name.len == 0 && serial::text_lexeme(&document, 1) == "0");
    assert(document.values[2].kind == TextKind.ARRAY && document.values[2].children == 0);
}

fn void test_text_syntax_errors_have_pointer_offset_and_byte_position() @test {
    assert_text_error("", { .cause = c3d::ASSET_FORMAT_ERROR, .offset = 0, .line = 1, .column = 1 });
    assert_text_error("[1,]", { .cause = c3d::ASSET_FORMAT_ERROR, .offset = 3, .line = 1, .column = 4 });
    assert_text_error(`{"a":1,}`, { .cause = c3d::ASSET_FORMAT_ERROR, .offset = 7, .line = 1, .column = 8 });
    assert_text_error(`{"a" 1}`, { .cause = c3d::ASSET_FORMAT_ERROR, .pointer = "/a", .offset = 5, .line = 1, .column = 6 });
    assert_text_error(`{"a":}`, { .cause = c3d::ASSET_FORMAT_ERROR, .pointer = "/a", .offset = 5, .line = 1, .column = 6 });
    assert_text_error(`{"a":"\q"}`, { .cause = c3d::ASSET_FORMAT_ERROR, .pointer = "/a", .offset = 7, .line = 1, .column = 8 });
    assert_text_error("{} true", { .cause = c3d::ASSET_FORMAT_ERROR, .offset = 3, .line = 1, .column = 4 });
    assert_text_error("/*open", { .cause = c3d::ASSET_FORMAT_ERROR, .offset = 6, .line = 1, .column = 7 });
    String source = "{\r\n  \"a/b~c\": [0,\r\n    truX]\r\n}";
    assert_text_error(source, {
        .cause = c3d::ASSET_FORMAT_ERROR,
        .pointer = "/a~1b~0c/1",
        .offset = (usz)source.index_of_char('X')!!,
        .line = 3,
        .column = 8,
    });
}

fn void test_text_rejects_duplicate_decoded_keys_and_bad_escapes() @test {
    assert_text_error(`{"a":0,"\u0061":1}`, {
        .cause = c3d::ASSET_FORMAT_ERROR, .pointer = "/a", .offset = 7, .line = 1, .column = 8,
    });
    String duplicate = `{"𝄞":0,"\uD834\uDD1E":1}`;
    usz duplicate_offset = (usz)duplicate.index_of("\\uD834")!! - 1;
    assert_text_error(duplicate, {
        .cause = c3d::ASSET_FORMAT_ERROR,
        .pointer = "/𝄞",
        .offset = duplicate_offset,
        .line = 1,
        .column = duplicate_offset + 1,
    });
    assert_text_error(`"\udc00"`, { .cause = c3d::ASSET_FORMAT_ERROR, .offset = 1, .line = 1, .column = 2 });
    assert_text_error(`"\ud800"`, { .cause = c3d::ASSET_FORMAT_ERROR, .offset = 7, .line = 1, .column = 8 });
    assert_text_error(`"\uZZZZ"`, { .cause = c3d::ASSET_FORMAT_ERROR, .offset = 3, .line = 1, .column = 4 });
    assert_text_error(`"\ud800\u0041"`, { .cause = c3d::ASSET_FORMAT_ERROR, .offset = 9, .line = 1, .column = 10 });
    assert_text_valid(`{"a":{"x":1},"b":{"x":2}}`);
    assert_text_valid(`/* non-nesting /* text */ {}`);
}

fn void test_text_rejects_invalid_utf8_and_accepts_unicode_boundaries() @test {
    char[*] overlong = { '"', 0xc0, 0x80, '"' };
    char[*] surrogate = { '"', 0xed, 0xa0, 0x80, '"' };
    char[*] above_maximum = { '"', 0xf4, 0x90, 0x80, 0x80, '"' };
    char[*] broken_continuation = { '"', 0xe2, 'x', '"' };
    char[*] valid_maximum = { '"', 0xf4, 0x8f, 0xbf, 0xbf, '"' };
    char[*] invalid_comment = { '/', '*', 0xc0, 0x80, '*', '/', '0' };
    ExpectedError first = { .cause = c3d::ASSET_FORMAT_ERROR, .offset = 1, .line = 1, .column = 2 };
    assert_text_error((String)overlong[..], first);
    assert_text_error((String)surrogate[..], first);
    assert_text_error((String)above_maximum[..], first);
    assert_text_error((String)broken_continuation[..], {
        .cause = c3d::ASSET_FORMAT_ERROR, .offset = 2, .line = 1, .column = 3,
    });
    assert_text_error((String)invalid_comment[..], {
        .cause = c3d::ASSET_FORMAT_ERROR, .offset = 2, .line = 1, .column = 3,
    });
    assert_text_valid((String)valid_maximum[..]);
    assert_text_valid(`"\u0000\u007f\u0080\u07ff\u0800\ud7ff\ue000\uffff\udbff\udfff"`);
}

fn void test_text_limits_accept_boundary_and_reject_one_past() @test {
    TextLimits limits = serial::TEXT_LIMITS_DEFAULT;
    limits.max_bytes = 2;
    assert_text_valid("[]", limits);
    limits.max_bytes = 1;
    assert_text_error("[]", { .cause = c3d::CAPACITY_EXCEEDED, .offset = 1, .line = 1, .column = 2 }, limits);
    limits = serial::TEXT_LIMITS_DEFAULT;
    limits.max_string_bytes = 3;
    assert_text_valid(`"a"`, limits);
    assert_text_error(`"ab"`, { .cause = c3d::CAPACITY_EXCEEDED, .offset = 3, .line = 1, .column = 4 }, limits);
    limits.max_string_bytes = 8;
    assert_text_valid(`"\u0061"`, limits);
    limits.max_string_bytes = 7;
    assert_text_error(`"\u0061"`, { .cause = c3d::CAPACITY_EXCEEDED, .offset = 7, .line = 1, .column = 8 }, limits);
    limits = serial::TEXT_LIMITS_DEFAULT;
    limits.max_number_bytes = 3;
    assert_text_valid("123", limits);
    assert_text_error("1234", { .cause = c3d::CAPACITY_EXCEEDED, .offset = 3, .line = 1, .column = 4 }, limits);
    limits = serial::TEXT_LIMITS_DEFAULT;
    limits.max_depth = 2;
    assert_text_valid("[[]]", limits);
    assert_text_error("[[[]]]", {
        .cause = c3d::CAPACITY_EXCEEDED, .pointer = "/0/0", .offset = 2, .line = 1, .column = 3,
    }, limits);
    char[128] maximum_depth;
    maximum_depth[:64] = '[';
    maximum_depth[64..] = ']';
    assert_text_valid((String)maximum_depth[..]);
    char[130] excess_depth;
    excess_depth[:65] = '[';
    excess_depth[65..] = ']';
    char[128] depth_pointer;
    for (usz index = 0; index < 64; index++) {
        depth_pointer[index * 2] = '/';
        depth_pointer[index * 2 + 1] = '0';
    }
    assert_text_error((String)excess_depth[..], {
        .cause = c3d::CAPACITY_EXCEEDED,
        .pointer = (String)depth_pointer[..],
        .offset = 64,
        .line = 1,
        .column = 65,
    });
}

fn void test_text_every_strict_prefix_fails_without_reader_leaks() @test {
    String source = `{"a/b~c":[{"s":"€","v":-1.25e+2},true,null],"escaped":"\uD834\uDD1E"}`;
    FailingAllocator allocator = { .backing = mem };
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    for (usz count = 0; count < source.len; count++) {
        assert(@catch(serial::parse_text(
            allocator: &allocator,
            source: source[:count],
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )) == c3d::ASSET_FORMAT_ERROR);
        assert(allocator.live == 0);
        assert(diagnostic.cause == c3d::ASSET_FORMAT_ERROR && diagnostic.has_text_position);
        assert(diagnostic.byte_offset <= count);
    }
    TextDocument document = serial::parse_text(
        allocator: &allocator,
        source: source,
        limits: serial::TEXT_LIMITS_DEFAULT,
        diagnostic: &diagnostic,
    )!!;
    serial::destroy_text_document(&document);
    assert(allocator.live == 0 && !diagnostic.cause);
}

fn void test_text_reader_allocation_failures_release_every_acquisition() @test {
    String source = `{"s":"owned","a":[1,2,3]}`;
    FailingAllocator baseline = { .backing = mem };
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    TextDocument document = serial::parse_text(
        allocator: &baseline,
        source: source,
        limits: serial::TEXT_LIMITS_DEFAULT,
        diagnostic: &diagnostic,
    )!!;
    usz allocations = baseline.calls;
    assert(allocations >= 3);
    serial::destroy_text_document(&document);
    assert(baseline.live == 0);
    for (usz failure = 1; failure <= allocations; failure++) {
        FailingAllocator allocator = { .backing = mem, .fail_at = failure };
        assert(@catch(serial::parse_text(
            allocator: &allocator,
            source: source,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )) == c3d::CAPACITY_EXCEEDED);
        assert(allocator.live == 0 && diagnostic.cause == c3d::CAPACITY_EXCEEDED);
    }
}

fn void test_text_diagnostic_ownership_reuse_and_allocation_failure() @test {
    FailingAllocator diagnostic_allocator = { .backing = mem };
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(&diagnostic_allocator);
    String source = `{"owned":truX}`;
    assert(@catch(serial::parse_text(
        allocator: mem,
        source: source,
        limits: serial::TEXT_LIMITS_DEFAULT,
        diagnostic: &diagnostic,
    )) == c3d::ASSET_FORMAT_ERROR);
    assert(diagnostic.pointer == "/owned" && diagnostic_allocator.live == 1);
    TextDocument document = serial::parse_text(
        allocator: mem,
        source: "{}",
        limits: serial::TEXT_LIMITS_DEFAULT,
        diagnostic: &diagnostic,
    )!!;
    serial::destroy_text_document(&document);
    assert(diagnostic_allocator.live == 0 && !diagnostic.cause && !diagnostic.has_text_position);
    diagnostic_allocator.fail_at = diagnostic_allocator.calls + 1;
    assert(@catch(serial::parse_text(
        allocator: mem,
        source: source,
        limits: serial::TEXT_LIMITS_DEFAULT,
        diagnostic: &diagnostic,
    )) == c3d::CAPACITY_EXCEEDED);
    assert(diagnostic.cause == c3d::CAPACITY_EXCEEDED && !diagnostic.has_text_position);
    assert(diagnostic.pointer.len == 0 && diagnostic_allocator.live == 0);
    serial::destroy_serial_diagnostic(&diagnostic);
}

fn void test_text_diagnostics_do_not_truncate_long_pointers() @test {
    const usz KEY_BYTES = 2048;
    char[KEY_BYTES + 9] source;
    source[0] = '{';
    source[1] = '"';
    source[2:KEY_BYTES] = '/';
    String suffix = `":truX}`;
    mem::copy(&source[2 + KEY_BYTES], suffix.ptr, suffix.len);
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    assert(@catch(serial::parse_text(
        allocator: mem,
        source: (String)source[..],
        limits: serial::TEXT_LIMITS_DEFAULT,
        diagnostic: &diagnostic,
    )) == c3d::ASSET_FORMAT_ERROR);
    assert(diagnostic.pointer.len == 1 + KEY_BYTES * 2);
    assert(diagnostic.pointer[0] == '/');
    for (usz index = 0; index < KEY_BYTES; index++) {
        assert(diagnostic.pointer[1 + index * 2] == '~' && diagnostic.pointer[2 + index * 2] == '1');
    }
}

fn void test_text_complete_validation_precedes_consumer_skipping() @test {
    assert_text_valid(`{"selected":1,"unknown":{"values":[true,false,null]}}`);
    String malformed = `{"selected":1,"unknown":{"values":[true,]}}`;
    usz offset = (usz)malformed.index_of_char(']')!!;
    assert_text_error(malformed, {
        .cause = c3d::ASSET_FORMAT_ERROR,
        .pointer = "/unknown/values",
        .offset = offset,
        .line = 1,
        .column = offset + 1,
    });
}

fn void test_text_semantic_diagnostics_survive_document_destruction() @test {
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    TextDocument document = serial::parse_text(
        allocator: mem,
        source: `{"version":2}`,
        limits: serial::TEXT_LIMITS_DEFAULT,
        diagnostic: &diagnostic,
    )!!;
    assert(serial::text_error(
        document: &document,
        value: 1,
        cause: c3d::UNSUPPORTED,
        diagnostic: &diagnostic,
    ) == c3d::UNSUPPORTED);
    serial::destroy_text_document(&document);
    assert(diagnostic.cause == c3d::UNSUPPORTED && diagnostic.pointer == "/version");
    assert(diagnostic.has_text_position && diagnostic.byte_offset == 11 && diagnostic.line == 1 && diagnostic.byte_column == 12);
}
fn void test_text_number_grammar_rejects_non_json_spellings() @test {
    String[*] sources = { "01", "-", "-.1", "1.", "1e", "1e+", "1a", "+1", ".1", "NaN", "Infinity", "0x1" };
    usz[sources.len] offsets = { 1, 1, 1, 2, 2, 3, 1, 0, 0, 0, 0, 1 };
    foreach (index, source : sources) {
        assert_text_error(source, {
            .cause = c3d::ASSET_FORMAT_ERROR,
            .offset = offsets[index],
            .line = 1,
            .column = offsets[index] + 1,
        });
    }
    assert_text_valid("[-0,0,12,-12,0.25,-0.25,1e2,1E-2,1e+2]");
}
