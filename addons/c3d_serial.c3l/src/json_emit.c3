module c3d::serial;

import c3d;
import std::io;

struct JsonOutput @private {
    Writer writer;
    TextLimits limits;
    bool[TEXT_MAX_DEPTH] objects;
    uint[TEXT_MAX_DEPTH] counts;
    uint depth;
}

fn void? JsonOutput.append(&self, String text) {
    if (text.len > self.limits.max_bytes - self.writer.offset) return c3d::CAPACITY_EXCEEDED~;
    self.writer.write_bytes((char[])text);
    self.writer.finish()!;
}

fn void? JsonOutput.indent(&self) {
    self.append("\n")!;
    for (uint index = 0; index < self.depth; index++) self.append("  ")!;
}

fn void? JsonOutput.quoted(&self, String value) {
    if (!valid_utf8(value)) return c3d::INVALID_ARGUMENT~;
    usz start = self.writer.offset;
    self.append("\"")!;
    foreach (part : value) {
        switch (part) {
            case '"': self.append("\\\"")!;
            case '\\': self.append("\\\\")!;
            case '\b': self.append("\\b")!;
            case '\f': self.append("\\f")!;
            case '\n': self.append("\\n")!;
            case '\r': self.append("\\r")!;
            case '\t': self.append("\\t")!;
            default:
                if (part < 0x20) {
                    char[6] escaped = { '\\', 'u', '0', '0', "0123456789abcdef"[part >> 4],
                        "0123456789abcdef"[part & 15] };
                    self.append((String)escaped[..])!;
                } else {
                    self.append((String)(&part)[:1])!;
                }
        }
        if (self.writer.offset - start + 1 > self.limits.max_string_bytes) return c3d::CAPACITY_EXCEEDED~;
    }
    self.append("\"")!;
    if (self.writer.offset - start > self.limits.max_string_bytes) return c3d::CAPACITY_EXCEEDED~;
}

fn void? JsonOutput.prefix(&self, String name) {
    if (!self.depth) return;
    if (self.counts[self.depth - 1]++) self.append(",")!;
    self.indent()!;
    if (self.objects[self.depth - 1]) {
        self.quoted(name)!;
        self.append(": ")!;
    }
}

fn void? JsonOutput.begin(&self, String name, bool object) {
    if (self.depth == self.limits.max_depth) return c3d::CAPACITY_EXCEEDED~;
    self.prefix(name)!;
    self.append(object ? "{" : "[")!;
    self.objects[self.depth] = object;
    self.counts[self.depth++] = 0;
}

fn void? JsonOutput.end(&self) {
    bool object = self.objects[--self.depth];
    if (self.counts[self.depth]) self.indent()!;
    self.append(object ? "}" : "]")!;
}

fn void? JsonOutput.string(&self, String name, String value) {
    self.prefix(name)!;
    self.quoted(value)!;
}

fn void? JsonOutput.literal(&self, String name, String token) {
    self.prefix(name)!;
    self.append(token)!;
}

fn void? JsonOutput.number(&self, String name, String token) {
    usz limit = token[0] == '"' ? self.limits.max_string_bytes : self.limits.max_number_bytes;
    if (token.len > limit) return c3d::CAPACITY_EXCEEDED~;
    self.literal(name, token)!;
}

fn void? JsonOutput.signed(&self, String name, long value) {
    char[TEXT_NUMBER_FORMAT_BYTES] scratch;
    String token = (String)(io::bprintf(scratch[..], "%s", value) ?? c3d::CAPACITY_EXCEEDED~!);
    self.number(name, token)!;
}

fn void? JsonOutput.unsigned(&self, String name, ulong value) {
    char[TEXT_NUMBER_FORMAT_BYTES] scratch;
    String token = (String)(io::bprintf(scratch[..], "%s", value) ?? c3d::CAPACITY_EXCEEDED~!);
    self.number(name, token)!;
}
