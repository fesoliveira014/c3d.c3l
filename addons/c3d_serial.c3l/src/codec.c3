module c3d::serial;

import c3d;
import c3d::ecs;
import c3d::scene;

<*
 Select an owner's portable nodes and components.
 @param [&in] component : "Live value of the registered type."
 @param [&inout] context : "Receives temporary ownership claims."
 @return? c3d::INVALID_ARGUMENT, c3d::INVALID_ID, c3d::CAPACITY_EXCEEDED
*>
alias CollectFn = fn void? (void* component, WriteContext* context);

<*
 Encode one component payload.
 @param [&in] component : "Live value of the registered type."
 @param [&inout] writer : "Receives canonical payload bytes."
 @param [&inout] context : "Resolves portable references."
 @return? c3d::INVALID_ARGUMENT, c3d::INVALID_ID, c3d::CAPACITY_EXCEEDED
*>
alias WriteFn = fn void? (void* component, Writer* writer, WriteContext* context);

<*
 Attach authoring to the supplied destination node.
 @param [&inout] reader : "Contains exactly one bounded payload."
 @param [&inout] context : "Supplies ownership and resolved references."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ID, c3d::CAPACITY_EXCEEDED
*>
alias ReadFn = fn void? (Reader* reader, ReadContext* context);

<* Component restoration order. *>
enum RestorePhase {
    VALUE,
    REFERENCES,
    OWNER,
}

<* Stable stream identity and callbacks of a component. *>
struct ComponentCodec {
    String name;
    uint version;
    RestorePhase phase;
    CollectFn collect;
    WriteFn write;
    ReadFn read;
}

struct CodecEntry @private {
    ComponentCodec codec;
    bool transient;
    DescribedBinding* described;
    String diagnostic_name;
}

CodecEntry[ecs::MAX_COMPONENT_TYPES] codecs @private;

<*
 Bind a component to its portable schema.
 @param codec : "Name has static lifetime; registration is single-threaded."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
 @require codec.name.len > 0 && valid_utf8(codec.name) && codec.version > 0
 @require codec.write != null && codec.read != null
*>
macro void? register_codec($Type, ComponentCodec codec) {
    foreach (index, &entry : codecs) {
        if (entry.codec.name != codec.name) continue;
        uint previous = ecs::assigned_slot($Type) ?? c3d::INVALID_ARGUMENT~!;
        if (index != previous) return c3d::INVALID_ARGUMENT~;
    }
    uint slot = ecs::slot_of($Type)!;
    codecs[slot] = { .codec = codec };
}

<*
 Mark runtime component data as intentionally omitted.
 @param collect : "Read-only check; claims nothing and may only reject."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
macro void? register_transient($Type, CollectFn collect = null) {
    uint slot = ecs::slot_of($Type)!;
    if (codecs[slot].transient) {
        if (codecs[slot].codec.collect != collect) return c3d::INVALID_ARGUMENT~;
        return;
    }
    codecs[slot] = { .codec = { .collect = collect }, .transient = true, .diagnostic_name = $Type::qname };
}

<* Whether a component has an explicit serialization policy. *>
macro bool is_serializable($Type) {
    if (try slot = ecs::assigned_slot($Type)) {
        return codecs[slot].transient || codecs[slot].codec.name.len != 0;
    }
    return false;
}

fn uint? codec_slot(String name) @private {
    foreach (index, &entry : codecs) {
        if (entry.codec.name == name) return (uint)index;
    }
    return c3d::UNSUPPORTED~;
}
