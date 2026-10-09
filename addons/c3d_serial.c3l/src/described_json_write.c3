module c3d::serial;

import c3d;
import c3d::describe;

struct DescribedJsonWrite @private {
    JsonOutput* output;
    WriteContext* context;
    bool root;
}

fn void? write_described_json(
    DescribedType* type,
    JsonOutput* output,
    WriteContext* context,
    void* value,
) @private {
    DescribedJsonWrite state = { .output = output, .context = context, .root = true };
    describe::Visitor visitor = {
        .mode = WRITE,
        .field = &described_json_field,
        .begin = &described_json_begin,
        .end = &described_json_end,
        .user = &state,
    };
    describe::walk_descriptor(type.descriptor, &visitor, value)!;
}

fn bool? described_json_begin(describe::Visitor* visitor, describe::Info* info, void* value) @local {
    DescribedJsonWrite* state = visitor.user;
    if (state.root) {
        state.root = false;
        return true;
    }
    state.output.begin(info.name, info.kind == STRUCT)!;
    return true;
}

fn void? described_json_end(describe::Visitor* visitor, describe::Info* info, void* value) @local {
    DescribedJsonWrite* state = visitor.user;
    state.output.end()!;
}

fn bool? described_json_field(describe::Visitor* visitor, describe::Info* info, void* value) @local {
    DescribedJsonWrite* state = visitor.user;
    JsonOutput* output = state.output;
    char[TEXT_NUMBER_FORMAT_BYTES] scratch;
    switch (info.kind) {
        case BOOL: output.boolean(info.name, *(bool*)value)!;
        case ICHAR: output.signed(info.name, *(ichar*)value)!;
        case CHAR: output.unsigned(info.name, *(char*)value)!;
        case SHORT: output.signed(info.name, *(short*)value)!;
        case USHORT: output.unsigned(info.name, *(ushort*)value)!;
        case INT: output.signed(info.name, *(int*)value)!;
        case UINT: output.unsigned(info.name, *(uint*)value)!;
        case LONG: output.number(info.name, text_format_long(scratch[..], *(long*)value)!)!;
        case ULONG: output.number(info.name, text_format_ulong(scratch[..], *(ulong*)value)!)!;
        case FLOAT: output.float_bits(info.name, *(uint*)value)!;
        case DOUBLE: output.double_bits(info.name, *(ulong*)value)!;
        case VEC2:
        case VEC3:
        case VEC4:
        case QUAT:
        case UVEC3:
        case MAT4:
            output.lanes(
                name: info.name,
                values: value,
                count: described_lanes(info.kind),
                integer: info.kind == UVEC3,
            )!;
        case STRING: output.string(info.name, *(String*)value)!;
        case ENUM:
            ulong ordinal = info.read_enum(value);
            if (ordinal >= info.enum_names.len) return c3d::INVALID_ARGUMENT~;
            output.string(info.name, info.enum_names[ordinal])!;
        case ENTITY:
        case ASSET:
            uint reference = described_reference_index(state.context, info, value)!;
            if (reference == INDEX_NONE) {
                output.literal(info.name, "null")!;
            } else if (info.kind == ENTITY) {
                output.unsigned(info.name, reference)!;
            } else {
                output.string(info.name, state.context.state.keys[reference])!;
            }
        case STRUCT:
        case ARRAY:
        case SLICE: unreachable();
    }
    return false;
}

fn uint? described_reference_index(WriteContext* context, describe::Info* info, void* value) @private {
    Id* id = value;
    if (!id.index && !id.generation) return INDEX_NONE;
    if (!context) return c3d::INVALID_ARGUMENT~;
    char[uint::size] bytes;
    Writer writer = writer_over(bytes[..]);
    if (info.kind == ENTITY) {
        context.write_entity(&writer, *(Entity*)value)!;
    } else {
        write_described_asset(
            context: context,
            writer: &writer,
            kind: info.metadata.asset_kind,
            custom_slot: info.metadata.custom_slot,
            value: value,
        )!;
    }
    Reader reader = reader_over(bytes[..]);
    return reader.read_uint()!;
}
