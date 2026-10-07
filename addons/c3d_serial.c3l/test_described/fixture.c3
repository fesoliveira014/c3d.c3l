module c3d::serial::test_described;

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::ecs;
import c3d::scene;
import c3d::serial;
import std::math;

const ulong NUMBER_LAYOUT @private = 0xbee18e5f208356dd;
const ulong ITEM_LAYOUT @private = 0xa60ad998206ebe88;
const ulong OWNER_LAYOUT @private = 0x0d6b3b20eb90bfdb;

serial::BinaryCompatibility[1] number_compatibility @private = {
    { .version = 1, .read = &read_old_number },
};

struct Number @private {
    uint count;
    float gain;
    Entity target;
}

struct Item @private {
    String label;
    short amount;
}

struct Owner @private {
    Item[] items;
    ulong total;
    double precision;
    uint[<3>] cells;
    Mat4 basis;
}

struct Fixture @private {
    Scene source;
    Scene destination;
    AssetStore assets;
    uint removed;
}

struct FailingAllocator (Allocator) @private {
    uint attempts;
    uint failure;
    uint outstanding;
}

fn void*? FailingAllocator.acquire(&self, sz size, AllocInitType init_type, sz alignment) @dynamic {
    if (++self.attempts == self.failure) return mem::OUT_OF_MEMORY~;
    void* pointer = mem.acquire(size, init_type, alignment)!;
    self.outstanding++;
    return pointer;
}

fn void*? FailingAllocator.resize(&self, void* pointer, sz size, sz alignment) @dynamic {
    if (++self.attempts == self.failure) return mem::OUT_OF_MEMORY~;
    return mem.resize(pointer, size, alignment);
}

fn void FailingAllocator.release(&self, void* pointer, bool aligned) @dynamic {
    self.outstanding--;
    mem.release(pointer, aligned);
}

fn void initialize_descriptions() @private {
    describe::register_reflected(Number)!!;
    describe::register_reflected(Item)!!;
    describe::register_reflected(Owner)!!;
}

fn void defaults_number(void* raw) @private {
    *(Number*)raw = { .count = 3, .gain = 0.5f };
}

fn void defaults_item(void* raw) @private {
    *(Item*)raw = { .label = "item", .amount = -7 };
}

fn void defaults_owner(void* raw) @private {
    *(Owner*)raw = { .total = 17, .precision = 0.25, .cells = { 1, 2, 3 }, .basis = matrix::IDENTITY4 };
}

fn void register_described_codecs() @private {
    initialize_descriptions();
    serial::register_described_type(
        $Type: Number,
        version: 2,
        layout: NUMBER_LAYOUT,
        defaults: &defaults_number,
    )!!;
    serial::register_described_type(
        $Type: Item,
        version: 1,
        layout: ITEM_LAYOUT,
        defaults: &defaults_item,
    )!!;
    serial::register_described_type(
        $Type: Owner,
        version: 1,
        layout: OWNER_LAYOUT,
        defaults: &defaults_owner,
    )!!;
    serial::register_described(Number, {
        .name = "number",
        .phase = REFERENCES,
        .binary_compatibility = number_compatibility[..],
    })!!;
    serial::register_described(Owner, { .name = "owner", .attach = &attach_owner })!!;
}

fn void create_fixture(Fixture* fixture) @private {
    register_described_codecs();
    fixture.source = scene::create_scene(mem, { .max_nodes = 16 });
    fixture.destination = scene::create_scene(mem, { .max_nodes = 16 });
    fixture.source.register(Number)!!;
    fixture.source.register(Owner)!!;
    fixture.destination.register(Number)!!;
    fixture.destination.register(Owner)!!;
    fixture.source.set_remove_hook(Owner, &remove_owner, &fixture.removed);
    fixture.destination.set_remove_hook(Owner, &remove_owner, &fixture.removed);
    fixture.assets = asset::create_asset_store(mem, {
        .max_geometries = 2,
        .max_textures = 8,
        .max_materials = 2,
        .max_samplers = 8,
        .max_models = 1,
        .max_skeletons = 1,
        .max_clips = 1,
        .max_environments = 1,
        .max_shaders = 1,
        .max_compute_shaders = 1,
        .max_fonts = 1,
    });
}

fn void destroy_fixture(Fixture* fixture) @private {
    scene::destroy_scene(&fixture.destination);
    scene::destroy_scene(&fixture.source);
    asset::destroy_asset_store(&fixture.assets);
}

fn void? attach_owner(void* raw, ReadContext* context) @private {
    Owner value = *(Owner*)raw;
    if (value.total == 99) return c3d::INVALID_ARGUMENT~;
    value.items = alloc::clone_slice(mem, value.items);
    foreach (&item : value.items) item.label = item.label.copy(mem);
    context.scene.add(context.node, value);
}

fn void remove_owner(Entity entity, void* raw, void* user) @private {
    Owner* value = raw;
    foreach (item : value.items) alloc::free(mem, item.label.ptr);
    alloc::free(mem, value.items.ptr);
    (*(uint*)user)++;
}

fn void? read_old_number(Reader* reader, ReadContext* context) @private {
    Number value;
    defaults_number(&value);
    value.count = reader.read_uint()!;
    if (reader.remaining()) return c3d::ASSET_FORMAT_ERROR~;
    context.scene.add(context.node, value);
}

fn void? write_old_number(void* raw, Writer* writer, WriteContext* context) @private {
    writer.write_uint(((Number*)raw).count);
}

fn Node* fixture_tree(Fixture* fixture) @private {
    Node* root = fixture.source.add_node(name: "root")!!;
    Node* child = fixture.source.add_node(root, "child")!!;
    fixture.source.add(root, (Number){ .count = 21, .gain = -0.0f, .target = child.id });
    Item[2] items = { { .label = "first", .amount = short::min }, { .label = "second", .amount = short::max } };
    Owner owner = {
        .items = items[..],
        .total = ulong::max,
        .precision = bitcast(0x7ff0000000000001UL, double),
        .cells = { 0, 2147483648U, uint::max },
        .basis = matrix::IDENTITY4,
    };
    owner.basis.m01 = 0.375f;
    owner.basis.m22 = -2;
    ReadContext context = { .scene = &fixture.source, .node = child };
    attach_owner(&owner, &context)!!;
    return root;
}

fn char[] fixture_bytes(Fixture* fixture, Node* root) @private {
    return serial::write_subtree(
        allocator: tmem,
        scene: &fixture.source,
        assets: &fixture.assets,
        root: root,
    )!!;
}

fn void test_described_layout_fingerprint() @test {
    initialize_descriptions();
    assert(serial::description_layout(describe::get(Number)!!)!! == NUMBER_LAYOUT);
    assert(serial::description_layout(describe::get(Item)!!)!! == ITEM_LAYOUT);
    assert(serial::description_layout(describe::get(Owner)!!)!! == OWNER_LAYOUT);
    if (catch excuse = serial::register_described_type(
        $Type: Number,
        version: 2,
        layout: NUMBER_LAYOUT ^ 1,
        defaults: &defaults_number,
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    if (catch excuse = serial::register_described_type(
        $Type: Number,
        version: 2,
        layout: NUMBER_LAYOUT,
        defaults: null,
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
}
