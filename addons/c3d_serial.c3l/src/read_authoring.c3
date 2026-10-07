module c3d::serial;

import c3d;
import c3d::ecs;

struct ReadAuthoring @private {
    uint record;
    uint slot;
    uint version;
    char[] bytes;
    void* value;
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
    if (!context.scene.world.is_alive(entity)) return c3d::INVALID_ID~;
    bool present;
    foreach (node : context.nodes) present |= c3d::same_id(node.id, entity);
    if (!present) return c3d::INVALID_ID~;
    foreach (&entry : context.authoring) {
        if (entry.slot != slot || !c3d::same_id(context.nodes[entry.record].id, entity)) continue;
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
        )) return component_diagnostic(context.diagnostic, entry.record, binding.codec.name, excuse)~;
        entry.value = value;
        return value;
    }
    return (void*)null;
}

fn void initialize_binary_authoring(
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
}
