module c3d::test::describe_consumers @private;

import c3d;
import c3d::describe;
import std::core::mem::allocators;
import std::math;
import described_component;

const usz FIXTURE_BYTES = 16384;
const usz MAX_ELEMENTS = 64;
const usz MAX_OWNED_BYTES = 32768;
const usz MAX_ACQUISITIONS = 64;
const usz MAX_SCOPES = 16;

enum FixtureStyle : ushort {
    FIRST,
    SECOND,
    THIRD,
}

struct FixtureNested {
    uint[] weights;
    int nested_guard;
}

struct FixtureEntry @align(32) {
    String label;
    uint amount;
}

struct Fixture {
    uint[] top_values;
    int signed_count;
    uint unsigned_count;
    long signed_total;
    ulong unsigned_total;
    double precision @tag("display", "Precision") @tag("range", { -2.0, 2.0 }) @tag("unit", "rad");
    Vec2 direction;
    Vec4 tint;
    Quat rotation;
    String title;
    FixtureStyle category;
    Entity owner;
    TextureId texture;
    FixtureNested nested;
    int[3] steps;
    FixtureEntry[] entries;
    uint derived @tag("transient", true);
}

struct FixtureSource {
    uint[2] top_values;
    uint[3] weights;
    FixtureEntry[2] entries;
    Fixture value;
}

struct Acquisitions {
    Allocator allocator;
    void*[MAX_ACQUISITIONS] pointers;
    bool[MAX_ACQUISITIONS] aligned;
    usz count;
    usz bytes;
    usz attempts;
}

fn void*? Acquisitions.acquire(
    &self,
    usz count,
    usz size,
    usz alignment = 0,
) {
    if (count > MAX_ELEMENTS || size && count > (MAX_OWNED_BYTES - self.bytes) / size) {
        return INVALID_FIXTURE~;
    }
    usz bytes = count * size;
    if (!bytes) return null;
    if (self.count == MAX_ACQUISITIONS) return INVALID_FIXTURE~;
    self.attempts++;
    void* pointer = self.allocator.acquire((sz)bytes, ZERO, (sz)alignment)!;
    self.aligned[self.count] = alignment != 0;
    self.pointers[self.count++] = pointer;
    self.bytes += bytes;
    return pointer;
}

fn void Acquisitions.release_all(&self) {
    while (self.count) {
        self.count--;
        self.allocator.release(self.pointers[self.count], self.aligned[self.count]);
    }
    self.bytes = 0;
}

fn usz vector_size(describe::Kind kind) {
    switch (kind) {
        case VEC2: return 2;
        case VEC3: return 3;
        case VEC4:
        case QUAT: return 4;
        case BOOL:
        case INT:
        case UINT:
        case LONG:
        case ULONG:
        case FLOAT:
        case DOUBLE:
        case STRING:
        case ENUM:
        case ENTITY:
        case ASSET:
        case STRUCT:
        case ARRAY:
        case SLICE: unreachable();
    }
}

fn void? register_fixtures() {
    describe::register_reflected(FixtureNested)!;
    describe::register_reflected(FixtureEntry)!;
    describe::register_reflected(Fixture, after: &finish_fixture)!;
}

fn void? finish_fixture(void* raw) {
    Fixture* value = (Fixture*)raw;
    value.derived = value.unsigned_count + 1;
}

fn void assert_fixture_equal(Fixture* first, Fixture* second) {
    assert(first.top_values == second.top_values);
    assert(first.signed_count == second.signed_count);
    assert(first.unsigned_count == second.unsigned_count);
    assert(first.signed_total == second.signed_total);
    assert(first.unsigned_total == second.unsigned_total);
    assert(bitcast(first.precision, ulong) == bitcast(second.precision, ulong));
    assert(first.direction == second.direction);
    assert(bitcast(first.direction.x, uint) == bitcast(second.direction.x, uint));
    assert(first.tint == second.tint);
    assert(first.rotation.v == second.rotation.v);
    assert(first.title == second.title);
    assert(first.category == second.category);
    assert(c3d::same_id(first.owner, second.owner));
    assert(c3d::same_id(first.texture, second.texture));
    assert(first.nested.weights == second.nested.weights);
    assert(first.nested.nested_guard == second.nested.nested_guard);
    assert(first.steps == second.steps);
    assert(first.entries.len == second.entries.len);
    if (second.entries.len) assert((uptr)second.entries.ptr % FixtureEntry::alignment == 0);
    foreach (index, entry : first.entries) {
        assert(entry.label == second.entries[index].label);
        assert(entry.amount == second.entries[index].amount);
    }
    assert(second.derived == second.unsigned_count + 1);
}

fn void initialize_fixture(FixtureSource* source) {
    source.top_values = { 7, 11 };
    source.weights = { 2, 3, 5 };
    source.entries = {
        { .label = "first\nentry", .amount = 17 },
        { .label = "quoted \"name\"", .amount = 19 },
    };
    source.value = {
        .top_values = source.top_values[..],
        .signed_count = int::min,
        .unsigned_count = uint::max - 1,
        .signed_total = long::min,
        .unsigned_total = ulong::max,
        .precision = 1.2345678901234567,
        .direction = { -0.0f, 0.75f },
        .tint = { 0.125f, 0.25f, 0.5f, 1.0f },
        .rotation = { .v = { 0, 0.6f, 0, 0.8f } },
        .title = "sample \"title\"\n",
        .category = THIRD,
        .owner = { .index = 17, .generation = 4 },
        .texture = { .index = 23, .generation = 7 },
        .nested = { .weights = source.weights[..], .nested_guard = 29 },
        .steps = { -3, 0, 8 },
        .entries = source.entries[..],
        .derived = 0,
    };
}

fn void assert_demo_equal(DescribedComponent* first, DescribedComponent* second) {
    assert(first.enabled == second.enabled);
    assert(first.speed == second.speed);
    assert(first.mode == second.mode);
    assert(first.offset == second.offset);
    assert(c3d::same_id(first.target, second.target));
    assert(c3d::same_id(first.geometry, second.geometry));
    assert(second.speed_squared == second.speed * second.speed);
}

fn DescribedComponent demo_fixture() {
    return {
        .enabled = true,
        .speed = 2.5f,
        .mode = ORBIT,
        .offset = { 1, 2, -3 },
        .target = { .index = 13, .generation = 5 },
        .geometry = { .index = 23, .generation = 7 },
        .speed_squared = -1,
    };
}
