module c3d::serial::test;

import c3d;
import c3d::asset;
import c3d::asset::custom;
import c3d::ecs;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::serial;
import std::math;

struct Value @private {
    uint number;
    bool enabled;
    Entity other;
    GeometryId geometry;
    Node* pointer;
}

struct Owned @private {
    uint[] values;
    String label;
}

struct Unknown @private {
    uint value;
}

struct Versioned @private {
    uint first;
    uint second;
}

struct Duplicate @private {
    uint value;
}

struct Composite @private {
    Entity child;
}

struct Wave @private {
    float amplitude;
}

struct OtherAsset @private {
    float amplitude;
}

struct CustomValue @private {
    CustomId{Wave} wave;
}

struct Fixture @private {
    AssetStore assets;
    Scene source;
    Scene destination;
    uint removed;
}

fn void init_fixture(Fixture* fixture, uint capacity = 32) @private {
    fixture.assets = asset::create_asset_store(mem, {
        .max_geometries = 8,
        .max_textures = 8,
        .max_materials = 8,
        .max_samplers = 8,
        .max_models = 2,
        .max_skeletons = 2,
        .max_clips = 2,
        .max_environments = 1,
        .max_shaders = 1,
        .max_compute_shaders = 1,
    });
    fixture.source = scene::create_scene(mem, { .max_nodes = 32 });
    fixture.destination = scene::create_scene(mem, { .max_nodes = capacity });
    register_scene(&fixture.source, &fixture.removed);
    register_scene(&fixture.destination, &fixture.removed);
    register_codecs();
}

fn void free_fixture(Fixture* fixture) @private {
    scene::destroy_scene(&fixture.destination);
    scene::destroy_scene(&fixture.source);
    asset::destroy_asset_store(&fixture.assets);
}

fn void register_scene(Scene* scene, uint* removed) @private {
    scene.register(Value)!!;
    scene.register(Owned)!!;
    scene.register(Unknown)!!;
    scene.register(Versioned)!!;
    scene.register(Duplicate)!!;
    scene.register(Composite)!!;
    scene.register(CustomValue)!!;
    scene.set_remove_hook(Owned, &free_owned, removed);
}

fn void register_codecs() @private {
    serial::register_codec(Value, {
        .name = "value",
        .version = 1,
        .phase = RestorePhase.REFERENCES,
        .write = &write_value,
        .read = &read_value,
    })!!;
    serial::register_codec(Owned, {
        .name = "owned",
        .version = 1,
        .write = &write_owned,
        .read = &read_owned,
    })!!;
    serial::register_codec(Versioned, {
        .name = "versioned",
        .version = 2,
        .write = &write_versioned,
        .read = &read_versioned,
    })!!;
    serial::register_codec(Composite, {
        .name = "composite",
        .version = 1,
        .collect = &collect_composite,
        .write = &write_composite,
        .read = &read_composite,
    })!!;
    serial::register_codec(CustomValue, {
        .name = "custom",
        .version = 1,
        .write = &write_custom,
        .read = &read_custom,
    })!!;
}

fn void? write_value(void* component, Writer* writer, WriteContext* context) @private {
    Value* value = component;
    writer.write_uint(value.number);
    writer.write_bool(value.enabled);
    context.write_entity(writer, value.other)!;
    context.write_geometry(writer, value.geometry)!;
    context.write_node(writer, value.pointer)!;
}

fn void? read_value(Reader* reader, ReadContext* context) @private {
    assert(context.has_component(Value));
    Value value;
    value.number = reader.read_uint()!;
    value.enabled = reader.read_bool()!;
    value.other = context.read_entity(reader)!;
    value.geometry = context.read_geometry(reader)!;
    value.pointer = context.read_node(reader)!;
    context.scene.add(context.node, value);
}

fn void? write_owned(void* component, Writer* writer, WriteContext* context) @private {
    Owned* owned = component;
    writer.write_uint((uint)owned.values.len);
    foreach (value : owned.values) writer.write_uint(value);
    writer.write_string(owned.label);
}

fn void? read_owned(Reader* reader, ReadContext* context) @private {
    uint count = reader.read_uint()!;
    if (count > reader.remaining() / uint::size) return c3d::ASSET_FORMAT_ERROR~;
    uint[] values = alloc::new_array_try(context.scene.allocator, uint, count) ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch alloc::free(context.scene.allocator, values.ptr);
    foreach (&value : values) *value = reader.read_uint()!;
    String label = reader.read_string()!;
    context.scene.add(context.node, (Owned){ .values = values, .label = label.copy(context.scene.allocator) });
}

fn void free_owned(Entity entity, void* component, void* user) @private {
    Owned* owned = component;
    alloc::free(mem, owned.values.ptr);
    alloc::free(mem, owned.label.ptr);
    (*(uint*)user)++;
}

fn void? write_versioned(void* component, Writer* writer, WriteContext* context) @private {
    Versioned* value = component;
    writer.write_uint(value.first);
    writer.write_uint(value.second);
}

fn void? write_old_version(void* component, Writer* writer, WriteContext* context) @private {
    writer.write_uint(((Versioned*)component).first);
}

fn void? read_versioned(Reader* reader, ReadContext* context) @private {
    Versioned value = { .first = reader.read_uint()!, .second = 7 };
    if (context.version >= 2) value.second = reader.read_uint()!;
    context.scene.add(context.node, value);
}

fn void? collect_composite(void* component, WriteContext* context) @private {
    Composite* owner = component;
    if (!owner.child.generation) return;
    Node* child = context.scene.node(owner.child);
    context.omit_node(child)!;
    context.omit_component(child, ecs::slot_of(Value)!)!;
}

fn void? write_composite(void* component, Writer* writer, WriteContext* context) @private {}

fn void? read_composite(Reader* reader, ReadContext* context) @private {
    context.scene.add(context.node, (Composite){});
}

fn void? write_custom(void* component, Writer* writer, WriteContext* context) @private {
    context.write_custom(writer: writer, $Type: Wave, id: ((CustomValue*)component).wave)!;
}

fn void? read_custom(Reader* reader, ReadContext* context) @private {
    context.scene.add(context.node, (CustomValue){ .wave = context.read_custom(reader, Wave)! });
}

fn GeometryId add_geometry(AssetStore* assets, String key) @private {
    Geometry geometry = geometry::box(
        allocator: tmem,
        width: 1,
        height: 1,
        depth: 1,
    );
    return assets.add_geometry(&geometry, key)!!;
}

fn Node* value_tree(Fixture* fixture) @private {
    Node* root = fixture.source.add_node(name: "root")!!;
    Node* first = fixture.source.add_node(root, "first")!!;
    Node* second = fixture.source.add_node(root, "second")!!;
    Node* leaf = fixture.source.add_node(first, "leaf")!!;
    first.local.position = { 2, 3, 4 };
    first.layers = 9;
    leaf.transform_space = TransformSpace.WORLD;
    leaf.local.position = { 8, 9, 10 };
    second.visible = false;
    fixture.source.add(root, (Value){ .number = 42, .enabled = true, .other = leaf.id, .pointer = leaf });
    uint[3] values = { 3, 5, 8 };
    fixture.source.add(second, (Owned){
        .values = alloc::clone_slice(mem, values[..]),
        .label = "persistent".copy(mem),
    });
    return root;
}

fn uint chunk_offset(char[] bytes, ChunkKind wanted) @private {
    Reader reader = serial::reader_over(bytes);
    reader.offset = 20;
    uint count = reader.read_uint()!!;
    for (uint index = 0; index < count; index++) {
        uint kind = reader.read_uint()!!;
        uint offset = reader.read_uint()!!;
        (void)reader.read_uint()!!;
        if (kind == wanted.ordinal) return offset;
    }
    unreachable("missing fixture chunk");
}

fn void patch_uint(char[] bytes, usz offset, uint value) @private {
    Writer writer = serial::writer_over(bytes[offset..]);
    writer.write_uint(value);
}

fn uint value_payload_offset(char[] bytes, uint type_index = 1) @private {
    Reader reader = serial::reader_over(bytes);
    reader.offset = chunk_offset(bytes, ChunkKind.COMPONENTS);
    uint groups = reader.read_uint()!!;
    for (uint group = 0; group < groups; group++) {
        uint type = reader.read_uint()!!;
        uint count = reader.read_uint()!!;
        for (uint entry = 0; entry < count; entry++) {
            (void)reader.read_uint()!!;
            uint size = reader.read_uint()!!;
            if (type == type_index) return (uint)reader.offset;
            (void)reader.read_bytes(size)!!;
        }
    }
    unreachable("missing fixture payload");
}
