module c3d::serial;

import c3d;
import c3d::describe;
import c3d::ecs;
import std::io;

struct SchemaState @private {
    JsonOutput* output;
    uint depth;
}

<*
 Write registered component policies, field layouts and semantic defaults.
 @return "Text owned by the supplied allocator."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED, describe::MISSING_DESCRIPTION
*>
fn String? write_schema(Allocator allocator, TextLimits limits = TEXT_LIMITS_DEFAULT) {
    if (!text_limits_valid(limits)) return c3d::INVALID_ARGUMENT~;
    JsonOutput measured = { .writer = measuring_writer(), .limits = limits };
    emit_schema(&measured)!;
    char[] bytes = alloc::new_array_try(allocator, char, (sz)measured.writer.written()) ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch alloc::free(allocator, bytes.ptr);
    JsonOutput output = { .writer = writer_over(bytes), .limits = limits };
    emit_schema(&output)!;
    return (String)bytes;
}

fn void? emit_schema(JsonOutput* output) @local {
    output.begin("", true)!;
    output.unsigned("version", 1)!;
    output.begin("components", false)!;
    uint[ecs::MAX_COMPONENT_TYPES] sorted;
    uint count;
    foreach (slot, entry : codecs) {
        if (!entry.codec.name.len) continue;
        uint position = count++;
        while (position && codecs[sorted[position - 1]].codec.name.compare_to(entry.codec.name) > 0) {
            sorted[position] = sorted[position - 1];
            position--;
        }
        sorted[position] = (uint)slot;
    }
    foreach (slot : sorted[:count]) {
        CodecEntry* entry = &codecs[slot];
        output.begin("", true)!;
        output.string("name", entry.codec.name)!;
        output.unsigned("version", entry.codec.version)!;
        output.boolean("binary_only", entry.described == null)!;
        if (entry.described) {
            output.string("type", entry.described.type.descriptor.name)!;
        } else {
            output.literal("fields", "null")!;
        }
        output.end()!;
    }
    output.end()!;
    output.begin("types", false)!;
    for (DescribedTypeEntry* entry = described_types; entry; entry = entry.next) {
        emit_type_schema(output, &entry.type)!;
    }
    output.end()!;
    output.end()!;
}

fn void? emit_type_schema(JsonOutput* output, DescribedType* type) @local {
    output.begin("", true)!;
    output.string("name", type.descriptor.name)!;
    output.unsigned("version", type.version)!;
    char[TEXT_NUMBER_FORMAT_BYTES] scratch;
    String layout = (String)(io::bprintf(scratch[..], "%016x", type.layout) ?? c3d::CAPACITY_EXCEEDED~!);
    output.string("layout", layout)!;
    output.begin("fields", false)!;
    SchemaState state = { .output = output };
    describe::Visitor visitor = {
        .mode = SCHEMA,
        .field = &schema_output_field,
        .begin = &schema_output_begin,
        .end = &schema_output_end,
        .user = &state,
    };
    describe::walk_descriptor(type.descriptor, &visitor, null)!;
    output.end()!;
    output.begin("defaults", true)!;
    Acquisitions owned = { .allocator = tmem };
    defer owned.release();
    void* value = owned.acquire(1, type.descriptor.size, type.descriptor.alignment)!;
    type.defaults(value);
    write_described_json(
        type: type,
        output: output,
        context: null,
        value: value,
    )!;
    output.end()!;
}

fn void? schema_output_info(JsonOutput* output, describe::Info* info) @local {
    output.string("name", info.name)!;
    output.string("kind", describe::Kind::names[info.kind.ordinal])!;
    output.unsigned("size", info.size)!;
    if (info.kind == STRUCT) {
        DescribedType* type = find_described_type(info.identity)!;
        output.string("type", type.descriptor.name)!;
    }
    if (info.kind == ARRAY) output.unsigned("extent", info.extent)!;
    if (info.metadata.display_name.len) output.string("display_name", info.metadata.display_name)!;
    if (info.metadata.unit.len) output.string("unit", info.metadata.unit)!;
    if (info.metadata.range.enabled) {
        output.begin("range", false)!;
        output.double_bits("", bitcast(info.metadata.range.min, ulong))!;
        output.double_bits("", bitcast(info.metadata.range.max, ulong))!;
        output.end()!;
    }
    if (info.kind == ENUM) {
        output.begin("enum", false)!;
        foreach (name : info.enum_names) output.string("", name)!;
        output.end()!;
    }
    if (info.kind == ASSET) output.string("asset_kind", AssetKind::names[info.metadata.asset_kind.ordinal])!;
}

fn bool? schema_output_field(describe::Visitor* visitor, describe::Info* info, void* value) @local {
    SchemaState* state = visitor.user;
    state.output.begin("", true)!;
    schema_output_info(state.output, info)!;
    state.output.end()!;
    return false;
}

fn bool? schema_output_begin(describe::Visitor* visitor, describe::Info* info, void* value) @local {
    SchemaState* state = visitor.user;
    if (!state.depth++) return true;
    state.output.begin("", true)!;
    schema_output_info(state.output, info)!;
    state.output.begin(info.kind == STRUCT ? "fields" : "element", false)!;
    return true;
}

fn void? schema_output_end(describe::Visitor* visitor, describe::Info* info, void* value) @local {
    SchemaState* state = visitor.user;
    if (!--state.depth) return;
    state.output.end()!;
    state.output.end()!;
}
