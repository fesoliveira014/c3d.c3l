# Baked navigation snapshots

`c3d::nav` saves an initialized `NavMesh` to portable bytes and replaces a mesh from those bytes. The snapshot includes baked geometry, current polygon flags/areas, bounded surface and clearance metadata, and original off-mesh connections. It needs no scene, renderer or serialization add-on.

[Authored navigation serialization](serialization.md#navigation-adapter) saves NavSource, NavVolume, NavLink, NavObstacle and NavAgent setup. A baked snapshot is independent of that authoring. File I/O, asset versioning, streaming, builder/cache inputs, agents, crowd state and saved searches belong to the application.

## Use and ownership

The public operations are `NavMesh.snapshot_size()`, `write_snapshot(output, scratch)`, `read_snapshot(input, scratch, limits)`, `poly_key(ref)` and `resolve_poly_key(key)`. `NAV_SNAPSHOT_VERSION` identifies the portable format, independently of native TileMesh/TileData versions.

An application with an initialized mesh can save and replace it as follows:

```c3
usz byte_count = mesh.snapshot_size()!;
char[] bytes = alloc::new_array_try(mem, char, (sz)byte_count)!;
defer free(bytes);
char[] scratch = alloc::new_array_try(mem, char, 32768)!;
defer free(scratch);

NavPolyKey key = mesh.poly_key(selected_polygon)!;
(void)mesh.write_snapshot(bytes, scratch)!;
mesh.read_snapshot(bytes, scratch, {
    .max_blob_bytes = bytes.len,
    .max_staged_bytes = 8 * 1024 * 1024,
})!;
selected_polygon = mesh.resolve_poly_key(key)!;
```

The scratch and staged-byte values in the excerpt are application budgets, not universal required sizes. The complete [CPU example](../addons/c3d_nav.c3l/examples/nav_persistence.c3) builds four tiles with two layers and an off-mesh connection, saves/replaces them, reacquires a polygon and runs a path query:

```text
python scripts/build.py --example nav_persistence
```

Use `--measure` on the example executable for bounded save/load timing and allocation accounting. The byte report distinguishes reserved scratch from the smallest successful scratch span for that fixture and excludes allocator bookkeeping, stack and executable storage.

The caller owns input, output and scratch. They may begin at any byte address; the codec reads fields explicitly and aligns decoded native tile storage through the destination allocator. Input/output, scratch, and destination-owned storage must be disjoint. The caller keeps them alive for the call and does not modify them concurrently. Save preflights output and sorting scratch; output contents are unspecified on failure and only the returned successful prefix is a snapshot.

Load retains no input or scratch. Its successful replacement uses the destination allocator and keeps the destination object's address and configured tile/link capacities. Grid origin and tile dimensions are restored from the file. A valid zero-tile snapshot replaces a populated mesh with no resident tiles.

Loading stages all tables and tiles. Any fault leaves the original descriptor, owned/borrowed storage, links, flags, queries and currently valid references unchanged. Success releases the old owned storage; borrowed tile bytes remain the caller's property and are not freed or overwritten.

Call save/load on the owner thread between mesh/query operations. After success, old TileRef/PolyRef values and borrowed tile/array pointers are invalid. Reset retained corridors and sliced searches, and reset/recreate a dependent crowd before resuming it. An idle NavQuery may keep its borrowed pointer to the same mesh object and start fresh queries.

## Bounds and faults

`NavSnapshotLimits.max_blob_bytes` bounds the entire input slice. `max_staged_bytes` bounds all concurrently allocated replacement tables, links and native tile bytes, including alignment and rebuilt BV storage. The already-live destination, caller input/output and scratch are additional simultaneous memory. These ceilings count allocator-requested payload and native tile padding, not allocator bookkeeping or process memory. Capacities and limits do not grow automatically.

Save needs one pointer per resident tile plus the arena's alignment/header space. Load reuses scratch between tiles and between validation and BV reconstruction. For the current runtime, a conservative scratch budget for both operations is:

```text
max(
    resident_tile_count * sizeof(pointer),
    16 * largest_BV_enabled_ground_polygon_count,
    16 * next_power_of_two(6 * min(largest_tile_detail_triangle_count, 65534))
) + 64 bytes
```

Treat the third term as zero when there are no detail triangles and calculate the formula with checked arithmetic. The 64 bytes cover arena header/alignment space on supported targets. A smaller fixed application budget is valid; insufficient scratch returns a capacity fault without a temporary/global allocation fallback.

| Fault | Meaning |
| --- | --- |
| `INVALID_NAV_SNAPSHOT` | Invalid magic/marker, truncation, overflow, layout, reserved bytes, counts, geometry/topology, precision metadata or incompatible tile adjacency. |
| `INCOMPATIBLE_NAV_SNAPSHOT` | Recognized snapshot with an unsupported portable version or header layout. |
| `c3d::CAPACITY_EXCEEDED` | Output/scratch, explicit byte ceiling, destination tile capacity or destination allocation could not satisfy the operation. |
| `NO_FREE_LINKS` | The complete staged connectivity exceeds the destination link pool. |
| `INVALID_REF` | A key conversion/resolution refers to a missing or stale polygon. |

Native TileData bytes are not a portable snapshot. Load validates complete wire ranges before native allocation, then validates decoded geometry and adjacency before publication. A tile must contain ground polygons; only the whole snapshot may be empty. At most 32 layers may share an XZ coordinate, matching the runtime's adjacent-layer query capacity.

## Identity and deterministic output

`NavPolyKey` contains signed `x`, `z`, `layer` and an unsigned polygon ordinal. It is stable only within the application's same baked-data version. Tile and off-mesh user IDs are preserved but need not be unique. Keys do not define identity across a new bake, mesh merging or polygon reordering.

A successful replacement advances each destination slot's salt before installing any tile. Every reference currently valid before replacement becomes invalid, even if the same tile reuses its slot. Zero salts are skipped. The existing 16-bit generation history is finite: after enough reuse, an ancient reference can repeat. Removal of a restored tile advances its salt normally.

The writer emits little-endian bytes, sorted by signed tile X, then Z, then layer. It preserves polygon, vertex, detail and off-mesh ordering. Equal persisted values produce equal bytes across repeated saves and save/load/save, independent of slot/salt history, spare capacity, native padding, link/BV node ordering and snapped endpoint storage. The BV-enabled setting is retained because the runtime's BV and non-BV query paths can differ; BV nodes themselves are rebuilt.

Both marked byte orders load. Saving either yields the same canonical little-endian representation. This does not canonicalize different bakes or add a path tie-breaking guarantee for equal-cost alternatives.

## Version 1 wire layout

Offsets are relative to the beginning of the containing blob or record. Integers are u8/u16/u32/u64 or two's-complement i32. Floats are IEEE binary32/binary64. All multi-byte scalar fields use the byte order selected by the marker; single bytes and magic bytes do not change.

Records and array sections start at relative multiples of eight. The writer zeroes every specified reserved/padding byte. The reader requires exact packed layout and lengths: no duplicate tile keys, overlapping records, ranges inside the header/directory, extra gaps or trailing bytes. It rejects nonzero padding/reserved fields and unsupported enum/flag values.

### Header: 64 bytes

| Offset | Type | Value |
| --- | --- | --- |
| 0 | 8 bytes | ASCII `C3DNAV` followed by two zero bytes. |
| 8 | u32 | `0x01020304`: bytes `04 03 02 01` for little endian, `01 02 03 04` for big endian. |
| 12 | u32 | Portable version: 1. |
| 16 | u32 | Header bytes: 64. |
| 20 | u32 | Resident tile count. |
| 24 | u64 | Exact total blob length. |
| 32 | 3 × f32 | Grid origin X/Y/Z. |
| 44 | f32 | Tile width along X. |
| 48 | f32 | Tile height along Z. |
| 52 | 12 bytes | Zero. |

The directory begins immediately after the header. Each 32-byte entry contains X/Z/layer as three i32 values at offsets 0/4/8, a zero u32 at 12, the record's absolute u64 byte offset at 16 and u64 byte length at 24. Entries are strictly ordered by their coordinate key. Records follow contiguously in that same order.

### Tile metadata: 128 bytes

| Offset | Type | Value |
| --- | --- | --- |
| 0 | u32 | Tile user ID. |
| 4, 8, 12 | u32 each | Ground polygon count, ground vertex count, off-mesh connection count. |
| 16, 20, 24 | u32 each | Detail vertex, triangle and portal counts. |
| 28 | u32 | Detail mode: 0 COARSE, 1 BOUNDED. |
| 32 | u32 | Clearance mode: 0 WHOLE_CELL, 1 SUB_CELL. |
| 36 | u32 | Subdivision. |
| 40 | u32 | Explicit corner state, exactly 0 or 1. |
| 44 | u32 | BV enabled, exactly 0 or 1. |
| 48, 52, 56 | f32 each | Walkable height, radius and climb. |
| 60, 72 | 3 × f32 each | Bounds minimum and maximum. |
| 84 | f32 | BV quantization factor. |
| 88, 92, 96 | f32 each | Cell size, source cell size and clearance maximum error. |
| 100 | 3 × f32 | Detail origin X/Y/Z. |
| 112 | 2 × f64 | Compensated detail-origin X/Z corrections. |

Grid origin/dimensions, active geometry and precision values must be finite and satisfy the runtime's domain/topology rules. Ground polygons precede off-mesh polygons. Total vertices are ground vertices plus two per off-mesh connection; total polygons are ground polygons plus off-mesh count. Counts must fit the current runtime's index/range limits, independently of their wire field width.

### Arrays after the tile metadata

Each row starts after the previous row's bytes rounded up to eight; intervening padding is zero.

| Order | Count | Element |
| --- | --- | --- |
| 1 | Ground vertex count | X/Y/Z as three f32 values, 12 bytes. |
| 2 | Ground polygon count | Ground polygon record, 32 bytes. |
| 3 | Ground vertex count when BOUNDED; zero otherwise | Local detail corner X/Y/Z, 12 bytes. |
| 4 | Ground polygon count when BOUNDED; zero otherwise | Detail range: vertex base/count and triangle base/count as four u32 values, 16 bytes. |
| 5 | Detail vertex count | Local X/Y/Z as three f32 values, 12 bytes. |
| 6 | Detail triangle count | Three u16 local vertex indices and one u16 boundary-edge mask, 8 bytes. |
| 7 | Detail portal count | Detail portal record, 32 bytes. |
| 8 | Off-mesh connection count | Off-mesh record, 48 bytes. |

A ground polygon record contains six u16 vertex indices at 0, six u16 neighbor words at 12, current u16 flags at 24, u8 vertex count at 26, u8 area at 27 and four zero bytes at 28. Inactive vertex/neighbor entries are zero. Active neighbors use 0 for none, polygon ordinal plus one for an internal neighbor, or `0x8000 | side` for a tile portal; valid side values are 0, 2, 4 and 6. Areas range from 0 through 63; zero flags are preserved exactly.

A detail portal contains polygon/edge as u32 at 0/4; accepted interval minimum/maximum and source/target heights as f32 at 8/12/16/20; kind as u16 at 24; source floor as u16 at 26; and target as u32 at 28. Kinds are 0 HEIGHT_BORDER, 1 FLOOR_BORDER and 2 INTERNAL. Target means neighbor floor ordinal for FLOOR_BORDER and polygon ordinal for INTERNAL. Bounds and reciprocal identities follow the current bounded-surface contract.

An off-mesh record contains original start/end X/Y/Z as f32 at 0/12, radius as f32 at 24, user ID as u32 at 28, polygon ordinal as u32 at 32, current polygon flags as u16 at 36, polygon area as u8 at 38, bidirectionality as u8 at 39, side as u8 at 40 and seven zero bytes at 41. Bidirectionality is exactly 0 or 1; side is 0 through 7 or 255 for the same tile. Connection ordinal `i` must refer to polygon `ground_polygon_count + i`. Its two runtime vertices are recreated from the original endpoints and then snapped during linking.

No native header, pointer, runtime ref/salt, ownership flag, link, free list, lookup table, BV node, builder/cache object, query or crowd object is stored.
