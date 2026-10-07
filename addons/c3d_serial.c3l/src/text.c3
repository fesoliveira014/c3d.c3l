module c3d::serial;

import c3d;

<* Hard ceiling for nested JSONC objects and arrays. *>
const uint TEXT_MAX_DEPTH = 64; // bounds recursion; each fixed diagnostic path reserves 64 entries

<* Hard ceiling shared with the binary container's size bound. *>
const usz TEXT_MAX_BYTES = uint::max;

<* Default limits for one JSONC document. *>
const TextLimits TEXT_LIMITS_DEFAULT = {
    .max_bytes = 64 * 1024 * 1024,
    .max_string_bytes = 1024 * 1024,
    .max_number_bytes = 128,
    .max_depth = TEXT_MAX_DEPTH,
};

const usz TEXT_NUMBER_FORMAT_BYTES @private = 32; // 32 bytes per scalar; fits the longest 64-bit decimal

const uint TEXT_NO_PARENT @private = uint::max;

enum TextKind @private {
    OBJECT,
    ARRAY,
    STRING,
    NUMBER,
    BOOLEAN,
    NIL,
}

<*
 Per-call JSONC limits; raw string lengths include quotes and escapes.
*>
struct TextLimits {
    usz max_bytes;
    usz max_string_bytes;
    usz max_number_bytes;
    uint max_depth;
}

<*
 Owned failure details that survive reader cleanup.
*>
struct SerialDiagnostic {
    Allocator allocator;
    fault cause;
    String pointer;
    usz byte_offset;
    usz line;
    usz byte_column;
    bool has_text_position;
    String node_path;
    String type_name;
    String model_key;
    String asset_key;
    uint template_index;
    bool has_template_index;
    uint bone_index;
    bool has_bone_index;
}

struct TextValue @private {
    TextKind kind;
    uint offset;
    uint length;
    uint parent;
    uint index;
    uint end;
    uint children;
    uint name_offset;
    String name;
    String string;
    bool boolean;
}

struct TextDocument @private {
    Allocator allocator;
    String source;
    TextValue[] values;
    char[] strings;
}

struct TextPathPart @private {
    bool array;
    uint index;
    String name;
    bool raw;
}

struct TextStringWriter @private {
    char* bytes;
    usz length;
}

struct TextParser @private {
    TextDocument* document;
    TextLimits limits;
    SerialDiagnostic* diagnostic;
    usz cursor;
    uint next_value;
    usz next_string;
    uint named_values;
    uint depth;
    uint path_depth;
    TextPathPart[TEXT_MAX_DEPTH] path;
    uint[] names;
    bool storing;
}

<*
 Create an empty caller-owned diagnostic without allocating storage.
 @require allocator.ptr != null
*>
fn SerialDiagnostic create_serial_diagnostic(Allocator allocator) {
    return { .allocator = allocator };
}

<*
 Release retained diagnostic text and clear the record.
 @param [&inout] diagnostic : "Owns its retained text; cleared afterward."
*>
fn void destroy_serial_diagnostic(SerialDiagnostic* diagnostic) {
    clear_serial_diagnostic(diagnostic);
    *diagnostic = {};
}

fn void clear_serial_diagnostic(SerialDiagnostic* diagnostic) @private {
    Allocator allocator = diagnostic.allocator;
    alloc::free(allocator, diagnostic.pointer.ptr);
    alloc::free(allocator, diagnostic.node_path.ptr);
    alloc::free(allocator, diagnostic.type_name.ptr);
    alloc::free(allocator, diagnostic.model_key.ptr);
    alloc::free(allocator, diagnostic.asset_key.ptr);
    *diagnostic = { .allocator = allocator };
}

fn void destroy_text_document(TextDocument* document) @private {
    alloc::free(document.allocator, document.values.ptr);
    alloc::free(document.allocator, document.strings.ptr);
    *document = {};
}

fn bool text_limits_valid(TextLimits limits) @private {
    return limits.max_bytes > 0 && limits.max_bytes <= TEXT_MAX_BYTES
        && limits.max_string_bytes > 0 && limits.max_string_bytes <= TEXT_MAX_BYTES
        && limits.max_number_bytes > 0 && limits.max_number_bytes <= TEXT_MAX_BYTES
        && limits.max_depth > 0 && limits.max_depth <= TEXT_MAX_DEPTH;
}

fn String text_lexeme(TextDocument* document, uint value) @private {
    TextValue* token = &document.values[value];
    return document.source[token.offset:token.length];
}
