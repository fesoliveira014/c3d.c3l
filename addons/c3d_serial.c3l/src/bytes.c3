module c3d::serial;

import c3d;
import c3d::maths;
import std::math;

const uint BYTE_BITS @local = 8;

<* Measuring or bounded byte output. *>
struct Writer {
    char* base;
    usz offset;
    usz capacity;
    bool measuring;
    fault failure;
}

<* Bounded byte input. *>
struct Reader {
    char[] bytes;
    usz offset;
}

<* Bytes emitted by the cursor. *>
fn usz Writer.written(&self) => self.offset;

<*
 Check the bounded output size.
 @return? c3d::CAPACITY_EXCEEDED
*>
fn void? Writer.finish(&self) {
    if (self.failure) return self.failure~;
}

<*
 Append bytes without an implicit allocation.
 @require self.measuring || bytes.len <= self.capacity - self.offset
*>
fn void Writer.write_bytes(&self, char[] bytes) {
    if (self.failure) return;
    if (bytes.len > uint::max - self.offset) {
        self.failure = c3d::CAPACITY_EXCEEDED;
        return;
    }
    if (!self.measuring) self.base[self.offset:bytes.len] = bytes[..];
    self.offset += bytes.len;
}

<* Append a little-endian unsigned integer. *>
fn void Writer.write_uint(&self, uint value) {
    char[uint::size] bytes;
    foreach (index, &part : bytes) *part = (char)(value >> (index * BYTE_BITS));
    self.write_bytes(bytes[..]);
}

<* Append a little-endian signed integer. *>
fn void Writer.write_int(&self, int value) => self.write_uint(bitcast(value, uint));

<* Append a little-endian unsigned wide integer. *>
fn void Writer.write_ulong(&self, ulong value) {
    char[ulong::size] bytes;
    foreach (index, &part : bytes) *part = (char)(value >> (index * BYTE_BITS));
    self.write_bytes(bytes[..]);
}

<* Append an IEEE binary32 value. *>
fn void Writer.write_float(&self, float value) => self.write_uint(bitcast(value, uint));

<* Append a canonical boolean byte. *>
fn void Writer.write_bool(&self, bool value) {
    char part = value ? 1 : 0;
    self.write_bytes((&part)[:1]);
}

<*
 Append a length-prefixed UTF-8 string.
 @require valid_utf8(value)
*>
fn void Writer.write_string(&self, String value) {
    if (value.len > uint::max) {
        self.failure = c3d::CAPACITY_EXCEEDED;
        return;
    }
    self.write_uint((uint)value.len);
    self.write_bytes((char[])value);
}

<* Append a versioned enum ordinal. *>
macro void Writer.write_enum(&self, value) {
    self.write_uint((uint)value.ordinal);
}

<* Bytes remaining in the input cursor. *>
fn usz Reader.remaining(&self) => self.bytes.len - self.offset;

<*
 Borrow the next bounded byte range.
 @return? c3d::ASSET_FORMAT_ERROR
*>
fn char[]? Reader.read_bytes(&self, usz count) {
    if (count > self.remaining()) return c3d::ASSET_FORMAT_ERROR~;
    char[] result = self.bytes[self.offset:count];
    self.offset += count;
    return result;
}

<*
 Read a little-endian unsigned integer.
 @return? c3d::ASSET_FORMAT_ERROR
*>
fn uint? Reader.read_uint(&self) {
    char[] bytes = self.read_bytes(uint::size)!;
    uint value;
    foreach (index, part : bytes) value |= (uint)part << (index * BYTE_BITS);
    return value;
}

<*
 Read a little-endian signed integer.
 @return? c3d::ASSET_FORMAT_ERROR
*>
fn int? Reader.read_int(&self) {
    uint value = self.read_uint()!;
    return bitcast(value, int);
}

<*
 Read a little-endian unsigned wide integer.
 @return? c3d::ASSET_FORMAT_ERROR
*>
fn ulong? Reader.read_ulong(&self) {
    char[] bytes = self.read_bytes(ulong::size)!;
    ulong value;
    foreach (index, part : bytes) value |= (ulong)part << (index * BYTE_BITS);
    return value;
}

<*
 Read an IEEE binary32 value.
 @return? c3d::ASSET_FORMAT_ERROR
*>
fn float? Reader.read_float(&self) {
    uint value = self.read_uint()!;
    return bitcast(value, float);
}

<*
 Read a canonical boolean byte.
 @return? c3d::ASSET_FORMAT_ERROR
*>
fn bool? Reader.read_bool(&self) {
    char[] bytes = self.read_bytes(1)!;
    if (bytes[0] > 1) return c3d::ASSET_FORMAT_ERROR~;
    return bytes[0] != 0;
}

<*
 Borrow a length-prefixed UTF-8 string.
 @return? c3d::ASSET_FORMAT_ERROR
*>
fn String? Reader.read_string(&self) {
    uint count = self.read_uint()!;
    String result = (String)self.read_bytes(count)!;
    if (!valid_utf8(result)) return c3d::ASSET_FORMAT_ERROR~;
    return result;
}

<*
 Read a supported enum ordinal.
 @return? c3d::ASSET_FORMAT_ERROR
*>
macro Reader.read_enum(&self, $Enum) {
    uint ordinal = self.read_uint()!;
    if (ordinal >= $Enum::values.len) return c3d::ASSET_FORMAT_ERROR~;
    return ($Enum)ordinal;
}

<* Create a cursor over caller-owned output. *>
fn Writer writer_over(char[] bytes) {
    return { .base = bytes.ptr, .capacity = bytes.len };
}

<* Create a cursor that counts without storing. *>
fn Writer measuring_writer() {
    return { .capacity = uint::max, .measuring = true };
}

<* Create a cursor over borrowed input. *>
fn Reader reader_over(char[] bytes) {
    return { .bytes = bytes };
}

fn bool valid_utf8(String value) @private {
    usz index;
    while (index < value.len) {
        uint first = value[index++];
        if (first < 0x80) continue;
        uint trailing;
        uint scalar;
        uint minimum;
        if (first >= 0xc2 && first <= 0xdf) {
            trailing = 1;
            scalar = first & 0x1f;
            minimum = 0x80;
        } else if (first >= 0xe0 && first <= 0xef) {
            trailing = 2;
            scalar = first & 0x0f;
            minimum = 0x800;
        } else if (first >= 0xf0 && first <= 0xf4) {
            trailing = 3;
            scalar = first & 0x07;
            minimum = 0x10000;
        } else {
            return false;
        }
        if (trailing > value.len - index) return false;
        for (uint count = 0; count < trailing; count++) {
            uint part = value[index++];
            if ((part & 0xc0) != 0x80) return false;
            scalar = (scalar << 6) | (part & 0x3f);
        }
        if (scalar < minimum || scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) return false;
    }
    return true;
}
