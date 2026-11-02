module c3d::serial::test_described;

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::ecs;
import c3d::scene;
import c3d::serial;

struct ValueNested @private {
    String label;
    int amount;
}

struct ValueRecord @private {
    float gain;
    String title;
    ValueNested nested;
    ValueNested[] extras;
}

struct ValueReferences @private {
    MaterialId material;
    Entity target;
}

fn void defaults_value_nested(void* raw) @private {
    *(ValueNested*)raw = { .label = "nested-default", .amount = 5 };
}

fn void defaults_value_record(void* raw) @private {
    *(ValueRecord*)raw = {
        .gain = 1.5f,
        .title = "untitled",
        .nested = { .label = "base", .amount = 10 },
    };
}

fn void defaults_value_references(void* raw) @private {
    *(ValueReferences*)raw = {};
}

fn void initialize_value_descriptions() @private {
    describe::register_reflected(ValueNested)!!;
    describe::register_reflected(ValueRecord)!!;
    describe::register_reflected(ValueReferences)!!;
    serial::register_described_type(
        $Type: ValueNested,
        version: 1,
        layout: serial::description_layout(describe::get(ValueNested)!!)!!,
        defaults: &defaults_value_nested,
    )!!;
    serial::register_described_type(
        $Type: ValueRecord,
        version: 1,
        layout: serial::description_layout(describe::get(ValueRecord)!!)!!,
        defaults: &defaults_value_record,
    )!!;
    serial::register_described_type(
        $Type: ValueReferences,
        version: 1,
        layout: serial::description_layout(describe::get(ValueReferences)!!)!!,
        defaults: &defaults_value_references,
    )!!;
}

fn bool value_records_equal(ValueRecord* left, ValueRecord* right) @private {
    if (left.gain != right.gain || left.title != right.title) return false;
    if (left.nested.label != right.nested.label || left.nested.amount != right.nested.amount) return false;
    if (left.extras.len != right.extras.len) return false;
    foreach (index, extra : left.extras) {
        if (extra.label != right.extras[index].label || extra.amount != right.extras[index].amount) return false;
    }
    return true;
}

fn void test_overlay_keeps_the_fields_the_text_omits() @test {
    initialize_value_descriptions();
    FailingAllocator counter;
    SerialStorage storage = serial::create_serial_storage(&counter);
    defer serial::destroy_serial_storage(&storage);
    DescribedType* type = serial::described_type(ValueRecord)!!;
    ValueRecord record;
    serial::read_value_text(
        type: type,
        text: `{"gain":2.5,"title":"first","nested":{"label":"inner","amount":3},"extras":[{"amount":4}]}`,
        value: &record,
        storage: &storage,
    )!!;
    assert(record.gain == 2.5f && record.title == "first");
    assert(record.nested.label == "inner" && record.nested.amount == 3);
    assert(record.extras.len == 1 && record.extras[0].label == "nested-default" && record.extras[0].amount == 4);

    serial::read_value_text(
        type: type,
        text: `{"gain":7.0,"nested":{"amount":9},"extras":[{},{"label":"b"}]}`,
        value: &record,
        storage: &storage,
        mode: OVERLAY,
    )!!;
    assert(record.gain == 7.0f && record.title == "first");
    assert(record.nested.label == "inner" && record.nested.amount == 9);
    assert(record.extras.len == 2);
    assert(record.extras[0].label == "nested-default" && record.extras[0].amount == 5);
    assert(record.extras[1].label == "b" && record.extras[1].amount == 5);

    serial::read_value_text(
        type: type,
        text: `{"gain":1.0}`,
        value: &record,
        storage: &storage,
    )!!;
    assert(record.gain == 1.0f && record.title == "untitled" && record.nested.label == "base");
    assert(!record.extras.len);

    storage.release();
    assert(!counter.outstanding);
}

fn void test_value_type_mismatch_reports_pointer_line_and_column() @test {
    initialize_value_descriptions();
    SerialStorage storage = serial::create_serial_storage(mem);
    defer serial::destroy_serial_storage(&storage);
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    ReadOptions options = serial::READ_OPTIONS_DEFAULT;
    options.diagnostic = &diagnostic;
    ValueRecord record;
    String text = "{\n  \"title\": \"x\",\n  \"gain\": \"loud\"\n}";
    if (catch excuse = serial::read_value_text(
        type: serial::described_type(ValueRecord)!!,
        text: text,
        value: &record,
        storage: &storage,
        options: options,
    )) {
        assert(excuse == c3d::ASSET_FORMAT_ERROR && diagnostic.cause == excuse);
        assert(diagnostic.pointer == "/gain" && diagnostic.line == 3 && diagnostic.byte_column == 11);
    } else {
        assert(false);
    }
}

fn void test_value_read_at_walks_records_of_a_document() @test {
    initialize_value_descriptions();
    SerialStorage storage = serial::create_serial_storage(mem);
    defer serial::destroy_serial_storage(&storage);
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    DescribedType* type = serial::described_type(ValueRecord)!!;
    String text = `{"alpha":{"gain":1.0},"beta":{"gain":2.0,"title":"b"},"gamma":{"nested":{"amount":3}}}`;
    TextDocument document = serial::parse_text(
        allocator: mem,
        source: text,
        limits: serial::TEXT_LIMITS_DEFAULT,
        diagnostic: &diagnostic,
    )!!;
    defer serial::destroy_text_document(&document);
    ValueRecord[3] records;
    String[3] names;
    uint count;
    document.@each_member(0; uint child) {
        names[count] = document.name(child);
        serial::read_value_at(
            type: type,
            document: &document,
            token: child,
            value: &records[count],
            storage: &storage,
        )!!;
        count++;
    };
    assert(count == 3 && names[0] == "alpha" && names[1] == "beta" && names[2] == "gamma");
    assert(records[0].gain == 1.0f && records[0].title == "untitled");
    assert(records[1].gain == 2.0f && records[1].title == "b");
    assert(records[2].gain == 1.5f && records[2].nested.amount == 3 && records[2].nested.label == "base");
    assert(document.kind(0) == TextKind.OBJECT && document.kind(document.member(0, "beta")!!) == TextKind.OBJECT);
    if (catch excuse = document.member(0, "missing")) {
        assert(excuse == NOT_FOUND);
    } else {
        assert(false);
    }

    String invalid = `{"alpha":{"gain":1.0},"beta":{"gain":true}}`;
    TextDocument rejected = serial::parse_text(
        allocator: mem,
        source: invalid,
        limits: serial::TEXT_LIMITS_DEFAULT,
        diagnostic: &diagnostic,
    )!!;
    defer serial::destroy_text_document(&rejected);
    ReadOptions options = serial::READ_OPTIONS_DEFAULT;
    options.diagnostic = &diagnostic;
    if (catch excuse = serial::read_value_at(
        type: type,
        document: &rejected,
        token: rejected.member(0, "beta")!!,
        value: &records[0],
        storage: &storage,
        options: options,
    )) {
        assert(excuse == c3d::ASSET_FORMAT_ERROR && diagnostic.pointer == "/beta/gain");
    } else {
        assert(false);
    }
}

fn void test_value_text_round_trips_nested_structs_and_slices() @test {
    initialize_value_descriptions();
    SerialStorage storage = serial::create_serial_storage(mem);
    defer serial::destroy_serial_storage(&storage);
    DescribedType* type = serial::described_type(ValueRecord)!!;
    ValueNested[2] extras = {
        { .label = "x \"quoted\"", .amount = 1 },
        { .label = "y", .amount = -2 },
    };
    ValueRecord original = {
        .gain = 2.25f,
        .title = "round trip",
        .nested = { .label = "n", .amount = -4 },
        .extras = extras[..],
    };
    String text = serial::write_value_text(
        allocator: mem,
        type: type,
        value: &original,
    )!!;
    defer alloc::free(mem, text.ptr);
    ValueRecord restored;
    serial::read_value_text(
        type: type,
        text: text,
        value: &restored,
        storage: &storage,
    )!!;
    assert(value_records_equal(&original, &restored));
    assert(restored.title.ptr != original.title.ptr && restored.extras.ptr != original.extras.ptr);
}

fn void test_value_write_fault_names_the_pointer_of_the_field() @test {
    initialize_value_descriptions();
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    TextWriteOptions options = serial::TEXT_WRITE_OPTIONS_DEFAULT;
    options.diagnostic = &diagnostic;
    char[1] invalid_utf8 = { 0xff };
    ValueNested[2] extras = {
        { .label = "valid", .amount = 1 },
        { .label = (String)invalid_utf8[..], .amount = 2 },
    };
    ValueRecord record = { .title = "t", .extras = extras[..] };
    if (catch excuse = serial::write_value_text(
        allocator: mem,
        type: serial::described_type(ValueRecord)!!,
        value: &record,
        options: options,
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT && diagnostic.cause == excuse);
        assert(diagnostic.pointer == "/extras/1/label" && !diagnostic.has_text_position);
    } else {
        assert(false);
    }
}

fn void test_value_references_resolve_through_a_store_and_fault_without_one() @test {
    initialize_value_descriptions();
    Fixture fixture;
    create_fixture(&fixture);
    defer destroy_fixture(&fixture);
    SerialStorage storage = serial::create_serial_storage(mem);
    defer serial::destroy_serial_storage(&storage);
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    DescribedType* type = serial::described_type(ValueReferences)!!;
    ReadOptions options = serial::READ_OPTIONS_DEFAULT;
    options.diagnostic = &diagnostic;
    TextWriteOptions write_options = serial::TEXT_WRITE_OPTIONS_DEFAULT;
    write_options.diagnostic = &diagnostic;
    MaterialId material = fixture.assets.add_material({}, "material-key")!!;
    Entity entity = fixture.destination.add_node(name: "node")!!.id;

    ValueReferences value;
    serial::read_value_text(
        type: type,
        text: `{"material":"material-key"}`,
        value: &value,
        storage: &storage,
        assets: &fixture.assets,
    )!!;
    assert(c3d::same_id(value.material, material));
    String text = serial::write_value_text(
        allocator: mem,
        type: type,
        value: &value,
        assets: &fixture.assets,
    )!!;
    defer alloc::free(mem, text.ptr);
    ValueReferences restored;
    serial::read_value_text(
        type: type,
        text: text,
        value: &restored,
        storage: &storage,
        assets: &fixture.assets,
    )!!;
    assert(c3d::same_id(restored.material, material));

    if (catch excuse = serial::read_value_text(
        type: type,
        text: `{"material":"material-key"}`,
        value: &value,
        storage: &storage,
        options: options,
    )) {
        assert(excuse == c3d::UNSUPPORTED && diagnostic.pointer == "/material");
    } else {
        assert(false);
    }
    serial::read_value_text(
        type: type,
        text: `{"material":null,"target":null}`,
        value: &value,
        storage: &storage,
    )!!;
    assert(!value.material.index && !value.target.index);

    if (catch excuse = serial::read_value_text(
        type: type,
        text: `{"target":0}`,
        value: &value,
        storage: &storage,
        options: options,
        assets: &fixture.assets,
    )) {
        assert(excuse == c3d::UNSUPPORTED && diagnostic.pointer == "/target");
    } else {
        assert(false);
    }
    value.target = entity;
    if (catch excuse = serial::write_value_text(
        allocator: mem,
        type: type,
        value: &value,
        options: write_options,
        assets: &fixture.assets,
    )) {
        assert(excuse == c3d::UNSUPPORTED && diagnostic.cause == excuse && diagnostic.pointer == "/target");
    } else {
        assert(false);
    }
    value.target = {};
    value.material = material;
    if (catch excuse = serial::write_value_text(
        allocator: mem,
        type: type,
        value: &value,
        options: write_options,
    )) {
        assert(excuse == c3d::UNSUPPORTED && diagnostic.pointer == "/material");
    } else {
        assert(false);
    }
}
