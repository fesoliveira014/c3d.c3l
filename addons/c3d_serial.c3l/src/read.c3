module c3d::serial;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::scene;
import std::collections::list;
import std::collections::map;

<*
 Restore a portable subtree under the supplied parent.
 @param [&inout] scene : "Owns copied nodes and components."
 @param [&in] assets : "Contains every referenced key; unchanged."
 @param [in] parent : "Live parent with current world matrices; null selects root."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ID, c3d::CAPACITY_EXCEEDED
 @require parent == null || scene.world.is_alive(parent.id)
 @require parent == null || &scene.nodes[parent.id.index] == parent
*>
fn Node*? read_subtree(
    Scene* scene,
    AssetStore* assets,
    char[] bytes,
    Node* parent = null,
    ReadOptions options = READ_OPTIONS_DEFAULT,
) {
    if (options.diagnostic) clear_serial_diagnostic(options.diagnostic);
    Node*? restored = read_subtree_binary(
        scene: scene,
        assets: assets,
        bytes: bytes,
        parent: parent,
        options: options,
    );
    if (catch excuse = restored) {
        if (options.diagnostic && !options.diagnostic.cause) options.diagnostic.cause = excuse;
        return excuse~;
    }
    return restored;
}

fn Node*? read_subtree_binary(
    Scene* scene,
    AssetStore* assets,
    char[] bytes,
    Node* parent,
    ReadOptions options,
) @local {
    SubtreeHeader header = read_header(bytes)!;
    Reader key_reader = reader_over(chunk_bytes(bytes, header.chunk_count, ChunkKind.KEYS));
    String[] keys = read_keys(assets, &key_reader, header.key_count)!;
    Reader type_reader = reader_over(chunk_bytes(bytes, header.chunk_count, ChunkKind.TYPES));
    TypeRecord[] types = read_types(scene, &type_reader)!;
    Reader node_reader = reader_over(chunk_bytes(bytes, header.chunk_count, ChunkKind.NODES));
    if (header.node_count > node_reader.remaining() / NODE_MIN_BYTES) return c3d::ASSET_FORMAT_ERROR~;
    if (header.node_count > scene.world.entities.free_count) return c3d::CAPACITY_EXCEEDED~;
    NodeRecord[] records = read_nodes(&node_reader, header.node_count)!;
    ComponentMask[] masks = alloc::new_array_try(tmem, ComponentMask, header.node_count) ?? c3d::CAPACITY_EXCEEDED~!;
    Reader component_reader = reader_over(chunk_bytes(bytes, header.chunk_count, ChunkKind.COMPONENTS));
    List{PayloadView} payloads = read_payloads(&component_reader, types, masks)!;
    Node*[] nodes = alloc::new_array_try(tmem, Node*, header.node_count) ?? c3d::CAPACITY_EXCEEDED~!;
    if (!parent) parent = scene.root;
    Node* root = scene.add_node(parent, records[0].name)!;
    defer catch scene.remove(root);
    nodes[0] = root;
    foreach (index, record : records) {
        Node* node = index ? scene.add_node(nodes[record.parent], record.name)! : root;
        nodes[index] = node;
        node.local = record.local;
        node.transform_space = record.transform_space;
        node.layers = record.layers;
        node.visible = record.visible;
        node.world = node.transform_space == TransformSpace.WORLD
          ? node.local.to_mat4() : node.parent.world.mul(node.local.to_mat4());
        node.visible_effective = node.visible && node.parent.visible_effective;
    }

    ReadContext context = {
        .scene = scene,
        .assets = assets,
        .allocator = options.allocator.ptr ? options.allocator : scene.allocator,
        .diagnostic = options.diagnostic,
        .nodes = nodes,
        .keys = keys,
        .component_masks = masks,
    };
    Acquisitions authoring_owned = { .allocator = context.allocator };
    defer authoring_owned.release();
    ReadAuthoring* authoring_storage = authoring_owned.acquire(
        count: (usz)payloads.len(),
        element_size: ReadAuthoring::size,
        alignment: ReadAuthoring::alignment,
    )!;
    initialize_binary_authoring(
        context: &context,
        entries: authoring_storage[:payloads.len()],
        payloads: payloads.array_view(),
        types: types,
        owned: &authoring_owned,
    )!;
    foreach (payload : payloads.array_view()) {
        TypeRecord type = types[payload.type];
        DescribedBinding* binding = codecs[type.slot].described;
        if (!binding || !binding.codec.validate || type.version != binding.type.version) continue;
        context.node = nodes[payload.record];
        context.record = payload.record;
        context.version = type.version;
        context.slot = type.slot;
        Reader bounded = reader_over(payload.bytes);
        if (catch excuse = validate_described_payload(binding, &bounded, &context)) {
            return component_diagnostic(
                diagnostic: context.diagnostic,
                record: payload.record,
                type_name: codecs[type.slot].codec.name,
                cause: excuse,
            )~;
        }
    }
    foreach (key : keys) {
        if (catch assets.find(key)) return asset_diagnostic(context.diagnostic, key, c3d::INVALID_ID)~;
    }
    foreach (phase : RestorePhase::values) {
        foreach (payload : payloads.array_view()) {
            TypeRecord type = types[payload.type];
            ComponentCodec codec = codecs[type.slot].codec;
            if (codec.phase != phase) continue;
            context.node = nodes[payload.record];
            context.record = payload.record;
            context.version = type.version;
            context.slot = type.slot;
            Reader bounded = reader_over(payload.bytes);
            if (catch excuse = codec.read(&bounded, &context)) {
                return component_diagnostic(
                    diagnostic: context.diagnostic,
                    record: payload.record,
                    type_name: codec.name,
                    cause: excuse,
                )~;
            }
            if (bounded.remaining()) return component_diagnostic(
                diagnostic: context.diagnostic,
                record: payload.record,
                type_name: codec.name,
                cause: c3d::ASSET_FORMAT_ERROR,
            )~;
        }
    }
    return root;
}

fn String[]? read_keys(AssetStore* assets, Reader* reader, uint count) @local {
    if (count > reader.remaining() / uint::size) return c3d::ASSET_FORMAT_ERROR~;
    String[] keys = alloc::new_array_try(tmem, String, count) ?? c3d::CAPACITY_EXCEEDED~!;
    HashMap{String, bool} found;
    found.tinit();
    foreach (&key : keys) {
        *key = reader.read_string()!;
        if (!key.len || found.has_key(*key)) return c3d::ASSET_FORMAT_ERROR~;
        found.set(*key, true);
    }
    if (reader.remaining()) return c3d::ASSET_FORMAT_ERROR~;
    return keys;
}

fn TypeRecord[]? read_types(Scene* scene, Reader* reader) @local {
    uint count = reader.read_uint()!;
    if (count > ecs::MAX_COMPONENT_TYPES || count > reader.remaining() / (2 * uint::size)) {
        return c3d::ASSET_FORMAT_ERROR~;
    }
    TypeRecord[] types = alloc::new_array_try(tmem, TypeRecord, count) ?? c3d::CAPACITY_EXCEEDED~!;
    ComponentMask found;
    foreach (&type : types) {
        String name = reader.read_string()!;
        if (!name.len) return c3d::ASSET_FORMAT_ERROR~;
        uint version = reader.read_uint()!;
        if (!version) return c3d::ASSET_FORMAT_ERROR~;
        uint slot = codec_slot(name)!;
        if (found & ecs::slot_bit(slot)) return c3d::ASSET_FORMAT_ERROR~;
        found |= ecs::slot_bit(slot);
        if (version > codecs[slot].codec.version || !scene.world.stores[slot]) return c3d::UNSUPPORTED~;
        *type = { .slot = slot, .version = version };
    }
    if (reader.remaining()) return c3d::ASSET_FORMAT_ERROR~;
    return types;
}

fn NodeRecord[]? read_nodes(Reader* reader, uint count) @local {
    NodeRecord[] records = alloc::new_array_try(tmem, NodeRecord, count) ?? c3d::CAPACITY_EXCEEDED~!;
    foreach (index, &record : records) {
        record.parent = reader.read_uint()!;
        uint owner = reader.read_uint()!;
        uint template = reader.read_uint()!;
        uint model = reader.read_uint()!;
        uint signature_size = reader.read_uint()!;
        (void)reader.read_bytes(signature_size)!;
        if (owner != INDEX_NONE || template != INDEX_NONE || model != INDEX_NONE) return c3d::UNSUPPORTED~;
        if (signature_size) return c3d::ASSET_FORMAT_ERROR~;
        if ((!index && record.parent != INDEX_NONE) || (index && record.parent >= index)) {
            return c3d::ASSET_FORMAT_ERROR~;
        }
        record.name = reader.read_string()!;
        record.local = reader.read_transform()!;
        record.transform_space = reader.read_enum(TransformSpace)!;
        record.layers = reader.read_uint()!;
        record.visible = reader.read_bool()!;
    }
    if (reader.remaining()) return c3d::ASSET_FORMAT_ERROR~;
    return records;
}

fn List{PayloadView}? read_payloads(Reader* reader, TypeRecord[] types, ComponentMask[] masks) @local {
    uint groups = reader.read_uint()!;
    if (groups != types.len) return c3d::ASSET_FORMAT_ERROR~;
    ComponentMask found;
    List{PayloadView} payloads;
    payloads.tinit();
    for (uint group = 0; group < groups; group++) {
        uint type = reader.read_uint()!;
        uint count = reader.read_uint()!;
        if (type >= types.len || !count || count > masks.len || count > reader.remaining() / (2 * uint::size)) {
            return c3d::ASSET_FORMAT_ERROR~;
        }
        if (found & ((ComponentMask)1 << type)) return c3d::ASSET_FORMAT_ERROR~;
        found |= (ComponentMask)1 << type;
        ComponentMask bit = ecs::slot_bit(types[type].slot);
        for (uint entry = 0; entry < count; entry++) {
            uint record = reader.read_uint()!;
            uint size = reader.read_uint()!;
            if (record >= masks.len || (masks[record] & bit)) return c3d::ASSET_FORMAT_ERROR~;
            masks[record] |= bit;
            char[] bytes = reader.read_bytes(size)!;
            payloads.push({ .record = record, .type = type, .bytes = bytes });
        }
    }
    if (reader.remaining()) return c3d::ASSET_FORMAT_ERROR~;
    return payloads;
}
