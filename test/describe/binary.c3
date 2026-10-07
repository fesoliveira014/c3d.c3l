module c3d::test::describe_consumers @private;

import c3d;
import c3d::describe;

struct BinaryWriter {
    char[FIXTURE_BYTES] bytes;
    usz position;
    usz[MAX_SCOPES] scopes;
    usz depth;
}

struct BinaryReader {
    char[] bytes;
    usz position;
    usz[MAX_SCOPES] limits;
    usz depth;
    Acquisitions owned;
    String fail_name;
}

fn void? BinaryWriter.integer(&self, ulong value, usz width) {
    if (width > FIXTURE_BYTES - self.position) return INVALID_FIXTURE~;
    for (usz index = 0; index < width; index++) {
        self.bytes[self.position++] = (char)(value >> (index * 8));
    }
}

fn ulong? BinaryReader.integer(&self, usz width) {
    usz limit = self.depth ? self.limits[self.depth - 1] : (usz)self.bytes.len;
    if (width > limit - self.position) return INVALID_FIXTURE~;
    ulong value;
    for (usz index = 0; index < width; index++) {
        value |= (ulong)self.bytes[self.position++] << (index * 8);
    }
    return value;
}

fn usz minimum_encoded_size(describe::Kind kind) {
    switch (kind) {
        case BOOL:
        case ICHAR:
        case CHAR: return 1;
        case SHORT:
        case USHORT: return ushort::size;
        case UVEC3: return 3 * uint::size;
        case INT:
        case UINT:
        case FLOAT: return uint::size;
        case LONG:
        case ULONG:
        case DOUBLE:
        case ENUM: return ulong::size;
        case VEC2:
        case VEC3:
        case VEC4:
        case QUAT:
        case MAT4: return component_count(kind) * float::size;
        case STRING:
        case ENTITY:
        case ASSET:
        case STRUCT: return uint::size;
        case ARRAY:
        case SLICE: return 2 * uint::size;
    }
}

fn bool? binary_write_begin(describe::Visitor* visitor, describe::Info* info, void* value) {
    BinaryWriter* writer = (BinaryWriter*)visitor.user;
    if (writer.depth == MAX_SCOPES) return INVALID_FIXTURE~;
    if (info.kind == ARRAY) writer.integer(info.extent, uint::size)!;
    if (info.kind == SLICE) writer.integer((ulong)((SliceRaw*)value).len, uint::size)!;
    writer.scopes[writer.depth++] = writer.position;
    writer.integer(0, uint::size)!;
    return true;
}

fn void? binary_write_end(describe::Visitor* visitor, describe::Info* info, void* value) {
    BinaryWriter* writer = (BinaryWriter*)visitor.user;
    usz length_position = writer.scopes[--writer.depth];
    usz length = writer.position - length_position - uint::size;
    for (usz index = 0; index < uint::size; index++) {
        writer.bytes[length_position + index] = (char)(length >> (index * 8));
    }
}

fn bool? binary_write_field(describe::Visitor* visitor, describe::Info* info, void* value) {
    BinaryWriter* writer = (BinaryWriter*)visitor.user;
    switch (info.kind) {
        case BOOL: writer.integer(*(bool*)value ? 1 : 0, 1)!;
        case ICHAR: writer.integer(bitcast(*(ichar*)value, char), ichar::size)!;
        case CHAR: writer.integer(*(char*)value, char::size)!;
        case SHORT: writer.integer(bitcast(*(short*)value, ushort), short::size)!;
        case USHORT: writer.integer(*(ushort*)value, ushort::size)!;
        case INT: writer.integer(bitcast(*(int*)value, uint), int::size)!;
        case UINT: writer.integer(*(uint*)value, uint::size)!;
        case LONG: writer.integer(bitcast(*(long*)value, ulong), long::size)!;
        case ULONG: writer.integer(*(ulong*)value, ulong::size)!;
        case FLOAT: writer.integer(bitcast(*(float*)value, uint), float::size)!;
        case DOUBLE: writer.integer(bitcast(*(double*)value, ulong), double::size)!;
        case VEC2:
        case VEC3:
        case VEC4:
        case QUAT:
        case MAT4:
            for (usz index = 0; index < component_count(info.kind); index++) {
                writer.integer(bitcast(((float*)value)[index], uint), float::size)!;
            }
        case UVEC3:
            for (usz index = 0; index < 3; index++) writer.integer(((uint*)value)[index], uint::size)!;
        case STRING:
            String string = *(String*)value;
            writer.integer((ulong)string.len, uint::size)!;
            if (string.len > FIXTURE_BYTES - writer.position) return INVALID_FIXTURE~;
            writer.bytes[writer.position:string.len] = ((char[])string)[..];
            writer.position += (usz)string.len;
        case ENUM: writer.integer(info.read_enum(value), ulong::size)!;
        case ENTITY:
        case ASSET:
            String token = reference_token(info, value)!;
            writer.integer((ulong)token.len, uint::size)!;
            if (token.len > FIXTURE_BYTES - writer.position) return INVALID_FIXTURE~;
            writer.bytes[writer.position:token.len] = ((char[])token)[..];
            writer.position += (usz)token.len;
        case STRUCT:
        case ARRAY:
        case SLICE: unreachable();
    }
    return false;
}

fn bool? binary_read_begin(describe::Visitor* visitor, describe::Info* info, void* value) {
    BinaryReader* reader = (BinaryReader*)visitor.user;
    if (reader.depth == MAX_SCOPES) return INVALID_FIXTURE~;
    ulong count;
    if (info.kind == ARRAY || info.kind == SLICE) count = reader.integer(uint::size)!;
    ulong length = reader.integer(uint::size)!;
    usz limit = reader.depth ? reader.limits[reader.depth - 1] : (usz)reader.bytes.len;
    if (length > limit - reader.position) return INVALID_FIXTURE~;
    if (info.kind == ARRAY && count != info.extent) return INVALID_FIXTURE~;
    if (info.kind == SLICE) {
        if (count > length / minimum_encoded_size(info.element_kind)) return INVALID_FIXTURE~;
        SliceRaw* slice = (SliceRaw*)value;
        slice.ptr = reader.owned.acquire((usz)count, info.element_size, info.element_alignment)!;
        slice.len = (sz)count;
    }
    reader.limits[reader.depth++] = reader.position + (usz)length;
    return true;
}

fn void? binary_read_end(describe::Visitor* visitor, describe::Info* info, void* value) {
    BinaryReader* reader = (BinaryReader*)visitor.user;
    if (reader.position != reader.limits[--reader.depth]) return INVALID_FIXTURE~;
}

fn bool? binary_read_field(describe::Visitor* visitor, describe::Info* info, void* value) {
    BinaryReader* reader = (BinaryReader*)visitor.user;
    if (reader.fail_name.len && info.name == reader.fail_name) return CONSUMER_ABORT~;
    switch (info.kind) {
        case BOOL:
            ulong encoded = reader.integer(1)!;
            if (encoded > 1) return INVALID_FIXTURE~;
            *(bool*)value = encoded != 0;
        case ICHAR: *(ichar*)value = bitcast((char)reader.integer(ichar::size)!, ichar);
        case CHAR: *(char*)value = (char)reader.integer(char::size)!;
        case SHORT: *(short*)value = bitcast((ushort)reader.integer(short::size)!, short);
        case USHORT: *(ushort*)value = (ushort)reader.integer(ushort::size)!;
        case INT: *(int*)value = bitcast((uint)reader.integer(int::size)!, int);
        case UINT: *(uint*)value = (uint)reader.integer(uint::size)!;
        case LONG: *(long*)value = bitcast(reader.integer(long::size)!, long);
        case ULONG: *(ulong*)value = reader.integer(ulong::size)!;
        case FLOAT: *(float*)value = bitcast((uint)reader.integer(float::size)!, float);
        case DOUBLE: *(double*)value = bitcast(reader.integer(double::size)!, double);
        case VEC2:
        case VEC3:
        case VEC4:
        case QUAT:
        case MAT4:
            for (usz index = 0; index < component_count(info.kind); index++) {
                ((float*)value)[index] = bitcast((uint)reader.integer(float::size)!, float);
            }
        case UVEC3:
            for (usz index = 0; index < 3; index++) ((uint*)value)[index] = (uint)reader.integer(uint::size)!;
        case STRING:
            ulong length = reader.integer(uint::size)!;
            usz limit = reader.depth ? reader.limits[reader.depth - 1] : (usz)reader.bytes.len;
            if (length > limit - reader.position) return INVALID_FIXTURE~;
            char* destination = (char*)reader.owned.acquire((usz)length, char::size)!;
            if (length) destination[:(sz)length] = reader.bytes[reader.position:(sz)length];
            *(String*)value = (String)destination[:(sz)length];
            reader.position += (usz)length;
        case ENUM:
            ulong ordinal = reader.integer(ulong::size)!;
            if (ordinal >= info.enum_names.len) return INVALID_FIXTURE~;
            info.write_enum(value, ordinal)!;
        case ENTITY:
        case ASSET:
            ulong length = reader.integer(uint::size)!;
            usz limit = reader.depth ? reader.limits[reader.depth - 1] : (usz)reader.bytes.len;
            if (length > limit - reader.position || length > MAX_ELEMENTS) return INVALID_FIXTURE~;
            String token = (String)reader.bytes[reader.position:(sz)length];
            read_reference(info, token, value)!;
            reader.position += (usz)length;
        case STRUCT:
        case ARRAY:
        case SLICE: unreachable();
    }
    return false;
}

fn void? binary_read(describe::Descriptor* descriptor, BinaryReader* reader, void* value) {
    defer catch reader.owned.release_all();
    describe::Visitor visitor = {
        .mode = READ,
        .field = &binary_read_field,
        .begin = &binary_read_begin,
        .end = &binary_read_end,
        .user = reader,
    };
    describe::walk_descriptor(descriptor, &visitor, value)!;
    if (reader.position != reader.bytes.len) return INVALID_FIXTURE~;
}

fn void? binary_write(describe::Descriptor* descriptor, BinaryWriter* writer, void* value) {
    describe::Visitor visitor = {
        .mode = WRITE,
        .field = &binary_write_field,
        .begin = &binary_write_begin,
        .end = &binary_write_end,
        .user = writer,
    };
    describe::walk_descriptor(descriptor, &visitor, value)!;
}
