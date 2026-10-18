module c3d::serial;

import c3d;
import c3d::describe;
import c3d::ecs;
import c3d::serial::described_component @public;

<*
 Borrow an owner's authored fields without changing live state.
 @param [&in] component : "Live owner of the registered component type."
 @param [&out] value : "Receives the described authoring value and borrowed arrays."
 @param [&inout] context : "Resolves source nodes and assets."
 @return "Success or the owner's unchanged fault."
*>
alias ProjectFn = fn void? (void* component, void* value, WriteContext* context);

<*
 Attach copied authoring without preparing runtime resources.
 @param [&in] value : "Borrowed until return; retained data must be copied."
 @param [&inout] context : "Destination node and normal owner removal hooks."
 @return "Success or the owner's unchanged fault; failure attaches nothing."
*>
alias AttachFn = fn void? (void* value, ReadContext* context);

<*
 Validate decoded dependencies before component attachment.
 @param [&in] value : "Fully decoded authoring, including resolved node references."
 @param [&in] context : "Scene and assets remain unchanged."
 @return "Success or the owner's unchanged fault."
*>
alias ValidateFn = fn void? (void* value, ReadContext* context);

<*
 Upgrade a decoded older authoring shape into the current one.
 @param [&in] older : "Decoded older shape; arrays borrow the read context."
 @param [&out] current : "Starts at the current shape's defaults."
 @param [&inout] context : "Resolves assets and node references."
 @return "Success or the fault of an invalid older value."
*>
alias UpgradeFn = fn void? (void* older, void* current, ReadContext* context);

<*
 One older component payload version, read by a reader or upgraded from its shape.
 An upgrade names a registered older shape; authored borrows and attachment then see the current shape.
*>
struct BinaryCompatibility {
    uint version;
    ReadFn read;
    typeid older;
    UpgradeFn upgrade;
}

<* Portable identity and attachment of a described component. *>
struct DescribedCodec {
    String name;
    RestorePhase phase;
    CollectFn collect;
    ProjectFn project;
    ValidateFn validate;
    AttachFn attach;
    BinaryCompatibility[] binary_compatibility;
    uint[] text_default_versions;
}

struct DescribedBinding @private {
    DescribedType* type;
    DescribedCodec codec;
}

<*
 Bind a described component to binary, text and schema encoding.
 @param codec : "Strings and arrays have immutable process lifetime."
 @return? c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, describe::MISSING_DESCRIPTION
*>
macro void? register_described($Type, DescribedCodec codec) {
    DescribedType* type = described_type($Type)!;
    if (!codec.project) codec.project = &described_component::project{$Type};
    if (!codec.attach) {
        if (description_is_dynamic(type.descriptor)!) return c3d::INVALID_ARGUMENT~;
        codec.attach = &described_component::attach{$Type};
    }
    register_described_binding(
        binding: &described_component::binding{$Type},
        type: type,
        codec: codec,
        slot: ecs::slot_of($Type)!,
    )!;
}

<*
 Bind an owner through a separate described authoring type.
 @param codec : "Projection and copying attachment are required."
 @return? c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
macro void? register_described_owner($Component, $Authoring, DescribedCodec codec) {
    DescribedType* type = described_type($Authoring)!;
    if (!codec.project || !codec.attach) return c3d::INVALID_ARGUMENT~;
    register_described_binding(
        binding: &described_component::binding{$Component},
        type: type,
        codec: codec,
        slot: ecs::slot_of($Component)!,
    )!;
}

fn void? register_described_binding(
    DescribedBinding* binding,
    DescribedType* type,
    DescribedCodec codec,
    uint slot,
) @private {
    if (!codec.name.len || !valid_utf8(codec.name)) return c3d::INVALID_ARGUMENT~;
    foreach (index, &entry : codecs) {
        if (entry.codec.name == codec.name && index != slot) return c3d::INVALID_ARGUMENT~;
    }
    foreach (index, compatibility : codec.binary_compatibility) {
        bool upgrades = (bool)compatibility.older && compatibility.upgrade;
        bool partial = (bool)compatibility.older != (compatibility.upgrade != null);
        if (!compatibility.version || compatibility.version >= type.version || partial) {
            return c3d::INVALID_ARGUMENT~;
        }
        if (compatibility.read ? upgrades : !upgrades) return c3d::INVALID_ARGUMENT~;
        foreach (previous : codec.binary_compatibility[:index]) {
            if (previous.version == compatibility.version) return c3d::INVALID_ARGUMENT~;
        }
    }
    foreach (index, version : codec.text_default_versions) {
        if (!version || version >= type.version) return c3d::INVALID_ARGUMENT~;
        foreach (previous : codec.text_default_versions[:index]) {
            if (previous == version) return c3d::INVALID_ARGUMENT~;
        }
    }
    *binding = { .type = type, .codec = codec };
    codecs[slot] = {
        .codec = {
            .name = codec.name,
            .version = type.version,
            .phase = codec.phase,
            .collect = codec.collect,
            .write = &write_described_component,
            .read = &read_described_component,
        },
        .described = binding,
    };
}

fn bool? description_is_dynamic(describe::Descriptor* descriptor) @private {
    LayoutState state;
    state.hash.init();
    describe::Visitor visitor = {
        .mode = SCHEMA,
        .field = &layout_field,
        .begin = &layout_begin,
        .end = &layout_end,
        .user = &state,
    };
    describe::walk_descriptor(descriptor, &visitor, null)!;
    return state.dynamic;
}

fn void? write_described_component(void* component, Writer* writer, WriteContext* context) @local {
    DescribedBinding* binding = codecs[context.slot].described;
    Acquisitions owned = { .allocator = tmem };
    defer owned.release();
    void* value = owned.acquire(1, binding.type.descriptor.size, binding.type.descriptor.alignment)!;
    binding.codec.project(component, value, context)!;
    write_described_value(
        type: binding.type,
        writer: writer,
        context: context,
        value: value,
    )!;
}

fn void? read_described_component(Reader* reader, ReadContext* context) @local {
    DescribedBinding* binding = codecs[context.slot].described;
    if (context.version != binding.type.version) {
        foreach (compatibility : binding.codec.binary_compatibility) {
            if (compatibility.version != context.version) continue;
            if (compatibility.read) return compatibility.read(reader, context);

            void* value = read_component_authoring(
                context:  context,
                entity:   context.node.id,
                slot:     context.slot,
                identity: binding.type.descriptor.identity,
            )!;
            reader.offset = reader.bytes.len;
            if (binding.codec.validate) binding.codec.validate(value, context)!;
            return binding.codec.attach(value, context);
        }
        return c3d::UNSUPPORTED~;
    }
    ReadAuthoring* entry = find_read_authoring(context, context.record, context.slot);
    if (entry && entry.value) {
        reader.offset = reader.bytes.len;
        binding.codec.attach(entry.value, context)!;
        return;
    }
    Acquisitions owned = { .allocator = context.allocator };
    defer owned.release();
    void* value = owned.acquire(1, binding.type.descriptor.size, binding.type.descriptor.alignment)!;
    read_described_value(
        type: binding.type,
        reader: reader,
        context: context,
        owned: &owned,
        value: value,
    )!;
    if (binding.codec.validate) binding.codec.validate(value, context)!;
    binding.codec.attach(value, context)!;
}

fn void? validate_described_payload(DescribedBinding* binding, Reader* reader, ReadContext* context) @private {
    void* value = read_component_authoring(
        context: context,
        entity: context.node.id,
        slot: context.slot,
        identity: binding.type.descriptor.identity,
    )!;
    reader.offset = reader.bytes.len;
    binding.codec.validate(value, context)!;
}

module c3d::serial::described_component <Type> @private;

import c3d::serial @public;

DescribedBinding binding;

fn void? project(void* component, void* value, WriteContext* context) {
    *(Type*)value = *(Type*)component;
}

fn void? attach(void* value, ReadContext* context) {
    context.scene.add(context.node, *(Type*)value);
}
