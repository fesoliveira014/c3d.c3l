module c3d::serial;

import c3d;
import c3d::describe;

const uint MAX_DESCRIBED_DEPTH @private = 64; // bounded reader stack; matches the text profile's hard cap

struct DescribedWriteState @private {
    Writer* writer;
    WriteContext* context;
    usz[MAX_DESCRIBED_DEPTH] lengths;
    uint depth;
}

struct DescribedReadState @private {
    Reader* reader;
    ReadContext* context;
    Acquisitions* owned;
    usz[MAX_DESCRIBED_DEPTH] ends;
    uint depth;
}

fn void? write_described_value(
    DescribedType* type,
    Writer* writer,
    WriteContext* context,
    void* value,
) @private {
    DescribedWriteState state = { .writer = writer, .context = context };
    describe::Visitor visitor = {
        .mode = WRITE,
        .field = &described_write_field,
        .begin = &described_write_begin,
        .end = &described_write_end,
        .user = &state,
    };
    describe::walk_descriptor(type.descriptor, &visitor, value)!;
    writer.finish()!;
}

fn void? read_described_value(
    DescribedType* type,
    Reader* reader,
    ReadContext* context,
    Acquisitions* owned,
    void* value,
) @private {
    DescribedReadState state = { .reader = reader, .context = context, .owned = owned };
    char[] original = reader.bytes;
    defer reader.bytes = original;
    describe::Visitor visitor = {
        .mode = READ,
        .field = &described_read_field,
        .begin = &described_read_begin,
        .end = &described_read_end,
        .user = &state,
    };
    describe::walk_descriptor(type.descriptor, &visitor, value)!;
    if (reader.remaining()) return c3d::ASSET_FORMAT_ERROR~;
}

fn bool? described_write_begin(describe::Visitor* visitor, describe::Info* info, void* value) @local {
    DescribedWriteState* state = visitor.user;
    if (state.depth == MAX_DESCRIBED_DEPTH) return c3d::CAPACITY_EXCEEDED~;
    switch (info.kind) {
        case STRUCT:
            DescribedType* type = find_described_type(info.identity)!;
            state.writer.write_uint(type.version);
            state.writer.write_ulong(type.layout);
        case ARRAY: state.writer.write_uint((uint)info.extent);
        case SLICE:
            usz count = (usz)((SliceRaw*)value).len;
            if (count > uint::max) return c3d::CAPACITY_EXCEEDED~;
            state.writer.write_uint((uint)count);
        default: unreachable();
    }
    state.lengths[state.depth++] = state.writer.offset;
    state.writer.write_uint(0);
    return true;
}

fn void? described_write_end(describe::Visitor* visitor, describe::Info* info, void* value) @local {
    DescribedWriteState* state = visitor.user;
    state.writer.finish()!;
    usz position = state.lengths[--state.depth];
    uint length = (uint)(state.writer.offset - position - uint::size);
    if (state.writer.measuring) return;
    Writer patch = writer_over(state.writer.base[position:uint::size]);
    patch.write_uint(length);
}

fn bool? described_write_field(describe::Visitor* visitor, describe::Info* info, void* value) @local {
    DescribedWriteState* state = visitor.user;
    Writer* writer = state.writer;
    switch (info.kind) {
        case BOOL: writer.write_bool(*(bool*)value);
        case ICHAR: write_integer(writer, bitcast(*(ichar*)value, char), char::size);
        case CHAR: write_integer(writer, *(char*)value, char::size);
        case SHORT: write_integer(writer, bitcast(*(short*)value, ushort), ushort::size);
        case USHORT: write_integer(writer, *(ushort*)value, ushort::size);
        case INT: writer.write_int(*(int*)value);
        case UINT: writer.write_uint(*(uint*)value);
        case LONG: writer.write_ulong(bitcast(*(long*)value, ulong));
        case ULONG: writer.write_ulong(*(ulong*)value);
        case FLOAT: writer.write_uint(*(uint*)value);
        case DOUBLE: writer.write_ulong(*(ulong*)value);
        case VEC2:
        case VEC3:
        case VEC4:
        case QUAT:
        case UVEC3:
        case MAT4:
            for (uint index = 0; index < described_lanes(info.kind); index++) {
                writer.write_uint(((uint*)value)[index]);
            }
        case STRING:
            if (!valid_utf8(*(String*)value)) return c3d::INVALID_ARGUMENT~;
            writer.write_string(*(String*)value);
        case ENUM: writer.write_ulong(info.read_enum(value));
        case ENTITY: state.context.write_entity(writer, *(Entity*)value)!;
        case ASSET:
            write_described_asset(
                context: state.context,
                writer: writer,
                kind: info.metadata.asset_kind,
                value: value,
            )!;
        case STRUCT:
        case ARRAY:
        case SLICE: unreachable();
    }
    writer.finish()!;
    return false;
}

fn bool? described_read_begin(describe::Visitor* visitor, describe::Info* info, void* value) @local {
    DescribedReadState* state = visitor.user;
    Reader* reader = state.reader;
    if (state.depth == MAX_DESCRIBED_DEPTH) return c3d::CAPACITY_EXCEEDED~;
    uint count;
    switch (info.kind) {
        case STRUCT:
            DescribedType* type = find_described_type(info.identity)!;
            uint version = reader.read_uint()!;
            ulong layout = reader.read_ulong()!;
            if (version != type.version) return c3d::UNSUPPORTED~;
            if (layout != type.layout) return c3d::ASSET_FORMAT_ERROR~;
            type.defaults(value);
        case ARRAY:
            count = reader.read_uint()!;
            if (count != info.extent) return c3d::ASSET_FORMAT_ERROR~;
        case SLICE: count = reader.read_uint()!;
        default: unreachable();
    }
    uint length = reader.read_uint()!;
    if (length > reader.remaining()) return c3d::ASSET_FORMAT_ERROR~;
    if (info.kind == SLICE) {
        if (count > length / minimum_described_size(info.element_kind)) return c3d::ASSET_FORMAT_ERROR~;
        SliceRaw* slice = value;
        slice.ptr = state.owned.acquire(
            count: count,
            element_size: info.element_size,
            alignment: info.element_alignment,
        )!;
        slice.len = count;
    }
    state.ends[state.depth++] = reader.bytes.len;
    reader.bytes = reader.bytes[:reader.offset + length];
    return true;
}

fn void? described_read_end(describe::Visitor* visitor, describe::Info* info, void* value) @local {
    DescribedReadState* state = visitor.user;
    if (state.reader.remaining()) return c3d::ASSET_FORMAT_ERROR~;
    state.reader.bytes = state.reader.bytes.ptr[:state.ends[--state.depth]];
}

fn bool? described_read_field(describe::Visitor* visitor, describe::Info* info, void* value) @local {
    DescribedReadState* state = visitor.user;
    Reader* reader = state.reader;
    switch (info.kind) {
        case BOOL: *(bool*)value = reader.read_bool()!;
        case ICHAR:
        case CHAR: *(char*)value = (char)read_integer(reader, char::size)!;
        case SHORT:
        case USHORT: *(ushort*)value = (ushort)read_integer(reader, ushort::size)!;
        case INT:
        case UINT:
        case FLOAT: *(uint*)value = reader.read_uint()!;
        case LONG:
        case ULONG:
        case DOUBLE: *(ulong*)value = reader.read_ulong()!;
        case VEC2:
        case VEC3:
        case VEC4:
        case QUAT:
        case UVEC3:
        case MAT4:
            for (uint index = 0; index < described_lanes(info.kind); index++) {
                ((uint*)value)[index] = reader.read_uint()!;
            }
        case STRING:
            String source = reader.read_string()!;
            char* copy = state.owned.acquire(source.len, char::size, char::alignment)!;
            if (source.len) copy[:source.len] = ((char[])source)[..];
            *(String*)value = (String)copy[:source.len];
        case ENUM:
            ulong ordinal = reader.read_ulong()!;
            if (ordinal >= info.enum_names.len) return c3d::ASSET_FORMAT_ERROR~;
            info.write_enum(value, ordinal)!;
        case ENTITY: *(Entity*)value = state.context.read_entity(reader)!;
        case ASSET:
            read_described_asset(
                context: state.context,
                reader: reader,
                kind: info.metadata.asset_kind,
                value: value,
            )!;
        case STRUCT:
        case ARRAY:
        case SLICE: unreachable();
    }
    return false;
}

fn uint described_lanes(describe::Kind kind) @private {
    switch (kind) {
        case VEC2: return 2;
        case VEC3:
        case UVEC3: return 3;
        case VEC4:
        case QUAT: return 4;
        case MAT4: return 16;
        default: unreachable();
    }
}

fn uint minimum_described_size(describe::Kind kind) @local {
    switch (kind) {
        case BOOL:
        case ICHAR:
        case CHAR: return 1;
        case SHORT:
        case USHORT: return 2;
        case INT:
        case UINT:
        case FLOAT:
        case STRING:
        case ENTITY:
        case ASSET: return uint::size;
        case LONG:
        case ULONG:
        case DOUBLE:
        case ENUM: return ulong::size;
        case VEC2:
        case VEC3:
        case VEC4:
        case QUAT:
        case UVEC3:
        case MAT4: return described_lanes(kind) * uint::size;
        case STRUCT: return 2 * uint::size + ulong::size;
        case ARRAY:
        case SLICE: return 2 * uint::size;
    }
}

fn void write_integer(Writer* writer, ulong value, uint width) @local {
    char[ulong::size] bytes;
    for (uint index = 0; index < width; index++) bytes[index] = (char)(value >> (index * 8));
    writer.write_bytes(bytes[:width]);
}

fn ulong? read_integer(Reader* reader, uint width) @local {
    char[] bytes = reader.read_bytes(width)!;
    ulong value;
    foreach (index, part : bytes) value |= (ulong)part << (index * 8);
    return value;
}
