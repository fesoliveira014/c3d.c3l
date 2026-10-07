module c3d::serial::test_described;

import c3d;
import c3d::describe;
import c3d::serial @public;

struct SchemaDetails @private {
    uint count @tag("display", "Count") @tag("range", { 1.0, 9.0 }) @tag("unit", "items");
    JsonMode mode;
    MaterialId material;
    JsonItem[2] children;
}
struct Opaque @private {
    uint value;
}

fn void defaults_schema_details(void* raw) @private {
    *(SchemaDetails*)raw = { .count = 5, .mode = SECOND, .children = {
        { .label = "left", .amount = 1 }, { .label = "right", .amount = 2 },
    } };
}
fn void? write_opaque(void* raw, Writer* writer, WriteContext* context) @private {
    writer.write_uint(((Opaque*)raw).value);
}

fn void? read_opaque(Reader* reader, ReadContext* context) @private {
    context.scene.add(context.node, (Opaque){ .value = reader.read_uint()! });
}

fn void register_opaque() @private {
    serial::register_codec(Opaque, { .name = "opaque", .version = 1, .write = &write_opaque, .read = &read_opaque })!!;
}

fn uint member(TextDocument* document, uint parent, String name) @private {
    for (uint index = parent + 1; index < document.values[parent].end; index = document.values[index].end) {
        if (document.values[index].name == name) return index;
    }
    unreachable("expected member");
}

fn uint named_entry(TextDocument* document, uint array, String name) @private {
    for (uint index = array + 1; index < document.values[array].end; index = document.values[index].end) {
        if (document.values[member(document, index, "name")].string == name) return index;
    }
    unreachable("expected named entry");
}

fn void test_schema_uses_declared_defaults_and_lists_binary_only_components() @test {
    @pool() {
        register_described_codecs();
        register_opaque();
        String schema = serial::write_schema(tmem)!!;
        assert(schema == serial::write_schema(tmem)!!);
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        TextDocument document = serial::parse_text(
            allocator: mem,
            source: schema,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        uint components = member(&document, 0, "components");
        uint opaque = named_entry(&document, components, "opaque");
        assert(document.values[member(&document, opaque, "binary_only")].boolean);
        assert(document.values[member(&document, opaque, "fields")].kind == TextKind.NIL);
        uint types = member(&document, 0, "types");
        uint number = named_entry(&document, types, Number::qname);
        uint defaults = member(&document, number, "defaults");
        assert(serial::text_read_unsigned(
            document: &document,
            value: member(&document, defaults, "count"),
            maximum: uint::max,
            diagnostic: &diagnostic,
        )!! == 3);
        assert(serial::text_read_float(&document, member(&document, defaults, "gain"), &diagnostic)!! == 0.5f);
        uint item = named_entry(&document, types, Item::qname);
        defaults = member(&document, item, "defaults");
        assert(document.values[member(&document, defaults, "label")].string == "item");
        uint owner = named_entry(&document, types, Owner::qname);
        defaults = member(&document, owner, "defaults");
        assert(document.values[member(&document, defaults, "items")].children == 0);
        assert(document.values[member(&document, defaults, "basis")].children == 16);
        assert(document.values[member(&document, defaults, "cells")].children == 3);
        uint fields = member(&document, owner, "fields");
        uint basis = named_entry(&document, fields, "basis");
        assert(document.values[member(&document, basis, "kind")].string == "MAT4");
        TextLimits exact = serial::TEXT_LIMITS_DEFAULT;
        exact.max_bytes = schema.len;
        assert(serial::write_schema(tmem, exact)!! == schema);
        exact.max_bytes--;
        if (catch excuse = serial::write_schema(tmem, exact)) {
            assert(excuse == c3d::CAPACITY_EXCEEDED);
        } else {
            assert(false);
        }
    };
}

fn void test_schema_retains_metadata_nested_fields_and_sorted_registration() @test {
    @pool() {
        initialize_json_descriptions();
        describe::register_reflected(SchemaDetails)!!;
        serial::register_described_type(
            $Type: SchemaDetails,
            version: 1,
            layout: serial::description_layout(describe::get(SchemaDetails)!!)!!,
            defaults: &defaults_schema_details,
        )!!;
        String schema = serial::write_schema(tmem)!!;
        assert(!json_hook_count);
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        TextDocument document = serial::parse_text(
            allocator: mem,
            source: schema,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        foreach (list_name : (String[]){ "components", "types" }) {
            uint array = member(&document, 0, list_name);
            String previous;
            for (uint index = array + 1; index < document.values[array].end; index = document.values[index].end) {
                String name = document.values[member(&document, index, "name")].string;
                if (previous.len) assert(previous.compare_to(name) < 0);
                previous = name;
            }
        }
        uint details = named_entry(&document, member(&document, 0, "types"), SchemaDetails::qname);
        uint fields = member(&document, details, "fields");
        uint count = named_entry(&document, fields, "count");
        assert(document.values[member(&document, count, "display_name")].string == "Count");
        assert(document.values[member(&document, count, "unit")].string == "items");
        uint range = member(&document, count, "range");
        assert(document.values[range].children == 2 && serial::text_read_double(&document, range + 1, &diagnostic)!! == 1);
        assert(serial::text_read_double(&document, range + 2, &diagnostic)!! == 9);
        uint mode = named_entry(&document, fields, "mode");
        uint names = member(&document, mode, "enum");
        assert(document.values[names + 1].string == "FIRST" && document.values[names + 2].string == "SECOND");
        uint material = named_entry(&document, fields, "material");
        assert(document.values[member(&document, material, "asset_kind")].string == "MATERIAL");
        uint children = named_entry(&document, fields, "children");
        assert(serial::text_lexeme(&document, member(&document, children, "extent")) == "2");
        uint element = member(&document, children, "element") + 1;
        assert(document.values[member(&document, element, "type")].string == JsonItem::qname);
        assert(document.values[member(&document, element, "fields")].children == 2);
        uint defaults = member(&document, details, "defaults");
        assert(serial::text_lexeme(&document, member(&document, defaults, "count")) == "5");
        assert(document.values[member(&document, defaults, "mode")].string == "SECOND");
    };
}

fn void test_schema_rejects_invalid_limits_and_output_allocation_failure() @test {
    register_described_codecs();
    FailingAllocator allocator = { .failure = 1 };
    TextLimits limits = serial::TEXT_LIMITS_DEFAULT;
    limits.max_depth = 0;
    assert(@catch(serial::write_schema(&allocator, limits)) == c3d::INVALID_ARGUMENT);
    assert(allocator.attempts == 0);
    assert(@catch(serial::write_schema(&allocator)) == c3d::CAPACITY_EXCEEDED);
    assert(allocator.attempts == 1 && !allocator.outstanding);
}
