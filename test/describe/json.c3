module c3d::test::describe_consumers @private;

import c3d;
import c3d::describe;
import std::collections::object;
import std::encoding::json;
import std::io;
import std::math;

struct JsonWriter {
    DString text;
    usz[MAX_SCOPES] counts;
    bool[MAX_SCOPES] maps;
    usz depth;
}

struct JsonReader {
    Object* root;
    Object*[MAX_SCOPES] scopes;
    sz[MAX_SCOPES] indices;
    usz depth;
    Acquisitions owned;
    String fail_name;
}

fn void? JsonWriter.prefix(&self, String name) {
    if (!self.depth) return;
    usz scope = self.depth - 1;
    if (self.counts[scope]++) self.text.append(',');
    if (self.maps[scope]) {
        json::marshal_to(&self.text, name)!;
        self.text.append(':');
    }
}

fn Object*? JsonReader.select(&self, String name) {
    if (!self.depth) return self.root;
    usz scope = self.depth - 1;
    Object* parent = self.scopes[scope];
    if (parent.is_map()) {
        if (try child = parent.get(name)) return child;
        return INVALID_FIXTURE~;
    }
    if (!parent.is_array() || self.indices[scope] >= parent.len()) return INVALID_FIXTURE~;
    return parent.get_at(self.indices[scope]++);
}

fn bool? json_write_begin(describe::Visitor* visitor, describe::Info* info, void* value) {
    JsonWriter* writer = (JsonWriter*)visitor.user;
    if (writer.depth == MAX_SCOPES) return INVALID_FIXTURE~;
    writer.prefix(info.name)!;
    bool map = info.kind == STRUCT;
    writer.text.append(map ? '{' : '[');
    writer.maps[writer.depth] = map;
    writer.counts[writer.depth++] = 0;
    return true;
}

fn void? json_write_end(describe::Visitor* visitor, describe::Info* info, void* value) {
    JsonWriter* writer = (JsonWriter*)visitor.user;
    writer.text.append(writer.maps[--writer.depth] ? '}' : ']');
}

fn void? json_write_number(DString* text, double number) {
    ulong bits = bitcast(number, ulong);
    if ((bits & 0x7ff0000000000000UL) == 0x7ff0000000000000UL) {
        io::fprintf(text, "\"f64:%016x\"", bits)!;
        return;
    }
    if (bitcast(number, ulong) == 0x8000000000000000) {
        text.append("-0.0");
        return;
    }
    io::fprintf(text, "%.17g", number)!;
}

fn void? json_write_float(DString* text, uint bits) {
    if ((bits & 0x7f800000U) == 0x7f800000U) {
        io::fprintf(text, "\"f32:%08x\"", bits)!;
    } else if (bits == 0x80000000U) {
        text.append("-0.0");
    } else {
        io::fprintf(text, "%.9g", bitcast(bits, float))!;
    }
}

fn void? json_write_token(DString* text, ulong token) {
    text.append('"');
    json::marshal_to(text, token)!;
    text.append('"');
}

fn bool? json_write_field(describe::Visitor* visitor, describe::Info* info, void* value) {
    JsonWriter* writer = (JsonWriter*)visitor.user;
    writer.prefix(info.name)!;
    switch (info.kind) {
        case BOOL: json::marshal_to(&writer.text, *(bool*)value)!;
        case ICHAR: json::marshal_to(&writer.text, (int)*(ichar*)value)!;
        case CHAR: json::marshal_to(&writer.text, (uint)*(char*)value)!;
        case SHORT: json::marshal_to(&writer.text, (int)*(short*)value)!;
        case USHORT: json::marshal_to(&writer.text, (uint)*(ushort*)value)!;
        case INT: json::marshal_to(&writer.text, *(int*)value)!;
        case UINT: json::marshal_to(&writer.text, *(uint*)value)!;
        case LONG: json::marshal_to(&writer.text, *(long*)value)!;
        case ULONG: json_write_token(&writer.text, *(ulong*)value)!;
        case FLOAT: json_write_float(&writer.text, *(uint*)value)!;
        case DOUBLE: json_write_number(&writer.text, *(double*)value)!;
        case VEC2:
        case VEC3:
        case VEC4:
        case QUAT:
        case MAT4:
            writer.text.append('[');
            for (usz index = 0; index < component_count(info.kind); index++) {
                if (index) writer.text.append(',');
                json_write_float(&writer.text, ((uint*)value)[index])!;
            }
            writer.text.append(']');
        case UVEC3:
            writer.text.append('[');
            for (usz index = 0; index < 3; index++) {
                if (index) writer.text.append(',');
                json::marshal_to(&writer.text, ((uint*)value)[index])!;
            }
            writer.text.append(']');
        case STRING: json::marshal_to(&writer.text, *(String*)value)!;
        case ENUM: json::marshal_to(&writer.text, info.enum_names[info.read_enum(value)])!;
        case ENTITY:
        case ASSET:
            String token = reference_token(info, value)!;
            json::marshal_to(&writer.text, token)!;
        case STRUCT:
        case ARRAY:
        case SLICE: unreachable();
    }
    return false;
}

fn bool? json_read_begin(describe::Visitor* visitor, describe::Info* info, void* value) {
    JsonReader* reader = (JsonReader*)visitor.user;
    if (reader.depth == MAX_SCOPES) return INVALID_FIXTURE~;
    Object* node = reader.select(info.name)!;
    if (info.kind == STRUCT) {
        if (!node.is_map()) return INVALID_FIXTURE~;
    } else {
        if (!node.is_array()) return INVALID_FIXTURE~;
        usz count = (usz)node.len();
        if (info.kind == ARRAY && count != info.extent) return INVALID_FIXTURE~;
        if (info.kind == SLICE) {
            SliceRaw* slice = (SliceRaw*)value;
            slice.ptr = reader.owned.acquire(count, info.element_size, info.element_alignment)!;
            slice.len = (sz)count;
        }
    }
    reader.scopes[reader.depth] = node;
    reader.indices[reader.depth++] = 0;
    return true;
}

fn void? json_read_end(describe::Visitor* visitor, describe::Info* info, void* value) {
    JsonReader* reader = (JsonReader*)visitor.user;
    reader.depth--;
}

fn int128? json_integer(Object* node, int128 minimum, int128 maximum) {
    if (!node.is_int() || node.i < minimum || node.i > maximum) return INVALID_FIXTURE~;
    return node.i;
}

fn double? json_number(Object* node) {
    if (node.is_int()) return (double)node.i;
    if (!node.is_float() || !math::is_finite(node.f)) return INVALID_FIXTURE~;
    return node.f;
}

fn ulong? json_exceptional_bits(
    Object* node,
    String prefix,
    usz digits,
    ulong exponent,
) {
    if (!node.is_string() || node.s.len != digits + 4 || node.s[:4] != prefix) return INVALID_FIXTURE~;
    ulong bits;
    foreach (char digit : node.s[4..]) {
        if (digit >= '0' && digit <= '9') {
            bits = (bits << 4) | (ulong)(digit - '0');
        } else if (digit >= 'a' && digit <= 'f') {
            bits = (bits << 4) | (ulong)(digit - 'a' + 10);
        } else {
            return INVALID_FIXTURE~;
        }
    }
    if ((bits & exponent) != exponent) return INVALID_FIXTURE~;
    return bits;
}

fn float? json_float(Object* node) {
    if (node.is_string()) {
        return bitcast((uint)json_exceptional_bits(
            node: node,
            prefix: "f32:",
            digits: 8,
            exponent: 0x7f800000U,
        )!, float);
    }
    double number = json_number(node)!;
    if (number < -float::max || number > float::max) return INVALID_FIXTURE~;
    return (float)number;
}

fn double? json_double(Object* node) {
    if (node.is_string()) {
        return bitcast(json_exceptional_bits(
            node: node,
            prefix: "f64:",
            digits: 16,
            exponent: 0x7ff0000000000000UL,
        )!, double);
    }
    return json_number(node);
}

fn ulong? json_token(Object* node) {
    if (!node.is_string()) return INVALID_FIXTURE~;
    if (try token = node.s.to_ulong()) return token;
    return INVALID_FIXTURE~;
}

fn bool? json_read_field(describe::Visitor* visitor, describe::Info* info, void* value) {
    JsonReader* reader = (JsonReader*)visitor.user;
    if (reader.fail_name.len && info.name == reader.fail_name) return CONSUMER_ABORT~;
    Object* node = reader.select(info.name)!;
    switch (info.kind) {
        case BOOL:
            if (!node.is_bool()) return INVALID_FIXTURE~;
            *(bool*)value = node.b;
        case ICHAR: *(ichar*)value = (ichar)json_integer(node, ichar::min, ichar::max)!;
        case CHAR: *(char*)value = (char)json_integer(node, char::min, char::max)!;
        case SHORT: *(short*)value = (short)json_integer(node, short::min, short::max)!;
        case USHORT: *(ushort*)value = (ushort)json_integer(node, ushort::min, ushort::max)!;
        case INT: *(int*)value = (int)json_integer(node, int::min, int::max)!;
        case UINT: *(uint*)value = (uint)json_integer(node, 0, uint::max)!;
        case LONG: *(long*)value = (long)json_integer(node, long::min, long::max)!;
        case ULONG: *(ulong*)value = json_token(node)!;
        case FLOAT: *(float*)value = json_float(node)!;
        case DOUBLE: *(double*)value = json_double(node)!;
        case VEC2:
        case VEC3:
        case VEC4:
        case QUAT:
        case MAT4:
            usz count = component_count(info.kind);
            if (!node.is_array() || (usz)node.len() != count) return INVALID_FIXTURE~;
            for (usz index = 0; index < count; index++) {
                ((float*)value)[index] = json_float(node.get_at((sz)index))!;
            }
        case UVEC3:
            if (!node.is_array() || node.len() != 3) return INVALID_FIXTURE~;
            for (usz index = 0; index < 3; index++) {
                ((uint*)value)[index] = (uint)json_integer(node.get_at((sz)index), 0, uint::max)!;
            }
        case STRING:
            if (!node.is_string()) return INVALID_FIXTURE~;
            char* copy = (char*)reader.owned.acquire((usz)node.s.len, char::size)!;
            if (node.s.len) copy[:node.s.len] = ((char[])node.s)[..];
            *(String*)value = (String)copy[:node.s.len];
        case ENUM:
            if (!node.is_string()) return INVALID_FIXTURE~;
            bool found;
            foreach (ordinal, name : info.enum_names) {
                if (name != node.s) continue;
                info.write_enum(value, (ulong)ordinal)!;
                found = true;
                break;
            }
            if (!found) return INVALID_FIXTURE~;
        case ENTITY:
        case ASSET:
            if (!node.is_string()) return INVALID_FIXTURE~;
            read_reference(info, node.s, value)!;
        case STRUCT:
        case ARRAY:
        case SLICE: unreachable();
    }
    return false;
}

fn void? json_read(describe::Descriptor* descriptor, JsonReader* reader, void* value) {
    defer catch reader.owned.release_all();
    describe::Visitor visitor = {
        .mode = READ,
        .field = &json_read_field,
        .begin = &json_read_begin,
        .end = &json_read_end,
        .user = reader,
    };
    describe::walk_descriptor(descriptor, &visitor, value)!;
}

fn void? json_write(describe::Descriptor* descriptor, JsonWriter* writer, void* value) {
    describe::Visitor visitor = {
        .mode = WRITE,
        .field = &json_write_field,
        .begin = &json_write_begin,
        .end = &json_write_end,
        .user = writer,
    };
    describe::walk_descriptor(descriptor, &visitor, value)!;
}
