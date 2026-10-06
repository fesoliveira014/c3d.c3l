module c3d::serial;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::scene;
import std::collections::list;
import std::collections::map;

<*
 Encode an authored subtree into an owned buffer.
 @param [&in] scene : "Owns root; structure remains unchanged."
 @param [&in] assets : "Resolves stable asset keys."
 @param [&in] root : "Live subtree root."
 @return "Buffer owned by allocator."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require scene.world.is_alive(root.id)
*>
fn char[]? write_subtree(
    Allocator allocator,
    Scene* scene,
    AssetStore* assets,
    Node* root,
) {
    WriteState state = prepare_export(scene, assets, root)!;
    WriteContext context = { .scene = scene, .assets = assets, .state = &state };
    Writer node_measure = measuring_writer();
    write_nodes(&context, &node_measure)!;
    node_measure.finish()!;
    Writer component_measure = measuring_writer();
    write_components(&context, &component_measure)!;
    component_measure.finish()!;
    Writer key_measure = measuring_writer();
    write_keys(&state, &key_measure);
    key_measure.finish()!;
    Writer type_measure = measuring_writer();
    write_types(&state, &type_measure);
    type_measure.finish()!;

    usz offset = HEADER_BYTES + REQUIRED_CHUNKS * CHUNK_ENTRY_BYTES;
    usz[REQUIRED_CHUNKS] sizes = {
        key_measure.written(), type_measure.written(), node_measure.written(), component_measure.written(),
    };
    ChunkEntry[REQUIRED_CHUNKS] chunks;
    foreach (index, size : sizes) {
        if (size > uint::max - offset) return c3d::CAPACITY_EXCEEDED~;
        chunks[index] = { .kind = (uint)index, .offset = (uint)offset, .size = (uint)size };
        offset += size;
    }
    char[] bytes = alloc::new_array_try(allocator, char, (sz)offset) ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch alloc::free(allocator, bytes.ptr);
    Writer output = writer_over(bytes);
    write_header(&output, {
        .magic = SUBTREE_MAGIC,
        .version = SUBTREE_VERSION,
        .byte_count = (uint)bytes.len,
        .node_count = state.count,
        .key_count = (uint)state.keys.len(),
        .chunk_count = REQUIRED_CHUNKS,
    });
    foreach (chunk : chunks) write_chunk(&output, chunk);
    state.filling = true;
    write_keys(&state, &output);
    write_types(&state, &output);
    write_nodes(&context, &output)!;
    write_components(&context, &output)!;
    output.finish()!;
    return bytes;
}

fn WriteState? prepare_export(Scene* scene, AssetStore* assets, Node* root) @local {
    if (root.id.index >= scene.nodes.len || &scene.nodes[root.id.index] != root) return c3d::INVALID_ARGUMENT~;
    WriteState state;
    state.projection = alloc::new_array_try(tmem, NodeProjection, scene.nodes.len) ?? c3d::CAPACITY_EXCEEDED~!;
    state.ordered = alloc::new_array_try(tmem, Node*, scene.nodes.len) ?? c3d::CAPACITY_EXCEEDED~!;
    Node*[] stack = alloc::new_array_try(tmem, Node*, scene.nodes.len) ?? c3d::CAPACITY_EXCEEDED~!;
    state.keys.tinit();
    state.key_index.tinit();
    state.claims.tinit();
    state.payload_sizes.tinit();
    uint pending = 1;
    stack[0] = root;
    while (pending) {
        Node* node = stack[--pending];
        state.projection[node.id.index] = { .selected = true, .local = node.local, .record = INDEX_NONE };
        state.ordered[state.count++] = node;
        for (Node* child = node.first_child; child; child = child.next_sibling) stack[pending++] = child;
    }

    state.collecting = true;
    WriteContext context = { .scene = scene, .assets = assets, .state = &state };
    foreach (node : state.ordered[:state.count]) {
        context.node = node;
        scene.world.@each_slot(node.id; uint slot) {
            if (codecs[slot].codec.collect) {
                context.slot = slot;
                codecs[slot].codec.collect(scene.world.component(node.id, slot), &context)!;
            }
        };
    }
    state.collecting = false;
    if (state.projection[root.id.index].node_owner) return c3d::INVALID_ARGUMENT~;
    ComponentMask transient_mask;
    foreach (slot, entry : codecs) if (entry.transient) transient_mask |= ecs::slot_bit((uint)slot);
    ComponentMask used;
    uint retained;
    foreach (node : state.ordered[:state.count]) {
        NodeProjection* projected = &state.projection[node.id.index];
        ComponentMask mask = scene.world.mask(node.id);
        if (projected.node_owner) {
            if (mask & ~(projected.omitted_components | transient_mask)) return c3d::INVALID_ARGUMENT~;
            continue;
        }
        if (node != root && state.projection[node.parent.id.index].node_owner) return c3d::INVALID_ARGUMENT~;
        if (scene.has(node, ModelInstance)) return c3d::UNSUPPORTED~;
        mask &= ~(projected.omitted_components | transient_mask);
        scene.world.@each_slot(node.id; uint slot) {
            if ((mask & ecs::slot_bit(slot)) && !codecs[slot].codec.name.len) return c3d::UNSUPPORTED~;
        };
        used |= mask;
        projected.record = retained;
        state.ordered[retained++] = node;
    }
    state.count = retained;
    for (uint slot = 0; slot < ecs::MAX_COMPONENT_TYPES; slot++) {
        if (!(used & ecs::slot_bit(slot))) continue;
        uint position = state.type_count++;
        while (position && codecs[state.slots[position - 1]].codec.name.compare_to(codecs[slot].codec.name) > 0) {
            state.slots[position] = state.slots[position - 1];
            position--;
        }
        state.slots[position] = slot;
    }
    return state;
}

fn void? write_nodes(WriteContext* context, Writer* writer) @local {
    WriteState* state = context.state;
    foreach (index, node : state.ordered[:state.count]) {
        if (!valid_utf8(node.name)) return c3d::INVALID_ARGUMENT~;
        writer.write_uint(index ? state.projection[node.parent.id.index].record : INDEX_NONE);
        writer.write_uint(INDEX_NONE);
        writer.write_uint(INDEX_NONE);
        writer.write_uint(INDEX_NONE);
        writer.write_uint(0);
        writer.write_string(node.name);
        writer.write_transform(state.projection[node.id.index].local);
        writer.write_enum(node.transform_space);
        writer.write_uint(node.layers);
        writer.write_bool(node.visible);
    }
}

fn void? write_components(WriteContext* context, Writer* writer) @local {
    WriteState* state = context.state;
    writer.write_uint(state.type_count);
    uint payload_index;
    foreach (type_index, slot : state.slots[:state.type_count]) {
        ComponentMask bit = ecs::slot_bit(slot);
        uint count;
        foreach (node : state.ordered[:state.count]) {
            if ((context.scene.world.mask(node.id) & bit)
                && !(state.projection[node.id.index].omitted_components & bit)) {
                count++;
            }
        }
        writer.write_uint((uint)type_index);
        writer.write_uint(count);
        foreach (record, node : state.ordered[:state.count]) {
            if (!(context.scene.world.mask(node.id) & bit)
                || (state.projection[node.id.index].omitted_components & bit)) continue;
            writer.write_uint((uint)record);
            uint expected = state.filling ? state.payload_sizes[payload_index] : 0;
            writer.write_uint(expected);
            usz before = writer.written();
            context.node = node;
            context.slot = slot;
            codecs[slot].codec.write(context.scene.world.component(node.id, slot), writer, context)!;
            writer.finish()!;
            uint size = (uint)(writer.written() - before);
            if (state.filling) {
                if (size != expected) return c3d::INVALID_ARGUMENT~;
            } else {
                state.payload_sizes.push(size);
            }
            payload_index++;
        }
    }
}

fn void write_keys(WriteState* state, Writer* writer) @local {
    foreach (key : state.keys.array_view()) writer.write_string(key);
}

fn void write_types(WriteState* state, Writer* writer) @local {
    writer.write_uint(state.type_count);
    foreach (slot : state.slots[:state.type_count]) {
        writer.write_string(codecs[slot].codec.name);
        writer.write_uint(codecs[slot].codec.version);
    }
}
