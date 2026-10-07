module c3d::test::describe_consumers @private;

import c3d;
import c3d::describe;
import described_component;
import std::core::mem;
import std::core::mem::allocators;
import std::io;

fn void test_shared_demo_binary_roundtrip() @test @public {
    described_component::register_described_component()!!;
    describe::Descriptor* descriptor = describe::get(DescribedComponent)!!;
    DescribedComponent original = demo_fixture();
    BinaryWriter writer;
    mem::@scoped(&allocators::NULL_ALLOCATOR) {
        Allocator previous_temp = allocators::current_temp;
        allocators::current_temp = &allocators::NULL_ALLOCATOR;
        defer allocators::current_temp = previous_temp;
        binary_write(descriptor, &writer, &original)!!;
    };
    BinaryReader reader = { .bytes = writer.bytes[:writer.position], .owned = { .allocator = mem } };
    defer reader.owned.release_all();
    DescribedComponent result;
    binary_read(descriptor, &reader, &result)!!;
    assert_demo_equal(&original, &result);
    assert(original.speed_squared == -1);
}

fn void check_binary_owned_roundtrip(Fixture* original) {
    describe::Descriptor* descriptor = describe::get(Fixture)!!;
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    BinaryWriter writer;
    binary_write(descriptor, &writer, original)!!;
    BinaryReader reader = { .bytes = writer.bytes[:writer.position], .owned = { .allocator = &tracking } };
    Fixture result;
    binary_read(descriptor, &reader, &result)!!;
    writer.bytes[..] = 0xEE;
    assert_fixture_equal(original, &result);
    reader.owned.release_all();
    assert(tracking.allocation_count() == 0);
    assert(original.derived == 0);
}

fn void test_binary_owned_roundtrips_survive_input_destruction() @test @public {
    register_fixtures()!!;
    FixtureSource source;
    initialize_fixture(&source);
    check_binary_owned_roundtrip(&source.value);
    source.value.precision = -0.0;
    for (sz count = 0; count < 2; count++) {
        source.value.top_values = source.top_values[:count];
        source.value.nested.weights = source.weights[:3 - count];
        source.value.entries = source.entries[:count];
        source.value.title = "";
        check_binary_owned_roundtrip(&source.value);
    }
}

fn void test_binary_faults_release_each_nesting_depth() @test @public {
    register_fixtures()!!;
    FixtureSource source;
    initialize_fixture(&source);
    describe::Descriptor* descriptor = describe::get(Fixture)!!;
    BinaryWriter writer;
    binary_write(descriptor, &writer, &source.value)!!;
    foreach (index, failure : (String[]){ "signed_count", "nested_guard", "amount" }) {
        TrackingAllocator tracking;
        tracking.init(mem);
        defer tracking.free();
        BinaryReader reader = {
            .bytes = writer.bytes[:writer.position],
            .owned = { .allocator = &tracking },
            .fail_name = failure,
        };
        Fixture partial;
        if (catch excuse = binary_read(descriptor, &reader, &partial)) {
            assert(excuse == CONSUMER_ABORT);
        } else {
            assert(false);
        }
        assert(reader.owned.attempts >= (usz)index + 1);
        assert(reader.owned.count == 0);
        assert(tracking.allocation_count() == 0);
    }
}

fn void test_binary_bad_lengths_fail_before_destination_allocation() @test @public {
    register_fixtures()!!;
    FixtureSource source;
    initialize_fixture(&source);
    describe::Descriptor* descriptor = describe::get(Fixture)!!;
    BinaryWriter writer;
    binary_write(descriptor, &writer, &source.value)!!;
    for (usz variant = 0; variant < 3; variant++) {
        BinaryReader reader = {
            .bytes = writer.bytes[:writer.position - (variant == 0 ? 1u : 0u)],
            .owned = { .allocator = &allocators::NULL_ALLOCATOR },
        };
        if (variant == 1) writer.bytes[uint::size:uint::size] = 0xFF;
        if (variant == 2) {
            writer.bytes[uint::size:uint::size] = 0;
            writer.bytes[uint::size] = 3;
        }
        Fixture partial;
        if (catch excuse = binary_read(descriptor, &reader, &partial)) {
            if (excuse != INVALID_FIXTURE) {
                io::printfn("Unexpected length fault: %s; allocation attempts: %s", excuse, reader.owned.attempts);
            }
            assert(excuse == INVALID_FIXTURE);
        } else {
            assert(false);
        }
        assert(reader.owned.attempts == 0);
    }
}

fn void test_binary_destination_out_of_memory_propagates_unchanged() @test @public {
    register_fixtures()!!;
    FixtureSource source;
    initialize_fixture(&source);
    describe::Descriptor* descriptor = describe::get(Fixture)!!;
    BinaryWriter writer;
    binary_write(descriptor, &writer, &source.value)!!;
    BinaryReader reader = {
        .bytes = writer.bytes[:writer.position],
        .owned = { .allocator = &allocators::NULL_ALLOCATOR },
    };
    Fixture partial;
    if (catch excuse = binary_read(descriptor, &reader, &partial)) {
        assert(excuse == mem::OUT_OF_MEMORY);
    } else {
        assert(false);
    }
    assert(reader.owned.attempts == 1 && reader.owned.count == 0);
}
