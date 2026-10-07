module c3d::test::describe_consumers @private;

import c3d;
import c3d::describe;
import c3d::maths;
import std::math;
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

fn void test_json_numeric_leaves_preserve_unsigned_lanes_and_affine_coefficients() @test @public {
    describe::register_reflected(NumericFixture)!!;
    describe::Descriptor* descriptor = describe::get(NumericFixture)!!;
    NumericFixture original = numeric_fixture();
    JsonWriter writer;
    writer.text.init(mem);
    defer writer.text.free();
    json_write(descriptor, &writer, &original)!!;
    Object* parsed = json::parse(mem, writer.text.str_view())!!;
    defer parsed.free();
    JsonReader reader = { .root = parsed, .owned = { .allocator = mem } };
    defer reader.owned.release_all();
    NumericFixture result;
    json_read(descriptor, &reader, &result)!!;
    assert_numeric_fixture_equal(&original, &result);
    assert(reader.owned.attempts == 0);
}

fn void test_json_numeric_leaves_reject_narrow_overflow_and_invalid_unsigned_lanes() @test @public {
    describe::register_reflected(NumericFixture)!!;
    describe::Descriptor* descriptor = describe::get(NumericFixture)!!;
    @pool() {
        foreach (input : (String[]){
            `{"signed_byte":128}`,
            `{"signed_byte":-128,"unsigned_byte":256}`,
            `{"signed_byte":0,"unsigned_byte":0,"signed_short":-32769}`,
            `{"signed_byte":0,"unsigned_byte":0,"signed_short":0,"unsigned_short":65536}`,
            `{"signed_byte":0,"unsigned_byte":0,"signed_short":0,"unsigned_short":0,"counts":[1,-1,3]}`,
            `{"signed_byte":0,"unsigned_byte":0,"signed_short":0,"unsigned_short":0,"counts":[1,2,4294967296]}`,
            `{"signed_byte":0,"unsigned_byte":0,"signed_short":0,"unsigned_short":0,"counts":[1,2]}`,
        }) {
            JsonReader reader = {
                .root = json::tparse(input)!!,
                .owned = { .allocator = &allocators::NULL_ALLOCATOR },
            };
            NumericFixture result;
            if (catch excuse = json_read(descriptor, &reader, &result)) {
                assert(excuse == INVALID_FIXTURE);
            } else {
                assert(false);
            }
            assert(reader.owned.attempts == 0);
        }
    };
}

fn void test_json_matrix_coefficients_follow_column_vector_transform_semantics() @test @public {
    describe::register_reflected(NumericFixture)!!;
    NumericFixture original = numeric_fixture();
    original.affine = ((Transform){ .position = { 7, -9, 11 }, .scale = { 2, 3, 4 } }).to_mat4();
    JsonWriter writer;
    writer.text.init(mem);
    defer writer.text.free();
    json_write(describe::get(NumericFixture)!!, &writer, &original)!!;
    Object* parsed = json::parse(mem, writer.text.str_view())!!;
    defer parsed.free();
    Object* coefficients = parsed.get("affine")!!;
    assert(coefficients.len() == 16);
    float[16] expected = { 2, 0, 0, 0, 0, 3, 0, 0, 0, 0, 4, 0, 7, -9, 11, 1 };
    foreach (index, coefficient : expected) assert(json_number(coefficients.get_at(index))!! == coefficient);
    assert(original.affine.apply({ 1, 2, 3, 1 }) == (Vec4){ 9, -3, 23, 1 });
}

fn void test_json_matrix_lanes_preserve_exceptional_float_bits() @test @public {
    describe::register_reflected(NumericFixture)!!;
    NumericFixture original = numeric_fixture();
    uint[8] bits = { 0x7f800000, 0xff800000, 0x7f800001, 0xff800001, 0x7fc00001, 0xffc00001, 0, 0x80000000 };
    foreach (index, value : bits) original.affine.m[index] = bitcast(value, float);
    JsonWriter writer;
    writer.text.init(mem);
    defer writer.text.free();
    json_write(describe::get(NumericFixture)!!, &writer, &original)!!;
    assert(writer.text.str_view().contains("\"f32:7f800001\""));
    Object* parsed = json::parse(mem, writer.text.str_view())!!;
    defer parsed.free();
    JsonReader reader = { .root = parsed, .owned = { .allocator = mem } };
    defer reader.owned.release_all();
    NumericFixture restored;
    json_read(describe::get(NumericFixture)!!, &reader, &restored)!!;
    assert_numeric_fixture_equal(&original, &restored);
    JsonWriter repeated;
    repeated.text.init(mem);
    defer repeated.text.free();
    json_write(describe::get(NumericFixture)!!, &repeated, &restored)!!;
    assert(writer.text.str_view() == repeated.text.str_view());
    @pool() {
        foreach (input : (String[]){ `"f32:3f800000"`, `"f32:7F800001"`, `"f32:7f80000"`, `"f64:7ff0000000000000"` }) {
            if (catch excuse = json_float(json::tparse(input)!!)) {
                assert(excuse == INVALID_FIXTURE);
            } else {
                assert(false);
            }
        }
    };
}
