module c3d::serial;

import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import std::math;

<* Magic of a portable subtree container. *>
const uint SUBTREE_MAGIC = 0x53443343;

<* Supported subtree container layout. *>
const uint SUBTREE_VERSION = 1;

<* Maximum entries in a portable chunk table. *>
const uint MAX_CHUNKS = 64; // four required kinds plus extensions; at most 2016 overlap comparisons

const usz HEADER_BYTES @private = 24;
const usz CHUNK_ENTRY_BYTES @private = 12;
const uint REQUIRED_CHUNKS @private = 4;
const usz NODE_MIN_BYTES @private = 73;

<* Portable subtree chunk kinds. *>
enum ChunkKind : uint {
    KEYS,
    TYPES,
    NODES,
    COMPONENTS,
}

<* Decoded fixed fields of a subtree container. *>
struct SubtreeHeader {
    uint magic;
    uint version;
    uint byte_count;
    uint node_count;
    uint key_count;
    uint chunk_count;
}

struct ChunkEntry @private {
    uint kind;
    uint offset;
    uint size;
}

struct NodeRecord @private {
    uint parent;
    String name;
    Transform local;
    TransformSpace transform_space;
    uint layers;
    bool visible;
}

struct TypeRecord @private {
    uint slot;
    uint version;
}

struct PayloadView @private {
    uint record;
    uint type;
    char[] bytes;
}

$assert SubtreeHeader::size == HEADER_BYTES;
$assert ChunkEntry::size == CHUNK_ENTRY_BYTES;

<*
 Validate a container header and its chunk ranges.
 @return? c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED
*>
fn SubtreeHeader? read_header(char[] bytes) {
    Reader reader = reader_over(bytes);
    SubtreeHeader header;
    header.magic = reader.read_uint()!;
    header.version = reader.read_uint()!;
    header.byte_count = reader.read_uint()!;
    header.node_count = reader.read_uint()!;
    header.key_count = reader.read_uint()!;
    header.chunk_count = reader.read_uint()!;
    if (header.magic != SUBTREE_MAGIC || header.byte_count != bytes.len || !header.node_count) {
        return c3d::ASSET_FORMAT_ERROR~;
    }
    if (header.version != SUBTREE_VERSION) return c3d::UNSUPPORTED~;
    if (header.chunk_count < REQUIRED_CHUNKS || header.chunk_count > MAX_CHUNKS
        || header.chunk_count > reader.remaining() / CHUNK_ENTRY_BYTES) {
        return c3d::ASSET_FORMAT_ERROR~;
    }
    usz table_end = HEADER_BYTES + (usz)header.chunk_count * CHUNK_ENTRY_BYTES;
    uint required;
    for (uint index = 0; index < header.chunk_count; index++) {
        ChunkEntry entry = read_chunk(&reader)!;
        if (entry.offset < table_end || entry.offset > bytes.len || entry.size > bytes.len - entry.offset) {
            return c3d::ASSET_FORMAT_ERROR~;
        }
        if (entry.kind < REQUIRED_CHUNKS) {
            uint bit = 1u << entry.kind;
            if (required & bit) return c3d::ASSET_FORMAT_ERROR~;
            required |= bit;
        }
        Reader previous = reader_over(bytes[HEADER_BYTES:index * CHUNK_ENTRY_BYTES]);
        for (uint earlier = 0; earlier < index; earlier++) {
            ChunkEntry other = read_chunk(&previous)!;
            if (entry.size && other.size && entry.offset < (usz)other.offset + other.size
                && other.offset < (usz)entry.offset + entry.size) return c3d::ASSET_FORMAT_ERROR~;
        }
    }
    if (required != (1u << REQUIRED_CHUNKS) - 1) return c3d::ASSET_FORMAT_ERROR~;
    return header;
}

fn ChunkEntry? read_chunk(Reader* reader) @private {
    ChunkEntry entry;
    entry.kind = reader.read_uint()!;
    entry.offset = reader.read_uint()!;
    entry.size = reader.read_uint()!;
    return entry;
}

fn void write_header(Writer* writer, SubtreeHeader header) @private {
    writer.write_uint(header.magic);
    writer.write_uint(header.version);
    writer.write_uint(header.byte_count);
    writer.write_uint(header.node_count);
    writer.write_uint(header.key_count);
    writer.write_uint(header.chunk_count);
}

fn void write_chunk(Writer* writer, ChunkEntry chunk) @private {
    writer.write_uint(chunk.kind);
    writer.write_uint(chunk.offset);
    writer.write_uint(chunk.size);
}

fn char[] chunk_bytes(char[] bytes, uint count, ChunkKind kind) @private {
    Reader reader = reader_over(bytes[HEADER_BYTES:count * CHUNK_ENTRY_BYTES]);
    for (uint index = 0; index < count; index++) {
        ChunkEntry chunk = read_chunk(&reader)!!;
        if (chunk.kind == kind.ordinal) return bytes[chunk.offset:chunk.size];
    }
    unreachable();
}
