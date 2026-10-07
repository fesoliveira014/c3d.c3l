module c3d::serial;

import c3d;
import c3d::describe;
import c3d::serial::described_type @public;
import std::hash::fnv64a;

<*
 Initialize semantic defaults without acquiring storage.
 @param [&out] value : "Strings and slices borrow immutable process-lifetime storage."
*>
alias DefaultsFn = fn void (void* value);

<* Versioned field layout and its single default source. *>
struct DescribedType {
    describe::Descriptor* descriptor;
    uint version;
    ulong layout;
    DefaultsFn defaults;
}

struct DescribedTypeEntry @private {
    DescribedType type;
    DescribedTypeEntry* next;
}

struct LayoutState @private {
    Fnv64a hash;
    bool dynamic;
}

DescribedTypeEntry* described_types @private;

<*
 Pin a serialized type's layout and semantic default source.
 @param layout : "Committed fingerprint for this version."
 @param defaults : "Explicit semantic defaults, including an explicitly empty value."
 @return? describe::MISSING_DESCRIPTION, c3d::INVALID_ARGUMENT
 @require version > 0
*>
macro void? register_described_type(
    $Type,
    uint version,
    ulong layout,
    DefaultsFn defaults,
) {
    describe::Descriptor* descriptor = describe::get($Type)!;
    if (!defaults || description_layout(descriptor)! != layout) return c3d::INVALID_ARGUMENT~;
    DescribedTypeEntry* entry = &described_type::entry{$Type};
    if (entry.type.descriptor) {
        if (entry.type.version != version || entry.type.layout != layout || entry.type.defaults != defaults) {
            return c3d::INVALID_ARGUMENT~;
        }
        return;
    }
    entry.type = {
        .descriptor = descriptor,
        .version = version,
        .layout = layout,
        .defaults = defaults,
    };
    DescribedTypeEntry** position = &described_types;
    while (*position && (*position).type.descriptor.name.compare_to(descriptor.name) < 0) {
        position = &(*position).next;
    }
    entry.next = *position;
    *position = entry;
}

<*
 Borrow a type's registered serialization policy.
 @return? c3d::UNSUPPORTED
*>
macro DescribedType*? described_type($Type) {
    DescribedType* type = &described_type::entry{$Type}.type;
    if (!type.descriptor) return c3d::UNSUPPORTED~;
    return type;
}

<*
 Calculate a deterministic fingerprint of a described field layout.
 @param [&in] descriptor : "Complete description, including every nested type."
 @return? describe::MISSING_DESCRIPTION
*>
fn ulong? description_layout(describe::Descriptor* descriptor) {
    LayoutState state;
    state.hash.init();
    describe::Visitor visitor = {
        .mode = SCHEMA,
        .field = &layout_field,
        .begin = &layout_begin,
        .end = &layout_end,
        .user = &state,
    };
    describe::walk_descriptor(
        descriptor: descriptor,
        visitor: &visitor,
        value: null,
        name: "value",
    )!;
    return (ulong)state.hash;
}

fn DescribedType*? find_described_type(typeid identity) @private {
    for (DescribedTypeEntry* entry = described_types; entry; entry = entry.next) {
        if (entry.type.descriptor.identity == identity) return &entry.type;
    }
    return c3d::UNSUPPORTED~;
}

fn void layout_integer(LayoutState* state, ulong value) @local {
    for (uint index = 0; index < ulong::size; index++) state.hash.update_byte((char)(value >> (index * 8)));
}

fn void layout_string(LayoutState* state, String value) @local {
    layout_integer(state, value.len);
    state.hash.update((char[])value);
}

fn void layout_info(LayoutState* state, describe::Info* info) @local {
    layout_string(state, info.name);
    layout_string(state, describe::Kind::names[info.kind.ordinal]);
    layout_integer(state, info.size);
    layout_integer(state, info.extent);
    if (info.kind == ARRAY || info.kind == SLICE) {
        layout_string(state, describe::Kind::names[info.element_kind.ordinal]);
        layout_integer(state, info.element_size);
    }
    if (info.kind == ASSET) layout_string(state, AssetKind::names[info.metadata.asset_kind.ordinal]);
    if (info.kind == ENUM) {
        layout_integer(state, info.enum_names.len);
        foreach (name : info.enum_names) layout_string(state, name);
    }
    if (info.kind == STRING || info.kind == SLICE) state.dynamic = true;
}

fn bool? layout_field(describe::Visitor* visitor, describe::Info* info, void* value) @private {
    LayoutState* state = visitor.user;
    state.hash.update_byte(0);
    layout_info(state, info);
    return false;
}

fn bool? layout_begin(describe::Visitor* visitor, describe::Info* info, void* value) @private {
    LayoutState* state = visitor.user;
    state.hash.update_byte(1);
    layout_info(state, info);
    return true;
}

fn void? layout_end(describe::Visitor* visitor, describe::Info* info, void* value) @private {
    LayoutState* state = visitor.user;
    state.hash.update_byte(2);
}

module c3d::serial::described_type <Type> @private;

import c3d::serial @public;

DescribedTypeEntry entry;
