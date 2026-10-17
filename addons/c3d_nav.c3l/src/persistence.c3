module c3d::nav;

import std::core::mem::allocator;
import std::math;
import std::sort;
import c3d;

<* Portable baked navigation snapshot version. *>
const uint NAV_SNAPSHOT_VERSION = 1;

const char[8] SNAPSHOT_MAGIC @local = { 'C', '3', 'D', 'N', 'A', 'V', 0, 0 };
const uint SNAPSHOT_ENDIAN_MARKER @local = 0x01020304;
const uint SNAPSHOT_SWAPPED_MARKER @local = 0x04030201;
const usz SNAPSHOT_HEADER_BYTES @local = 64;
const usz SNAPSHOT_DIRECTORY_BYTES @local = 32;
const usz SNAPSHOT_TILE_HEADER_BYTES @local = 128;
const usz SNAPSHOT_POLYGON_BYTES @local = 32;
const usz SNAPSHOT_QUERY_BOUNDS_BYTES @local = 12;
const usz SNAPSHOT_VECTOR_BYTES @local = 12;
const usz SNAPSHOT_DETAIL_BYTES @local = 16;
const usz SNAPSHOT_TRIANGLE_BYTES @local = 8;
const usz SNAPSHOT_PORTAL_BYTES @local = 32;
const usz SNAPSHOT_HEADER_PADDING_BYTES @local = 12;
const usz SNAPSHOT_CONNECTION_PADDING_BYTES @local = 7;
const usz SNAPSHOT_CONNECTION_BYTES @local = 48;
const usz SNAPSHOT_ALIGNMENT @local = 8;
const uint SNAPSHOT_BYTE_BITS @local = 8;

$assert char::size == 1 && ushort::size == 2 && uint::size == 4 && ulong::size == 8;
$assert int::size == 4 && float::size == 4 && double::size == 8;
$assert MAX_VERTS_PER_POLY == 6;

<* Bound input bytes and all concurrently staged destination allocations. *>
struct NavSnapshotLimits {
    usz max_blob_bytes;
    usz max_staged_bytes;
}

<* Locate a polygon within the application's same baked-data version. *>
struct NavPolyKey {
    int x;
    int z;
    int layer;
    uint polygon;
}

struct SnapshotReader @local {
    char[] bytes;
    usz offset;
    bool big_endian;
}

struct SnapshotWriter @local {
    char[] bytes;
    usz offset;
}

struct SnapshotHeader @local {
    NavMeshDesc desc;
    uint tile_count;
    bool big_endian;
}

struct SnapshotRecord @local {
    NavPolyKey key;
    usz offset;
    usz length;
}

<*
 Locate a currently resident polygon without retaining its runtime reference.
 @return? INVALID_REF
*>
fn NavPolyKey? NavMesh.poly_key(&self, PolyRef ref) {
    TileAndPoly found = self.tile_and_poly(ref)!;
    return {
        .x = found.tile.header.x,
        .z = found.tile.header.z,
        .layer = found.tile.header.layer,
        .polygon = decode_poly(ref),
    };
}

<*
 Resolve a baked polygon key to a current reference.
 @return? INVALID_REF
*>
fn PolyRef? NavMesh.resolve_poly_key(&self, NavPolyKey key) {
    MeshTile* tile = self.tile_at(key.x, key.z, key.layer);
    if (!tile || key.polygon >= tile.polys.len) return INVALID_REF~;
    return self.poly_ref_base(tile) | (PolyRef)key.polygon;
}

<*
 Measure the exact portable snapshot size without allocating.
 @return? INCOMPATIBLE_NAV_SNAPSHOT, c3d::CAPACITY_EXCEEDED
 @require self.tiles.len > 0
*>
fn usz? NavMesh.snapshot_size(&self) {
    usz size = SNAPSHOT_HEADER_BYTES;
    MeshTile*[MAX_TILES_AT + 1] layers;
    foreach (tile : self.tiles) {
        if (!tile.header) continue;
        if (self.tiles_at(tile.header.x, tile.header.z, layers[..]) > MAX_TILES_AT) {
            return INCOMPATIBLE_NAV_SNAPSHOT~;
        }
        usz? record_size = snapshot_tile_size(tile.header);
        if (catch record_size) return c3d::CAPACITY_EXCEEDED~;
        if (record_size > (usz)sz::max - SNAPSHOT_DIRECTORY_BYTES
            || record_size + SNAPSHOT_DIRECTORY_BYTES > (usz)sz::max - size) {
            return c3d::CAPACITY_EXCEEDED~;
        }
        size += record_size + SNAPSHOT_DIRECTORY_BYTES;
    }
    return size;
}

<*
 Save canonical little-endian bytes into caller-owned output.
 @param [out] output : "Contents are unspecified on failure."
 @param [inout] scratch : "Disjoint caller storage; retained only during this call."
 @return? INCOMPATIBLE_NAV_SNAPSHOT, c3d::CAPACITY_EXCEEDED
 @require self.tiles.len > 0
*>
fn usz? NavMesh.write_snapshot(&self, char[] output, char[] scratch) {
    usz size = self.snapshot_size()!;
    if (output.len < size) return c3d::CAPACITY_EXCEEDED~;
    usz count;
    foreach (tile : self.tiles) if (tile.header) count++;

    ArenaAllocator arena;
    arena.init(scratch);
    MeshTile*[]? ordered = alloc::alloc_array_try(&arena, MeshTile*, (sz)count);
    if (catch ordered) return c3d::CAPACITY_EXCEEDED~;
    usz cursor;
    foreach (&tile : self.tiles) if (tile.header) ordered[cursor++] = tile;
    sort::quicksort(ordered, &compare_snapshot_tiles);

    output[:size] = 0;
    SnapshotWriter writer = { .bytes = output[:size] };
    writer.bytes[:SNAPSHOT_MAGIC.len] = SNAPSHOT_MAGIC[..];
    writer.offset = SNAPSHOT_MAGIC.len;
    writer.integer(SNAPSHOT_ENDIAN_MARKER, uint::size);
    writer.integer(NAV_SNAPSHOT_VERSION, uint::size);
    writer.integer(SNAPSHOT_HEADER_BYTES, uint::size);
    writer.integer(count, uint::size);
    writer.integer(size, ulong::size);
    writer.vector(self.desc.origin);
    writer.real(self.desc.tile_width);
    writer.real(self.desc.tile_height);
    writer.offset = SNAPSHOT_HEADER_BYTES;

    usz record_offset = SNAPSHOT_HEADER_BYTES + count * SNAPSHOT_DIRECTORY_BYTES;
    foreach (tile : ordered) {
        usz length = snapshot_tile_size(tile.header)!!;
        writer.integer(bitcast(tile.header.x, uint), uint::size);
        writer.integer(bitcast(tile.header.z, uint), uint::size);
        writer.integer(bitcast(tile.header.layer, uint), uint::size);
        writer.offset += uint::size;
        writer.integer(record_offset, ulong::size);
        writer.integer(length, ulong::size);
        record_offset += length;
    }

    foreach (tile : ordered) write_snapshot_tile(&writer, tile);
    return size;
}

<*
 Replace every tile atomically and invalidate all current mesh references.
 @param input : "Borrowed snapshot; no bytes are retained."
 @param [inout] scratch : "Disjoint caller storage; no fallback allocation."
 @param limits : "Input and staged allocation byte ceilings."
 @return? INVALID_NAV_SNAPSHOT, INCOMPATIBLE_NAV_SNAPSHOT, c3d::CAPACITY_EXCEEDED, NO_FREE_LINKS
 @require self.tiles.len > 0
*>
fn void? NavMesh.read_snapshot(
    &self,
    char[] input,
    char[] scratch,
    NavSnapshotLimits limits,
) {
    SnapshotHeader header = check_snapshot(self, input, limits)!;
    NavMesh staged = create_nav_mesh(self.allocator, header.desc)!;
    defer catch destroy_nav_mesh(&staged);
    foreach (index, &tile : staged.tiles) {
        uint salt = (self.tiles[index].salt + 1) & ((1u << SALT_BITS) - 1);
        tile.salt = salt ? salt : 1;
    }

    SnapshotReader directory = {
        .bytes = input,
        .offset = SNAPSHOT_HEADER_BYTES,
        .big_endian = header.big_endian,
    };
    for (uint index = 0; index < header.tile_count; index++) {
        SnapshotRecord record = read_snapshot_record(&directory)!;
        char[] data = read_snapshot_tile(
            bytes: input[record.offset:record.length],
            key: record.key,
            big_endian: header.big_endian,
            allocator: self.allocator,
            scratch: scratch,
        )!;
        defer catch alloc::free(self.allocator, data.ptr);
        if (catch excuse = add_validated_tile(
            mesh: &staged,
            data: data,
            flags: { .free_data = true },
            last_ref: (TileRef)0,
        )) {
            return snapshot_load_fault(excuse)~;
        }
    }

    NavMesh previous = *self;
    *self = staged;
    destroy_nav_mesh(&previous);
}

fn void SnapshotWriter.integer(&self, ulong value, usz width) {
    for (usz index = 0; index < width; index++) {
        self.bytes[self.offset++] = (char)(value >> (index * SNAPSHOT_BYTE_BITS));
    }
}

fn void SnapshotWriter.real(&self, float value) => self.integer(bitcast(value, uint), uint::size);

fn void SnapshotWriter.vector(&self, Vec3 value) {
    for (usz axis = 0; axis < 3; axis++) self.real(value[axis]);
}

fn void SnapshotWriter.pad(&self) {
    self.offset = (self.offset + SNAPSHOT_ALIGNMENT - 1) / SNAPSHOT_ALIGNMENT * SNAPSHOT_ALIGNMENT;
}

fn ulong? SnapshotReader.integer(&self, usz width) {
    if (width > self.bytes.len - self.offset) return INVALID_NAV_SNAPSHOT~;
    ulong value;
    for (usz index = 0; index < width; index++) {
        usz shift = (self.big_endian ? width - index - 1 : index) * SNAPSHOT_BYTE_BITS;
        value |= (ulong)self.bytes[self.offset++] << shift;
    }
    return value;
}

fn uint? SnapshotReader.word(&self) => (uint)self.integer(uint::size)!;

fn int? SnapshotReader.signed_word(&self) {
    uint value = self.word()!;
    return bitcast(value, int);
}

fn float? SnapshotReader.real(&self) {
    uint value = self.word()!;
    return bitcast(value, float);
}

fn double? SnapshotReader.precise(&self) {
    ulong value = self.integer(ulong::size)!;
    return bitcast(value, double);
}

fn Vec3? SnapshotReader.vector(&self) {
    Vec3 value;
    for (usz axis = 0; axis < 3; axis++) value[axis] = self.real()!;
    return value;
}

fn void? SnapshotReader.zeros(&self, usz count) {
    if (count > self.bytes.len - self.offset) return INVALID_NAV_SNAPSHOT~;
    foreach (value : self.bytes[self.offset:count]) if (value != 0) return INVALID_NAV_SNAPSHOT~;
    self.offset += count;
}

fn void? SnapshotReader.pad(&self) {
    usz remainder = self.offset % SNAPSHOT_ALIGNMENT;
    if (remainder) self.zeros(SNAPSHOT_ALIGNMENT - remainder)!;
}

fn fault snapshot_load_fault(fault excuse) @local {
    if (excuse == c3d::CAPACITY_EXCEEDED || excuse == NO_FREE_LINKS) return excuse;
    return INVALID_NAV_SNAPSHOT;
}

fn int compare_snapshot_keys(NavPolyKey first, NavPolyKey second) @local {
    if (first.x != second.x) return first.x < second.x ? -1 : 1;
    if (first.z != second.z) return first.z < second.z ? -1 : 1;
    if (first.layer != second.layer) return first.layer < second.layer ? -1 : 1;
    return 0;
}

fn int compare_snapshot_tiles(MeshTile* first, MeshTile* second) @local {
    return compare_snapshot_keys(
        { .x = first.header.x, .z = first.header.z, .layer = first.header.layer },
        { .x = second.header.x, .z = second.header.z, .layer = second.header.layer },
    );
}

fn uint snapshot_query_bounds_count(TileHeader* header) @local {
    return header.detail_mode == DetailMode.COARSE && header.bv_node_count ? header.off_mesh_base : 0;
}

fn usz? snapshot_append_size(usz size, ulong count, usz stride) @local {
    if (count > ((ulong)sz::max - SNAPSHOT_ALIGNMENT + 1) / stride) return INVALID_NAV_SNAPSHOT~;
    usz bytes = (usz)count * stride;
    bytes = (bytes + SNAPSHOT_ALIGNMENT - 1) / SNAPSHOT_ALIGNMENT * SNAPSHOT_ALIGNMENT;
    if (bytes > (usz)sz::max - size) return INVALID_NAV_SNAPSHOT~;
    return size + bytes;
}

fn usz? snapshot_tile_size(TileHeader* header) @local {
    uint ground_vertices = header.vert_count - header.off_mesh_count * 2;
    bool bounded = header.detail_mode == DetailMode.BOUNDED;
    usz size = SNAPSHOT_TILE_HEADER_BYTES;
    size = snapshot_append_size(size, ground_vertices, SNAPSHOT_VECTOR_BYTES)!;
    size = snapshot_append_size(size, header.off_mesh_base, SNAPSHOT_POLYGON_BYTES)!;
    size = snapshot_append_size(size, snapshot_query_bounds_count(header), SNAPSHOT_QUERY_BOUNDS_BYTES)!;
    size = snapshot_append_size(size, bounded ? ground_vertices : 0, SNAPSHOT_VECTOR_BYTES)!;
    size = snapshot_append_size(size, bounded ? header.off_mesh_base : 0, SNAPSHOT_DETAIL_BYTES)!;
    size = snapshot_append_size(size, header.detail_vertex_count, SNAPSHOT_VECTOR_BYTES)!;
    size = snapshot_append_size(size, header.detail_triangle_count, SNAPSHOT_TRIANGLE_BYTES)!;
    size = snapshot_append_size(size, header.detail_portal_count, SNAPSHOT_PORTAL_BYTES)!;
    return snapshot_append_size(size, header.off_mesh_count, SNAPSHOT_CONNECTION_BYTES);
}

fn usz? snapshot_native_size(TileHeader* header) @local {
    uint ground_vertices = header.vert_count - header.off_mesh_count * 2;
    bool bounded = header.detail_mode == DetailMode.BOUNDED;
    usz size = TileHeader::size;
    size = snapshot_append_size(size, header.vert_count, Vec3::size)!;
    size = snapshot_append_size(size, header.poly_count, Poly::size)!;
    size = snapshot_append_size(size, bounded ? ground_vertices : 0, Vec3::size)!;
    size = snapshot_append_size(size, bounded ? header.off_mesh_base : 0, PolyDetail::size)!;
    size = snapshot_append_size(size, header.detail_vertex_count, Vec3::size)!;
    size = snapshot_append_size(size, header.detail_triangle_count, DetailTriangle::size)!;
    size = snapshot_append_size(size, header.detail_portal_count, DetailPortal::size)!;
    size = snapshot_append_size(size, header.bv_node_count, BvNode::size)!;
    return snapshot_append_size(size, header.off_mesh_count, OffMeshConnection::size);
}

fn SnapshotHeader? read_snapshot_header(char[] input, NavMeshDesc destination) @local {
    if (input.len < SNAPSHOT_HEADER_BYTES) return INVALID_NAV_SNAPSHOT~;
    foreach (index, value : SNAPSHOT_MAGIC) if (input[index] != value) return INVALID_NAV_SNAPSHOT~;

    SnapshotReader reader = { .bytes = input, .offset = SNAPSHOT_MAGIC.len };
    uint marker = reader.word()!;
    if (marker != SNAPSHOT_ENDIAN_MARKER && marker != SNAPSHOT_SWAPPED_MARKER) return INVALID_NAV_SNAPSHOT~;
    reader.big_endian = marker == SNAPSHOT_SWAPPED_MARKER;
    if (reader.word()! != NAV_SNAPSHOT_VERSION || reader.word()! != SNAPSHOT_HEADER_BYTES) {
        return INCOMPATIBLE_NAV_SNAPSHOT~;
    }

    uint tile_count = reader.word()!;
    if (reader.integer(ulong::size)! != input.len) return INVALID_NAV_SNAPSHOT~;
    destination.origin = reader.vector()!;
    destination.tile_width = reader.real()!;
    destination.tile_height = reader.real()!;
    reader.zeros(SNAPSHOT_HEADER_PADDING_BYTES)!;

    if (!finite_point(destination.origin) || !math::is_finite(destination.tile_width)
        || !math::is_finite(destination.tile_height)
        || destination.tile_width <= 0 || destination.tile_height <= 0) return INVALID_NAV_SNAPSHOT~;

    return { .desc = destination, .tile_count = tile_count, .big_endian = reader.big_endian };
}

fn SnapshotRecord? read_snapshot_record(SnapshotReader* reader) @local {
    SnapshotRecord record;
    record.key.x = reader.signed_word()!;
    record.key.z = reader.signed_word()!;
    record.key.layer = reader.signed_word()!;
    reader.zeros(uint::size)!;

    ulong offset = reader.integer(ulong::size)!;
    ulong length = reader.integer(ulong::size)!;
    if (offset > reader.bytes.len || length > reader.bytes.len - offset) return INVALID_NAV_SNAPSHOT~;
    record.offset = (usz)offset;
    record.length = (usz)length;
    return record;
}

fn TileHeader? read_snapshot_tile_header(SnapshotReader* reader, NavPolyKey key) @local {
    TileHeader header = {
        .magic = TILE_MAGIC,
        .version = TILE_VERSION,
        .x = key.x,
        .z = key.z,
        .layer = key.layer,
    };
    header.user_id = reader.word()!;
    header.off_mesh_base = reader.word()!;
    uint ground_vertices = reader.word()!;
    header.off_mesh_count = reader.word()!;
    header.detail_vertex_count = reader.word()!;
    header.detail_triangle_count = reader.word()!;
    header.detail_portal_count = reader.word()!;
    uint detail_mode = reader.word()!;
    uint clearance_mode = reader.word()!;
    header.subdivision = reader.word()!;
    uint explicit_corners = reader.word()!;
    uint build_bv_tree = reader.word()!;

    if (detail_mode > (uint)DetailMode.BOUNDED || clearance_mode > (uint)ClearanceMode.SUB_CELL
        || explicit_corners > 1 || build_bv_tree > 1 || header.off_mesh_base == 0
        || (ulong)header.off_mesh_base + header.off_mesh_count >= 1ul << POLY_BITS
        || ground_vertices == 0 || (ulong)ground_vertices + (ulong)header.off_mesh_count * 2 >= MESH_NULL_INDEX
        || (header.off_mesh_count && (ulong)header.off_mesh_base + header.off_mesh_count > MESH_NULL_INDEX)) {
        return INVALID_NAV_SNAPSHOT~;
    }

    header.detail_mode = (DetailMode)detail_mode;
    header.clearance_mode = (ClearanceMode)clearance_mode;
    header.explicit_corners = explicit_corners != 0;
    header.poly_count = header.off_mesh_base + header.off_mesh_count;
    header.vert_count = ground_vertices + header.off_mesh_count * 2;
    header.bv_node_count = build_bv_tree ? header.off_mesh_base * 2 - 1 : 0;

    header.walkable_height = reader.real()!;
    header.walkable_radius = reader.real()!;
    header.walkable_climb = reader.real()!;
    header.bounds.min = reader.vector()!;
    header.bounds.max = reader.vector()!;
    header.bv_quant_factor = reader.real()!;
    header.cell_size = reader.real()!;
    header.source_cell_size = reader.real()!;
    header.clearance_max_error = reader.real()!;
    header.detail_origin = reader.vector()!;
    foreach (&correction : header.detail_origin_correction) *correction = reader.precise()!;

    if (header.detail_mode == DetailMode.COARSE
        && (header.detail_vertex_count || header.detail_triangle_count || header.detail_portal_count)) {
        return INVALID_NAV_SNAPSHOT~;
    }

    return header;
}

fn SnapshotHeader? check_snapshot(NavMesh* destination, char[] input, NavSnapshotLimits limits) @local {
    if (input.len > limits.max_blob_bytes) return c3d::CAPACITY_EXCEEDED~;
    SnapshotHeader header = read_snapshot_header(input, destination.desc)!;
    usz expected = snapshot_append_size(SNAPSHOT_HEADER_BYTES, header.tile_count, SNAPSHOT_DIRECTORY_BYTES)!;
    if (expected > input.len) return INVALID_NAV_SNAPSHOT~;
    if (header.tile_count > destination.tiles.len) return c3d::CAPACITY_EXCEEDED~;

    usz staged_bytes = snapshot_append_size(0, destination.tiles.len, MeshTile::size)!;
    staged_bytes = snapshot_append_size(staged_bytes, destination.lookup.len, MeshTile*::size)!;
    staged_bytes = snapshot_append_size(staged_bytes, destination.links.len, Link::size)!;
    if (staged_bytes > limits.max_staged_bytes) return c3d::CAPACITY_EXCEEDED~;

    SnapshotReader directory = {
        .bytes = input,
        .offset = SNAPSHOT_HEADER_BYTES,
        .big_endian = header.big_endian,
    };
    NavPolyKey previous;
    uint layers;
    for (uint index = 0; index < header.tile_count; index++) {
        SnapshotRecord record = read_snapshot_record(&directory)!;
        if (record.offset != expected || record.length < SNAPSHOT_TILE_HEADER_BYTES
            || (index && compare_snapshot_keys(previous, record.key) >= 0)) return INVALID_NAV_SNAPSHOT~;

        layers = index && previous.x == record.key.x && previous.z == record.key.z ? layers + 1 : 1;
        if (layers > MAX_TILES_AT) return INVALID_NAV_SNAPSHOT~;
        previous = record.key;

        SnapshotReader reader = {
            .bytes = input[record.offset:record.length],
            .big_endian = header.big_endian,
        };
        TileHeader tile = read_snapshot_tile_header(&reader, record.key)!;
        if (snapshot_tile_size(&tile)! != record.length) return INVALID_NAV_SNAPSHOT~;

        usz native_bytes = snapshot_native_size(&tile)!;
        if (native_bytes > limits.max_staged_bytes - staged_bytes) return c3d::CAPACITY_EXCEEDED~;
        staged_bytes += native_bytes;
        expected += record.length;
    }

    if (expected != input.len) return INVALID_NAV_SNAPSHOT~;
    return header;
}

fn void write_snapshot_tile(SnapshotWriter* writer, MeshTile* tile) @local {
    TileHeader* header = tile.header;
    uint ground_vertices = header.vert_count - header.off_mesh_count * 2;
    writer.integer(header.user_id, uint::size);
    writer.integer(header.off_mesh_base, uint::size);
    writer.integer(ground_vertices, uint::size);
    writer.integer(header.off_mesh_count, uint::size);
    writer.integer(header.detail_vertex_count, uint::size);
    writer.integer(header.detail_triangle_count, uint::size);
    writer.integer(header.detail_portal_count, uint::size);
    writer.integer((uint)header.detail_mode, uint::size);
    writer.integer((uint)header.clearance_mode, uint::size);
    writer.integer(header.subdivision, uint::size);
    writer.integer(header.explicit_corners ? 1 : 0, uint::size);
    writer.integer(header.bv_node_count ? 1 : 0, uint::size);
    writer.real(header.walkable_height);
    writer.real(header.walkable_radius);
    writer.real(header.walkable_climb);
    writer.vector(header.bounds.min);
    writer.vector(header.bounds.max);
    writer.real(header.bv_quant_factor);
    writer.real(header.cell_size);
    writer.real(header.source_cell_size);
    writer.real(header.clearance_max_error);
    writer.vector(header.detail_origin);
    foreach (correction : header.detail_origin_correction) writer.integer(bitcast(correction, ulong), ulong::size);

    foreach (vertex : tile.verts[:ground_vertices]) writer.vector(vertex);
    writer.pad();

    foreach (poly : tile.polys[:header.off_mesh_base]) {
        for (usz index = 0; index < MAX_VERTS_PER_POLY; index++) {
            writer.integer(index < poly.vert_count ? poly.verts[index] : 0, ushort::size);
        }
        for (usz index = 0; index < MAX_VERTS_PER_POLY; index++) {
            writer.integer(index < poly.vert_count ? poly.neighbours[index] : 0, ushort::size);
        }
        writer.integer(poly.flags, ushort::size);
        writer.integer(poly.vert_count, char::size);
        writer.integer(poly.area_type.area, char::size);
        writer.offset += uint::size;
    }
    writer.pad();

    uint query_bounds_count = snapshot_query_bounds_count(header);
    if (query_bounds_count) {
        foreach (node : tile.bv_tree) {
            if (node.index < 0) continue;
            SnapshotWriter bounds = {
                .bytes = writer.bytes,
                .offset = writer.offset + (usz)node.index * SNAPSHOT_QUERY_BOUNDS_BYTES,
            };
            foreach (minimum : node.min) bounds.integer(minimum, ushort::size);
            foreach (maximum : node.max) bounds.integer(maximum, ushort::size);
        }
        writer.offset += query_bounds_count * SNAPSHOT_QUERY_BOUNDS_BYTES;
    }
    writer.pad();

    foreach (corner : tile.detail_corners) writer.vector(corner);
    writer.pad();

    foreach (detail : tile.details) {
        writer.integer(detail.vertex_base, uint::size);
        writer.integer(detail.vertex_count, uint::size);
        writer.integer(detail.triangle_base, uint::size);
        writer.integer(detail.triangle_count, uint::size);
    }
    writer.pad();

    foreach (vertex : tile.detail_vertices) writer.vector(vertex);
    writer.pad();

    foreach (triangle : tile.detail_triangles) {
        foreach (vertex : triangle.vertices) writer.integer(vertex, ushort::size);
        writer.integer(triangle.boundary_edges, ushort::size);
    }
    writer.pad();

    foreach (portal : tile.detail_portals) {
        writer.integer(portal.polygon, uint::size);
        writer.integer(portal.edge, uint::size);
        writer.real(portal.min);
        writer.real(portal.max);
        writer.real(portal.source_height);
        writer.real(portal.target_height);
        writer.integer((ushort)portal.kind, ushort::size);
        writer.integer(portal.source_floor, ushort::size);
        writer.integer(portal.target, uint::size);
    }
    writer.pad();

    foreach (connection : tile.off_mesh) {
        writer.vector(connection.start);
        writer.vector(connection.end);
        writer.real(connection.radius);
        writer.integer(connection.user_id, uint::size);
        writer.integer(connection.poly, uint::size);
        Poly* poly = &tile.polys[connection.poly];
        writer.integer(poly.flags, ushort::size);
        writer.integer(poly.area_type.area, char::size);
        writer.integer(connection.flags, char::size);
        writer.integer(connection.side, char::size);
        writer.offset += SNAPSHOT_CONNECTION_PADDING_BYTES;
    }
    writer.pad();
}

fn char[]? read_snapshot_tile(
    char[] bytes,
    NavPolyKey key,
    bool big_endian,
    Allocator allocator,
    char[] scratch,
) @local {
    SnapshotReader reader = { .bytes = bytes, .big_endian = big_endian };
    TileHeader header = read_snapshot_tile_header(&reader, key)!;
    usz size = snapshot_native_size(&header)!;
    char[]? data = alloc::new_array_try(allocator, char, (sz)size);
    if (catch data) return c3d::CAPACITY_EXCEEDED~;
    defer catch alloc::free(allocator, data.ptr);

    *(TileHeader*)data.ptr = header;
    MeshTile tile;
    carve_tile_data(&tile, data);

    uint ground_vertices = header.vert_count - header.off_mesh_count * 2;
    foreach (&vertex : tile.verts[:ground_vertices]) *vertex = reader.vector()!;
    reader.pad()!;

    foreach (&poly : tile.polys[:header.off_mesh_base]) {
        foreach (&vertex : poly.verts) *vertex = (ushort)reader.integer(ushort::size)!;
        foreach (&neighbour : poly.neighbours) *neighbour = (ushort)reader.integer(ushort::size)!;
        poly.flags = (ushort)reader.integer(ushort::size)!;
        poly.vert_count = (char)reader.integer(char::size)!;
        uint area = (uint)reader.integer(char::size)!;
        if (area > WALKABLE_AREA || poly.vert_count > MAX_VERTS_PER_POLY) return INVALID_NAV_SNAPSHOT~;
        poly.area_type = { .area = (char)area, .type = GROUND };
        for (usz index = 0; index < MAX_VERTS_PER_POLY; index++) {
            if (index < poly.vert_count) {
                if (poly.verts[index] >= ground_vertices) return INVALID_NAV_SNAPSHOT~;
            } else if (poly.verts[index] || poly.neighbours[index]) {
                return INVALID_NAV_SNAPSHOT~;
            }
        }
        reader.zeros(uint::size)!;
    }
    reader.pad()!;

    BvNode[] query_bounds = tile.bv_tree[:snapshot_query_bounds_count(&header)];
    foreach (index, &bounds : query_bounds) {
        foreach (&minimum : bounds.min) *minimum = (ushort)reader.integer(ushort::size)!;
        foreach (&maximum : bounds.max) *maximum = (ushort)reader.integer(ushort::size)!;
        bounds.index = (int)index;
    }
    reader.pad()!;

    foreach (&corner : tile.detail_corners) *corner = reader.vector()!;
    reader.pad()!;

    foreach (&detail : tile.details) {
        detail.vertex_base = reader.word()!;
        detail.vertex_count = reader.word()!;
        detail.triangle_base = reader.word()!;
        detail.triangle_count = reader.word()!;
    }
    reader.pad()!;

    foreach (&vertex : tile.detail_vertices) *vertex = reader.vector()!;
    reader.pad()!;

    foreach (&triangle : tile.detail_triangles) {
        foreach (&vertex : triangle.vertices) *vertex = (ushort)reader.integer(ushort::size)!;
        triangle.boundary_edges = (ushort)reader.integer(ushort::size)!;
    }
    reader.pad()!;

    foreach (&portal : tile.detail_portals) {
        portal.polygon = reader.word()!;
        portal.edge = reader.word()!;
        portal.min = reader.real()!;
        portal.max = reader.real()!;
        portal.source_height = reader.real()!;
        portal.target_height = reader.real()!;
        uint kind = (uint)reader.integer(ushort::size)!;
        if (kind > (uint)DetailPortalKind.INTERNAL) return INVALID_NAV_SNAPSHOT~;
        portal.kind = (DetailPortalKind)kind;
        portal.source_floor = (ushort)reader.integer(ushort::size)!;
        portal.target = reader.word()!;
    }
    reader.pad()!;

    foreach (index, &connection : tile.off_mesh) {
        connection.start = reader.vector()!;
        connection.end = reader.vector()!;
        connection.radius = reader.real()!;
        connection.user_id = reader.word()!;
        uint polygon = reader.word()!;
        if (polygon != header.off_mesh_base + index) return INVALID_NAV_SNAPSHOT~;
        connection.poly = (ushort)polygon;
        Poly* poly = &tile.polys[polygon];
        poly.flags = (ushort)reader.integer(ushort::size)!;
        uint area = (uint)reader.integer(char::size)!;
        if (area > WALKABLE_AREA) return INVALID_NAV_SNAPSHOT~;
        poly.area_type = { .area = (char)area, .type = OFF_MESH_CONNECTION };
        connection.flags = (char)reader.integer(char::size)!;
        connection.side = (char)reader.integer(char::size)!;
        reader.zeros(SNAPSHOT_CONNECTION_PADDING_BYTES)!;

        uint vertex = ground_vertices + (uint)index * 2;
        tile.verts[vertex] = connection.start;
        tile.verts[vertex + 1] = connection.end;
        poly.vert_count = 2;
        poly.verts[0] = (ushort)vertex;
        poly.verts[1] = (ushort)(vertex + 1);
    }
    reader.pad()!;
    if (reader.offset != bytes.len) return INVALID_NAV_SNAPSHOT~;

    ArenaAllocator arena;
    arena.init(scratch);
    if (catch excuse = validate_tile_data_scratch(data, &arena)) return snapshot_load_fault(excuse)~;
    arena.clear();
    if (header.bv_node_count) rebuild_tile_bv_tree(&tile, &arena, query_bounds)!;
    return data;
}
