module c3d::test::describe_consumers @private;

import c3d;
import c3d::describe;
import described_component;
import std::collections::object;
import std::core::mem::allocators;
import std::encoding::json;

fn void test_shared_demo_json_roundtrip() @test @public {
    described_component::register_described_component()!!;
    describe::Descriptor* descriptor = describe::get(DescribedComponent)!!;
    DescribedComponent original = demo_fixture();
    JsonWriter writer;
    writer.text.init(mem);
    defer writer.text.free();
    writer.text.append("/* settings */\n");
    json_write(descriptor, &writer, &original)!!;
    assert((usz)writer.text.len() < FIXTURE_BYTES);
    Object* parsed = json::parse(mem, writer.text.str_view())!!;
    defer parsed.free();
    JsonReader reader = { .root = parsed, .owned = { .allocator = mem } };
    defer reader.owned.release_all();
    DescribedComponent result;
    json_read(descriptor, &reader, &result)!!;
    assert_demo_equal(&original, &result);
    assert(original.speed_squared == -1);
}

fn void check_json_owned_roundtrip(Fixture* original) {
    describe::Descriptor* descriptor = describe::get(Fixture)!!;
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    JsonWriter writer;
    writer.text.init(mem);
    defer writer.text.free();
    json_write(descriptor, &writer, original)!!;
    assert((usz)writer.text.len() < FIXTURE_BYTES);
    Object* parsed = json::parse(mem, writer.text.str_view())!!;
    JsonReader reader = { .root = parsed, .owned = { .allocator = &tracking } };
    Fixture result;
    json_read(descriptor, &reader, &result)!!;
    ((char[])writer.text.str_view())[..] = '?';
    parsed.free();
    assert_fixture_equal(original, &result);
    reader.owned.release_all();
    assert(tracking.allocation_count() == 0);
    assert(original.derived == 0);
}

fn void test_json_owned_roundtrips_survive_input_destruction() @test @public {
    register_fixtures()!!;
    FixtureSource source;
    initialize_fixture(&source);
    check_json_owned_roundtrip(&source.value);
    source.value.precision = -0.0;
    for (sz count = 0; count < 2; count++) {
        source.value.top_values = source.top_values[:count];
        source.value.nested.weights = source.weights[:3 - count];
        source.value.entries = source.entries[:count];
        source.value.title = "";
        check_json_owned_roundtrip(&source.value);
    }
}

fn void test_json_faults_release_each_nesting_depth() @test @public {
    register_fixtures()!!;
    FixtureSource source;
    initialize_fixture(&source);
    describe::Descriptor* descriptor = describe::get(Fixture)!!;
    JsonWriter writer;
    writer.text.init(mem);
    defer writer.text.free();
    json_write(descriptor, &writer, &source.value)!!;
    Object* parsed = json::parse(mem, writer.text.str_view())!!;
    defer parsed.free();
    foreach (index, failure : (String[]){ "signed_count", "nested_guard", "amount" }) {
        TrackingAllocator tracking;
        tracking.init(mem);
        defer tracking.free();
        JsonReader reader = { .root = parsed, .owned = { .allocator = &tracking }, .fail_name = failure };
        Fixture partial;
        if (catch excuse = json_read(descriptor, &reader, &partial)) {
            assert(excuse == CONSUMER_ABORT);
        } else {
            assert(false);
        }
        assert(reader.owned.attempts >= (usz)index + 1);
        assert(reader.owned.count == 0);
        assert(tracking.allocation_count() == 0);
    }
}

fn void test_json_bad_shapes_and_lengths_fail_before_allocation() @test @public {
    register_fixtures()!!;
    describe::Descriptor* descriptor = describe::get(Fixture)!!;
    @pool() {
        foreach (input : (String[]){
            `{"top_values":[],"signed_count":2147483648}`,
            `{"top_values":{},"signed_count":0}`,
        }) {
            JsonReader reader = {
                .root = json::tparse(input)!!,
                .owned = { .allocator = &allocators::NULL_ALLOCATOR },
            };
            Fixture partial;
            if (catch excuse = json_read(descriptor, &reader, &partial)) {
                assert(excuse == INVALID_FIXTURE);
            } else {
                assert(false);
            }
            assert(reader.owned.attempts == 0);
        }
        DString input;
        input.tinit();
        input.append(`{"top_values":[`);
        for (usz index = 0; index <= MAX_ELEMENTS; index++) {
            if (index) input.append(',');
            input.append('0');
        }
        input.append("]}");
        JsonReader oversized = {
            .root = json::tparse(input.str_view())!!,
            .owned = { .allocator = &allocators::NULL_ALLOCATOR },
        };
        Fixture partial;
        if (catch excuse = json_read(descriptor, &oversized, &partial)) {
            assert(excuse == INVALID_FIXTURE);
        } else {
            assert(false);
        }
        assert(oversized.owned.attempts == 0);
    };
}

fn void test_json_destination_out_of_memory_propagates_unchanged() @test @public {
    register_fixtures()!!;
    FixtureSource source;
    initialize_fixture(&source);
    describe::Descriptor* descriptor = describe::get(Fixture)!!;
    JsonWriter writer;
    writer.text.init(mem);
    defer writer.text.free();
    json_write(descriptor, &writer, &source.value)!!;
    Object* parsed = json::parse(mem, writer.text.str_view())!!;
    defer parsed.free();
    JsonReader reader = { .root = parsed, .owned = { .allocator = &allocators::NULL_ALLOCATOR } };
    Fixture partial;
    if (catch excuse = json_read(descriptor, &reader, &partial)) {
        assert(excuse == mem::OUT_OF_MEMORY);
    } else {
        assert(false);
    }
    assert(reader.owned.attempts == 1 && reader.owned.count == 0);
}
