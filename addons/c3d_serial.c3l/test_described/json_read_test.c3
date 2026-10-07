module c3d::serial::test_described;

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::ecs;
import c3d::scene;
import c3d::serial @public;
import std::math;

enum JsonMode @private {
    FIRST,
    SECOND,
}

struct JsonScalars @private {
    bool enabled;
    ichar signed_byte;
    char byte;
    short small;
    ushort positive;
    int count;
    uint unsigned_count;
    long large;
    ulong huge;
    float single;
    double wide;
    Vec2 pair;
    Vec3 triple;
    Vec4 lanes;
    Quat rotation;
    JsonMode mode;
    int[] numbers;
}

struct JsonItem @private {
    String label;
    short amount;
    int derived @tag("transient", true);
}

struct JsonDefaults @private {
    JsonItem child;
    JsonItem[2] fixed;
    JsonItem[] items;
    String title;
}

struct JsonReferences @private {
    Entity target;
    MaterialId material;
    GeometryId geometry;
}

JsonItem[1] json_default_items @private = {
    { .label = "slice-default", .amount = 33 },
};
uint[8] json_hook_order @private;
uint json_hook_count @private;

fn void initialize_json_descriptions() @private {
    describe::register_reflected(JsonItem, &finish_json_item)!!;
    describe::register_reflected(JsonDefaults, &finish_json_defaults)!!;
    describe::register_reflected(JsonReferences)!!;
    describe::register_reflected(JsonScalars)!!;
    serial::register_described_type(
        $Type: JsonScalars,
        version: 1,
        layout: serial::description_layout(describe::get(JsonScalars)!!)!!,
        defaults: &defaults_json_scalars,
    )!!;
    serial::register_described_type(
        $Type: JsonItem,
        version: 1,
        layout: serial::description_layout(describe::get(JsonItem)!!)!!,
        defaults: &defaults_json_item,
    )!!;
    serial::register_described_type(
        $Type: JsonDefaults,
        version: 1,
        layout: serial::description_layout(describe::get(JsonDefaults)!!)!!,
        defaults: &defaults_json_defaults,
    )!!;
    serial::register_described_type(
        $Type: JsonReferences,
        version: 1,
        layout: serial::description_layout(describe::get(JsonReferences)!!)!!,
        defaults: &defaults_json_references,
    )!!;
    json_hook_order = {};
    json_hook_count = 0;
}

fn void defaults_json_scalars(void* raw) @private {
    *(JsonScalars*)raw = {};
}

fn void defaults_json_item(void* raw) @private {
    *(JsonItem*)raw = { .label = "item", .amount = -7 };
}

fn void defaults_json_defaults(void* raw) @private {
    *(JsonDefaults*)raw = {
        .child = { .label = "parent", .amount = 37, .derived = 74 },
        .fixed = {
            { .label = "fixed-a", .amount = 42, .derived = 84 },
            { .label = "fixed-b", .amount = 43, .derived = 86 },
        },
        .items = json_default_items[..],
        .title = "root",
    };
}

fn void defaults_json_references(void* raw) @private {
    *(JsonReferences*)raw = {};
}

fn void? finish_json_item(void* raw) @private {
    JsonItem* value = raw;
    if (value.amount == 13) return c3d::INVALID_ARGUMENT~;
    value.derived = value.amount * 2;
    json_hook_order[json_hook_count++] = 1;
}

fn void? finish_json_defaults(void* raw) @private {
    json_hook_order[json_hook_count++] = 2;
}

fn void? decode_json_value(
    DescribedType* type,
    String source,
    Acquisitions* owned,
    SerialDiagnostic* diagnostic,
    void* value,
    ReadContext* context = null,
    bool skip_unknown = false,
) @private {
    TextDocument document = serial::parse_text(
        allocator: mem,
        source: source,
        limits: serial::TEXT_LIMITS_DEFAULT,
        diagnostic: diagnostic,
    )!;
    defer serial::destroy_text_document(&document);
    serial::read_described_json(
        type: type,
        document: &document,
        token: 0,
        context: context,
        owned: owned,
        diagnostic: diagnostic,
        skip_unknown: skip_unknown,
        value: value,
    )!;
}

fn void test_json_reader_clones_default_storage_without_child_hooks() @test {
    initialize_json_descriptions();
    FailingAllocator counter;
    Acquisitions owned = { .allocator = &counter };
    defer owned.release();
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    JsonDefaults value;
    decode_json_value(
        type: serial::described_type(JsonDefaults)!!,
        source: "{}",
        owned: &owned,
        diagnostic: &diagnostic,
        value: &value,
    )!!;
    JsonDefaults defaults;
    defaults_json_defaults(&defaults);
    assert(value.child.label == "parent" && value.child.amount == 37 && value.child.derived == 74);
    assert(value.fixed[0].label == "fixed-a" && value.fixed[1].amount == 43);
    assert(value.items.len == 1 && value.items[0].label == "slice-default" && value.items[0].amount == 33);
    assert(value.items.ptr != &json_default_items[0]);
    assert(value.items[0].label.ptr != json_default_items[0].label.ptr);
    assert(value.child.label.ptr != defaults.child.label.ptr);
    assert(value.fixed[0].label.ptr != defaults.fixed[0].label.ptr);
    assert(value.title == "root" && value.title.ptr != defaults.title.ptr);
    assert(json_hook_count == 1 && json_hook_order[0] == 2);
    owned.release();
    assert(!counter.outstanding && json_default_items[0].label == "slice-default");
}

fn void test_json_reader_overlays_nested_defaults_and_initializes_new_slice_elements() @test {
    initialize_json_descriptions();
    Acquisitions owned = { .allocator = mem };
    defer owned.release();
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    JsonDefaults value;
    decode_json_value(
        type: serial::described_type(JsonDefaults)!!,
        source: `{"child":{"amount":8},"fixed":[{},{"label":"changed"}],"items":[{},{"amount":9}],"title":""}`,
        owned: &owned,
        diagnostic: &diagnostic,
        value: &value,
    )!!;
    assert(value.child.label == "parent" && value.child.amount == 8 && value.child.derived == 16);
    assert(value.fixed[0].label == "fixed-a" && value.fixed[0].amount == 42 && value.fixed[0].derived == 84);
    assert(value.fixed[1].label == "changed" && value.fixed[1].amount == 43 && value.fixed[1].derived == 86);
    assert(value.items.len == 2 && value.items[0].label == "item" && value.items[0].amount == -7);
    assert(value.items[0].derived == -14 && value.items[1].amount == 9 && value.items[1].derived == 18);
    assert(value.items[1].label == "item" && !value.title.len);
    assert(json_hook_count == 6 && json_hook_order[5] == 2);
    for (uint index = 0; index < 5; index++) assert(json_hook_order[index] == 1);
    assert(json_default_items[0].amount == 33 && json_default_items[0].label == "slice-default");
}

fn void test_json_reader_allocation_faults_release_defaults_and_overlay_storage() @test {
    initialize_json_descriptions();
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    String source = `{"child":{"label":"overlaid"},"items":[{"label":"first"},{"amount":9}],"title":"new"}`;
    JsonDefaults value;
    FailingAllocator counter;
    Acquisitions owned = { .allocator = &counter };
    defer owned.release();
    decode_json_value(
        type: serial::described_type(JsonDefaults)!!,
        source: source,
        owned: &owned,
        diagnostic: &diagnostic,
        value: &value,
    )!!;
    uint attempts = counter.attempts;
    assert(attempts > 10);
    owned.release();
    assert(!counter.outstanding);
    for (uint failure = 1; failure <= attempts; failure++) {
        counter = { .failure = failure };
        json_hook_count = 0;
        if (catch excuse = decode_json_value(
            type: serial::described_type(JsonDefaults)!!,
            source: source,
            owned: &owned,
            diagnostic: &diagnostic,
            value: &value,
        )) {
            assert(excuse == c3d::CAPACITY_EXCEEDED && diagnostic.cause == excuse);
            assert(diagnostic.has_text_position);
        } else {
            assert(false);
        }
        owned.release();
        assert(!counter.outstanding);
        assert(json_default_items[0].label == "slice-default" && json_default_items[0].amount == 33);
    }
}

fn void test_described_json_writer_emits_all_defaults_without_read_hooks() @test {
    initialize_json_descriptions();
    JsonDefaults value;
    defaults_json_defaults(&value);
    char[1024] storage;
    JsonOutput output = { .writer = serial::writer_over(storage[..]), .limits = serial::TEXT_LIMITS_DEFAULT };
    output.begin("", true)!!;
    serial::write_described_json(
        type: serial::described_type(JsonDefaults)!!,
        output: &output,
        context: null,
        value: &value,
    )!!;
    assert(json_hook_count == 0 && value.child.label == "parent" && value.items.ptr == &json_default_items[0]);
    SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
    defer serial::destroy_serial_diagnostic(&diagnostic);
    TextDocument document = serial::parse_text(
        allocator: mem,
        source: (String)storage[:output.writer.written()],
        limits: serial::TEXT_LIMITS_DEFAULT,
        diagnostic: &diagnostic,
    )!!;
    defer serial::destroy_text_document(&document);
    assert(document.values[0].children == 4);
    uint child = serial::json_member(&document, 0, "child");
    assert(document.values[child].children == 2);
    assert(document.values[serial::json_member(&document, child, "label")].string == "parent");
    uint amount = serial::json_member(&document, child, "amount");
    assert(serial::text_lexeme(&document, amount) == "37");
    assert(serial::json_member(&document, child, "derived") == serial::INDEX_NONE);
    assert(document.values[serial::json_member(&document, 0, "fixed")].children == 2);
    assert(document.values[serial::json_member(&document, 0, "items")].children == 1);
    assert(document.values[serial::json_member(&document, 0, "title")].string == "root");
}
