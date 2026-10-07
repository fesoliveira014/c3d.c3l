module c3d::serial::text_test;

import c3d;
import c3d::serial @public;
import std::core::mem;

struct FailingAllocator (Allocator) @private {
    Allocator backing;
    usz calls;
    usz fail_at;
    usz live;
}

fn void*? FailingAllocator.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    self.calls++;
    if (self.calls == self.fail_at) return mem::OUT_OF_MEMORY~;
    void* result = self.backing.acquire(size, init_type, alignment)!;
    self.live++;
    return result;
}

fn void*? FailingAllocator.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    self.calls++;
    if (self.calls == self.fail_at) return mem::OUT_OF_MEMORY~;
    return self.backing.resize(pointer, size, alignment);
}

fn void FailingAllocator.release(&self, void* pointer, bool aligned) @dynamic {
    self.live--;
    self.backing.release(pointer, aligned);
}

fn void test_text_tree_preserves_numbers_and_decodes_strings() @test {
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    String source = `{"array":[1,true,null,{"x":"ok"}],"name":"\uD834\uDD1E"}`;
    TextDocument document = serial::parse_text(
        allocator: mem,
        source: source,
        limits: serial::TEXT_LIMITS_DEFAULT,
        diagnostic: &diagnostic,
    )!!;
    defer serial::destroy_text_document(&document);
    assert(document.values.len == 8);
    assert(document.values[0].kind == TextKind.OBJECT && document.values[0].children == 2);
    assert(document.values[1].kind == TextKind.ARRAY && document.values[1].children == 4);
    assert(document.values[1].end == 7 && document.values[0].end == 8);
    assert(serial::text_lexeme(&document, 2) == "1");
    assert(document.values[3].boolean && document.values[4].kind == TextKind.NIL);
    assert(document.values[6].name == "x" && document.values[6].string == "ok");
    assert(document.values[7].name == "name" && document.values[7].string.len == 4);
    assert(document.values[7].string[0] == 0xf0 && document.values[7].string[3] == 0x9e);
    assert(!diagnostic.cause && !diagnostic.has_text_position);
}

fn void test_text_invalid_limits_fail_before_allocation() @test {
    TextLimits[8] cases;
    cases[..] = serial::TEXT_LIMITS_DEFAULT;
    cases[0].max_bytes = 0;
    cases[1].max_string_bytes = 0;
    cases[2].max_number_bytes = 0;
    cases[3].max_depth = 0;
    cases[4].max_bytes = (usz)uint::max + 1;
    cases[5].max_string_bytes = (usz)uint::max + 1;
    cases[6].max_number_bytes = (usz)uint::max + 1;
    cases[7].max_depth = serial::TEXT_MAX_DEPTH + 1;
    foreach (limits : cases) {
        FailingAllocator allocator = { .backing = mem, .fail_at = 1 };
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        assert(@catch(serial::parse_text(
            allocator: &allocator,
            source: "[]",
            limits: limits,
            diagnostic: &diagnostic,
        )) == c3d::INVALID_ARGUMENT);
        assert(allocator.calls == 0 && allocator.live == 0);
        assert(diagnostic.cause == c3d::INVALID_ARGUMENT && !diagnostic.has_text_position);
        assert(!diagnostic.pointer.len && !diagnostic.byte_offset && !diagnostic.line && !diagnostic.byte_column);
    }
}

fn void test_text_malformed_value_reports_its_path_and_location() @test {
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    assert(@catch(serial::parse_text(
        allocator: mem,
        source: `{"a/b~":truX}`,
        limits: serial::TEXT_LIMITS_DEFAULT,
        diagnostic: &diagnostic,
    )) == c3d::ASSET_FORMAT_ERROR);
    assert(diagnostic.pointer == "/a~1b~0" && diagnostic.byte_offset == 11);
    assert(diagnostic.line == 1 && diagnostic.byte_column == 12);
}

fn void test_text_writer_enforces_string_and_depth_boundaries() @test {
    TextLimits limits = serial::TEXT_LIMITS_DEFAULT;
    limits.max_string_bytes = 3;
    limits.max_depth = 2;
    JsonOutput output = { .writer = { .measuring = true }, .limits = limits };
    output.quoted("a")!!;
    assert(output.writer.written() == 3);
    assert(@catch(output.quoted("ab")) == c3d::CAPACITY_EXCEEDED);
    output = { .writer = { .measuring = true }, .limits = limits };
    output.begin("", false)!!;
    output.begin("", false)!!;
    assert(@catch(output.begin("", false)) == c3d::CAPACITY_EXCEEDED);
    output.end()!!;
    output.end()!!;
}

fn void test_text_diagnostic_releases_asset_context() @test {
    FailingAllocator allocator = { .backing = mem };
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(&allocator);
    diagnostic.asset_key = "asset".copy(&allocator);
    diagnostic.bone_index = 7;
    diagnostic.has_bone_index = true;
    serial::destroy_serial_diagnostic(&diagnostic);
    assert(allocator.live == 0 && !diagnostic.asset_key.len && !diagnostic.has_bone_index);
}
