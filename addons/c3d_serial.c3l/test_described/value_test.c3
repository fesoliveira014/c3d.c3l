module c3d::serial::test_values;

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::maths;
import c3d::scene;
import c3d::serial @public;
import std::math;

const ulong SCALARS_LAYOUT @private = 0xbf6be8a0e47a4695;
const ulong ELEMENT_LAYOUT @private = 0xa60ad998206ebe88;
const ulong VALUE_LAYOUT @private = 0xd40e6390123c0f33;

enum Choice @private { FIRST, SECOND }

struct Scalars @private {
    bool flag;
    ichar signed_byte;
    char byte;
    short signed_short;
    ushort unsigned_short;
    int signed_int;
    uint unsigned_int;
    long signed_long;
    ulong unsigned_long;
    float single;
    double wide;
    Vec2 pair;
    Vec3 triple;
    Vec4 quad;
    Quat rotation;
    uint[<3>] cells;
    Mat4 matrix;
    Choice choice;
    Entity target;
    GeometryId geometry;
}

struct Element @private { String label; short amount; }

struct Value @private {
    Scalars scalars;
    Element[] elements;
    String label;
    uint[3] fixed;
}

struct SameElement @private { String label; short amount; }

struct ValueAllocator (Allocator) @private {
    uint attempts;
    uint failure;
    uint outstanding;
}

fn void*? ValueAllocator.acquire(&self, sz size, AllocInitType init_type, sz alignment) @dynamic {
    if (++self.attempts == self.failure) return mem::OUT_OF_MEMORY~;
    void* allocation = mem.acquire(size, init_type, alignment)!;
    self.outstanding++;
    return allocation;
}

fn void*? ValueAllocator.resize(&self, void* pointer, sz size, sz alignment) @dynamic {
    if (++self.attempts == self.failure) return mem::OUT_OF_MEMORY~;
    return mem.resize(pointer, size, alignment);
}

fn void ValueAllocator.release(&self, void* pointer, bool aligned) @dynamic {
    self.outstanding--;
    mem.release(pointer, aligned);
}

fn void defaults_scalars(void* value) @private { *(Scalars*)value = {}; }
fn void defaults_element(void* value) @private { *(Element*)value = { .label = "default", .amount = -7 }; }
fn void defaults_value(void* value) @private { *(Value*)value = { .label = "value" }; }

macro void? register_value($Type, ulong layout, DefaultsFn defaults) @private {
    serial::register_described_type(
        $Type: $Type,
        version: 1,
        layout: layout,
        defaults: defaults,
    )!;
}

fn void register_values() @private {
    describe::register_reflected(Scalars)!!;
    describe::register_reflected(Element)!!;
    describe::register_reflected(Value)!!;
    register_value(Scalars, SCALARS_LAYOUT, &defaults_scalars)!!;
    register_value(Element, ELEMENT_LAYOUT, &defaults_element)!!;
    register_value(Value, VALUE_LAYOUT, &defaults_value)!!;
}

fn Value source_value(Element[] elements) @private {
    return {
        .scalars = {
            .flag = true, .signed_byte = ichar::min, .byte = char::max,
            .signed_short = short::min, .unsigned_short = ushort::max,
            .signed_int = int::min, .unsigned_int = uint::max,
            .signed_long = long::min, .unsigned_long = ulong::max,
            .single = -0.0f, .wide = bitcast(0x7ff0000000000001UL, double),
            .pair = { 1, -2 }, .triple = { 3, -4, 5 }, .quad = { 6, -7, 8, -9 },
            .rotation = { .v = { 0.25f, 0.5f, 0.75f, 1 } },
            .cells = { 0, 2147483648U, uint::max }, .matrix = matrix::IDENTITY4, .choice = SECOND,
        },
        .elements = elements, .label = "owned", .fixed = { 1, 2, uint::max },
    };
}

fn char[] encoded(Value* value, char[] storage) @private {
    AssetStore assets;
    WriteState state;
    WriteContext context = { .assets = &assets, .state = &state };
    DescribedType* type = serial::described_type(Value)!!;
    Writer measure = serial::measuring_writer();
    serial::write_described_value(
        type: type,
        writer: &measure,
        context: &context,
        value: value,
    )!!;
    assert(measure.written() <= storage.len);
    char[] bytes = storage[:measure.written()];
    Writer writer = serial::writer_over(bytes);
    serial::write_described_value(
        type: type,
        writer: &writer,
        context: &context,
        value: value,
    )!!;
    assert(writer.written() == measure.written());
    return bytes;
}

fn void? decoded(char[] bytes, Acquisitions* owned, Value* value) @private {
    Reader reader = serial::reader_over(bytes);
    ReadContext context;
    serial::read_described_value(
        type: serial::described_type(Value)!!,
        reader: &reader,
        context: &context,
        owned: owned,
        value: value,
    )!;
}

fn void test_registered_layout_pins_defaults_and_conflicts() @test {
    register_values();
    describe::register_reflected(SameElement)!!;
    assert(serial::description_layout(describe::get(SameElement)!!)!! == serial::described_type(Element)!!.layout);
    assert(@catch(register_value(Value, serial::described_type(Value)!!.layout ^ 1, &defaults_value)) == c3d::INVALID_ARGUMENT);
    assert(@catch(register_value(Value, serial::described_type(Value)!!.layout, null)) == c3d::INVALID_ARGUMENT);
    assert(@catch(register_value(Value, serial::described_type(Value)!!.layout, &defaults_scalars)) == c3d::INVALID_ARGUMENT);
    assert(@catch(serial::register_described_type(
        $Type: Value,
        version: 2,
        layout: serial::described_type(Value)!!.layout,
        defaults: &defaults_value,
    )) == c3d::INVALID_ARGUMENT);
    serial::register_core_value_types()!!;
    Transform transform;
    serial::described_type(Transform)!!.defaults(&transform);
    assert(transform.scale == (Vec3){ 1, 1, 1 } && transform.rotation.v.w == 1);
    Mesh mesh;
    serial::described_type(Mesh)!!.defaults(&mesh);
    assert(mesh.cast_shadow && mesh.receive_shadow && mesh.trace);
}

fn void test_described_fields_round_trip_exact_bits_and_owned_storage() @test {
    register_values();
    Element[2] elements = { { .label = "first", .amount = short::min }, { .label = "second", .amount = short::max } };
    Value original = source_value(&elements);
    original.scalars.matrix.m01 = 0.375f;
    original.scalars.matrix.m22 = -2;
    char[1024] storage, repeated;
    char[] bytes = encoded(&original, &storage);
    usz scalar_offset = 4 * uint::size + 2 * ulong::size;
    assert(bytes[scalar_offset:11] == (char[]){ 1, 0x80, 0xff, 0, 0x80, 0xff, 0xff, 0, 0, 0, 0x80 });
    ValueAllocator allocator;
    Acquisitions owned = { .allocator = &allocator };
    Value restored;
    decoded(bytes, &owned, &restored)!!;
    assert(restored.scalars.flag && restored.scalars.signed_byte == ichar::min && restored.scalars.byte == char::max);
    assert(restored.scalars.signed_short == short::min && restored.scalars.unsigned_short == ushort::max);
    assert(restored.scalars.signed_int == int::min && restored.scalars.unsigned_int == uint::max);
    assert(restored.scalars.signed_long == long::min && restored.scalars.unsigned_long == ulong::max);
    assert(bitcast(restored.scalars.single, uint) == 0x80000000U && bitcast(restored.scalars.wide, ulong) == 0x7ff0000000000001UL);
    assert(restored.scalars.pair == original.scalars.pair && restored.scalars.triple == original.scalars.triple);
    assert(restored.scalars.quad == original.scalars.quad && restored.scalars.rotation.v == original.scalars.rotation.v);
    assert(restored.scalars.cells == original.scalars.cells && restored.scalars.choice == SECOND);
    assert(restored.scalars.matrix.m01 == 0.375f && restored.scalars.matrix.m22 == -2);
    assert(!restored.scalars.target.index && !restored.scalars.geometry.index);
    assert(restored.elements.ptr != &elements[0] && restored.elements[0].label.ptr != elements[0].label.ptr);
    assert(restored.elements[0].label == "first" && restored.elements[1].amount == short::max);
    assert(restored.label == "owned" && restored.label.ptr != original.label.ptr && restored.fixed[2] == uint::max);
    assert(encoded(&restored, &repeated) == bytes && allocator.attempts == 4);
    storage[..] = 0;
    assert(restored.elements[1].label == "second" && restored.label == "owned");
    owned.release();
    assert(!allocator.outstanding);
}

fn void test_described_field_truncation_and_allocation_failures_release_storage() @test {
    register_values();
    Element[2] elements = { { .label = "first", .amount = -1 }, { .label = "second", .amount = 2 } };
    Value original = source_value(&elements);
    char[1024] storage;
    char[] bytes = encoded(&original, &storage);
    for (usz cut = 0; cut < bytes.len; cut++) {
        ValueAllocator allocator;
        Acquisitions owned = { .allocator = &allocator };
        Value value;
        assert(@catch(decoded(bytes[:cut], &owned, &value)) == c3d::ASSET_FORMAT_ERROR);
        owned.release();
        assert(!allocator.outstanding);
    }
    for (uint failure = 1; failure <= 4; failure++) {
        ValueAllocator allocator = { .failure = failure };
        Acquisitions owned = { .allocator = &allocator };
        Value value;
        assert(@catch(decoded(bytes, &owned, &value)) == c3d::CAPACITY_EXCEEDED);
        owned.release();
        assert(!allocator.outstanding && original.elements[0].label == "first");
    }
}

fn void test_described_payload_rejects_layout_drift_and_wrong_versions() @test {
    register_values();
    Value original = source_value({});
    char[1024] storage;
    char[] bytes = encoded(&original, &storage);
    foreach (offset : (usz[]){ 0, uint::size }) {
        char saved = bytes[offset];
        bytes[offset] ^= 1;
        ValueAllocator allocator;
        Acquisitions owned = { .allocator = &allocator };
        Value value;
        assert(@catch(decoded(bytes, &owned, &value)) == (offset ? c3d::ASSET_FORMAT_ERROR : c3d::UNSUPPORTED));
        owned.release();
        assert(!allocator.outstanding);
        bytes[offset] = saved;
    }
}
