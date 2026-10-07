module c3d::serial;

import c3d;
import c3d::ecs;
import std::sort;

struct ReadAuthoring @private {
    uint record;
    uint slot;
    uint version;
    char[] bytes;
    void* value;
}

struct ReadNodeRecord @private {
    uint node_index;
    uint record;
}

struct ReadAuthoringIndex @private {
    ReadNodeRecord[] node_records;
    uint[] first_entries;
    uint[] next_entries;
}

<*
 Borrow another component's decoded authoring before attachment.
 @param node : "Node from this document's resolved references."
 @return "Read-only borrow, or null for an absent component."
 @return? c3d::INVALID_ID, c3d::UNSUPPORTED, c3d::ASSET_FORMAT_ERROR, c3d::CAPACITY_EXCEEDED
 @require self.read_owned != null
*>
macro ReadContext.authored(
    &self,
    $Component,
    $Authoring,
    Entity node,
) {
    uint slot = ecs::assigned_slot($Component) ?? ecs::MAX_COMPONENT_TYPES;
    void* value = read_component_authoring(self, node, slot, $Authoring::typeid)!;
    return ($Authoring*)value;
}

fn void*? read_component_authoring(
    ReadContext* context,
    Entity entity,
    uint slot,
    typeid identity,
) @private {
    uint record = read_node_record(context, entity)!;
    ReadAuthoring* entry = find_read_authoring(context, record, slot);
    if (entry) {
        DescribedBinding* binding = codecs[slot].described;
        if (!binding || binding.type.descriptor.identity != identity) return c3d::UNSUPPORTED~;
        if (entry.value) return entry.value;
        if (entry.version != binding.type.version) return c3d::UNSUPPORTED~;
        ReadContext previous = *context;
        defer *context = previous;
        context.node = context.nodes[entry.record];
        context.record = entry.record;
        context.slot = slot;
        context.version = entry.version;
        void* value = context.read_owned.acquire(1, binding.type.descriptor.size, binding.type.descriptor.alignment)!;
        Reader reader = reader_over(entry.bytes);
        if (catch excuse = read_described_value(
            type: binding.type,
            reader: &reader,
            context: context,
            owned: context.read_owned,
            value: value,
        )) return component_diagnostic(
            diagnostic: context.diagnostic,
            record: entry.record,
            type_name: binding.codec.name,
            cause: excuse,
        )~;
        entry.value = value;
        return value;
    }
    return (void*)null;
}

fn void? initialize_binary_authoring(
    ReadContext* context,
    ReadAuthoring[] entries,
    PayloadView[] payloads,
    TypeRecord[] types,
    Acquisitions* owned,
) @private {
    context.authoring = entries;
    context.read_owned = owned;
    foreach (index, payload : payloads) {
        TypeRecord type = types[payload.type];
        entries[index] = {
            .record = payload.record, .slot = type.slot, .version = type.version, .bytes = payload.bytes,
        };
    }
    index_read_authoring(context)!;
}

fn ReadAuthoring* find_read_authoring(ReadContext* context, uint record, uint slot) @private {
    if (!context.authoring.len) return null;
    ReadAuthoringIndex* index = &context.authoring_index;
    for (uint current = index.first_entries[record]; current; current = index.next_entries[current - 1]) {
        ReadAuthoring* entry = &context.authoring[current - 1];
        if (entry.slot == slot) return entry;
    }
    return null;
}

fn uint? read_node_record(ReadContext* context, Entity entity) @private {
    if (!context.scene.world.is_alive(entity)) return c3d::INVALID_ID~;
    ReadNodeRecord[] records = context.authoring_index.node_records;
    usz first;
    usz last = (usz)records.len;
    while (first < last) {
        usz middle = first + (last - first) / 2;
        ReadNodeRecord pair = records[middle];
        if (pair.node_index == entity.index) return pair.record;
        if (pair.node_index < entity.index) {
            first = middle + 1;
        } else {
            last = middle;
        }
    }
    return c3d::INVALID_ID~;
}

fn void? index_read_authoring(ReadContext* context) @private {
    usz node_count = (usz)context.nodes.len;
    usz entry_count = (usz)context.authoring.len;
    usz pair_words = node_count * (ReadNodeRecord::size / uint::size);
    uint* storage = context.read_owned.acquire(pair_words + node_count + entry_count, uint::size, ReadNodeRecord::alignment)!;
    ReadAuthoringIndex* index = &context.authoring_index;
    index.node_records = ((ReadNodeRecord*)storage)[:node_count];
    index.first_entries = (storage + pair_words)[:node_count];
    index.next_entries = (storage + pair_words + node_count)[:entry_count];
    foreach (record, node : context.nodes) {
        index.node_records[record] = { .node_index = node.id.index, .record = (uint)record };
    }
    sort::countingsort(index.node_records, &read_node_sort_key);
    foreach (position, entry : context.authoring) {
        index.next_entries[position] = index.first_entries[entry.record];
        index.first_entries[entry.record] = (uint)position + 1;
    }
}

fn uint read_node_sort_key(ReadNodeRecord pair) @local {
    return pair.node_index;
}
