# Baked navigation snapshots

`c3d::nav` saves an initialized `NavMesh` to portable bytes and replaces a mesh from those bytes. A snapshot holds the baked geometry, the current polygon flags and areas, the quantized query bounds of coarse tiles, the bounded surface and clearance metadata, and the original off-mesh connections. It needs no scene, renderer or serialization add-on.

[Authored navigation serialization](serialization_reference.md#navigation-and-character) saves `NavSource`, `NavVolume`, `NavLink`, `NavObstacle` and `NavAgent` setup. A baked snapshot is independent of that authoring. File I/O, asset versioning, streaming, builder and cache inputs, agents, crowd state and saved searches belong to the application.

## Quick start

The public operations are `NavMesh.snapshot_size()`, `write_snapshot(output, scratch)`, `read_snapshot(input, scratch, limits)`, `poly_key(ref)` and `resolve_poly_key(key)`.

```c3
usz byte_count = mesh.snapshot_size()!;
char[] bytes = alloc::new_array_try(mem, char, (sz)byte_count)!;
defer free(bytes);
char[] scratch = alloc::new_array_try(mem, char, 32768)!;
defer free(scratch);

NavPolyKey key = mesh.poly_key(selected_polygon)!;
(void)mesh.write_snapshot(bytes, scratch)!;
mesh.read_snapshot(bytes, scratch, {
    .max_blob_bytes   = bytes.len,
    .max_staged_bytes = 8 * 1024 * 1024,
})!;
selected_polygon = mesh.resolve_poly_key(key)!;
```

The scratch size and the staged-byte limit are application budgets, not required sizes. The CPU example `nav_persistence` (`python3 scripts/build.py --example nav_persistence`) builds four tiles with two layers and an off-mesh connection, saves and replaces them, reacquires a polygon and runs a path query, with no scene or GPU.

## Concepts

- **Format version.** `NAV_SNAPSHOT_VERSION` (1) identifies the portable format. It is independent of the native `TileMesh` and `TileData` layouts, which are not portable; the [wire format](navigation_snapshot_format.md) is the contract.
- **What it omits.** No native header, pointer, runtime reference or salt, ownership flag, link, free list, lookup table, native BV node, builder or cache object, query or crowd object.
- **Keys.** A `NavPolyKey` holds the signed tile `x`, `z` and `layer` and an unsigned polygon ordinal. Runtime references change across a load, so save keys and resolve them afterwards.

## Save and load

The caller owns the input, output and scratch bytes. They may begin at any byte address. They and the destination-owned storage must be disjoint, outlive the call and not change concurrently. Call both operations on the owner thread, between mesh and query operations.

**Save.** `write_snapshot` preflights the output and sorting scratch and returns the byte count. The output is unspecified on failure; only the returned prefix of a successful call is a snapshot. `snapshot_size` measures the exact size without allocating.

**Load.** `read_snapshot` retains no input or scratch. It stages all tables and tiles, then replaces the mesh atomically:

- Any fault leaves the original descriptor, owned and borrowed storage, links, flags, queries and currently valid references unchanged.
- Success uses the destination allocator, keeps the destination object's address and its configured tile and link capacities, restores the grid origin and tile dimensions from the file, and releases the old owned storage. Borrowed tile bytes stay the caller's and are neither freed nor overwritten.
- A valid zero-tile snapshot replaces a populated mesh with no resident tiles.
- After success, old `TileRef` and `PolyRef` values and borrowed tile or array pointers are invalid. Reset retained corridors and sliced searches, and reset or recreate a dependent crowd before resuming it. An idle `NavQuery` may keep its pointer to the same mesh object and start fresh queries.

### Choose limits and scratch

`NavSnapshotLimits.max_blob_bytes` bounds the entire input slice. `max_staged_bytes` bounds all concurrently allocated replacement tables, links and native tile bytes, including alignment and rebuilt BV storage. The live destination, the caller's input and output, and the scratch count in addition. The limits count requested payload and padding, not allocator bookkeeping. Capacities and limits do not grow automatically.

Save needs one pointer per resident tile plus the arena's alignment and header space. Load reuses scratch between tiles and between validation and BV reconstruction. A conservative scratch budget for both operations is:

```text
max(
    resident_tile_count * sizeof(pointer),
    16 * largest_BV_enabled_ground_polygon_count,
    16 * next_power_of_two(6 * min(largest_tile_detail_triangle_count, 65534))
) + 64 bytes
```

Treat the third term as zero when there are no detail triangles, and compute the formula with checked arithmetic. The 64 bytes cover the arena header and alignment on supported targets. A smaller fixed budget is valid: insufficient scratch returns a capacity fault, with no temporary or global allocation fallback.

## Faults

| Fault | Meaning |
| --- | --- |
| `INVALID_NAV_SNAPSHOT` | Invalid magic or marker, truncation, overflow, layout, reserved bytes, counts, geometry or topology, precision metadata, or incompatible tile adjacency |
| `INCOMPATIBLE_NAV_SNAPSHOT` | Unsupported portable version or header layout, or a source mesh exceeding the snapshot layer limit |
| `c3d::CAPACITY_EXCEEDED` | Output, scratch, an explicit byte ceiling, the destination tile capacity or a destination allocation could not satisfy the operation |
| `NO_FREE_LINKS` | The complete staged connectivity exceeds the destination link pool |
| `INVALID_REF` | A key conversion or resolution names a missing or stale polygon |

Load validates the complete wire ranges before native allocation, then validates decoded geometry and adjacency before publication. A tile must contain ground polygons; only the whole snapshot may be empty.

## Identify polygons across a load

A key is stable only within the application's same baked-data version. Tile and off-mesh user ids are preserved but need not be unique. Keys do not identify polygons across a new bake, mesh merging or polygon reordering.

A successful replacement advances each destination slot's salt before installing any tile. Every reference valid before the replacement becomes invalid, even when the same tile reuses its slot. Zero salts are skipped. The 16-bit generation history is finite: after enough reuse, an ancient reference can repeat. Removing a restored tile advances its salt as usual.

## Deterministic output

The writer emits little-endian bytes sorted by signed tile X, then Z, then layer, and keeps polygon, vertex, detail and off-mesh order. Equal persisted values produce equal bytes across repeated saves and across save, load and save, independent of slot and salt history, spare capacity, native padding, link and BV node order, and snapped endpoint storage. The BV-enabled setting is retained because the runtime's BV and non-BV query paths can differ. Coarse BV-enabled tiles also keep their polygon-ordered quantized query bounds, which rounded world vertices cannot reliably reproduce; native node topology, unions and escape indices are rebuilt from them, and bounded nodes are rebuilt from geometry.

Both byte orders load, and saving either yields the same canonical little-endian bytes. The format does not canonicalize different bakes and adds no tie-breaking guarantee for equal-cost paths.

## Limits

- At most 32 layers may share one XZ coordinate, matching the runtime's adjacent-layer query capacity. Sizing and writing reject a source above that limit with `INCOMPATIBLE_NAV_SNAPSHOT` before reporting success, and the source stays unchanged.
- `snapshot_size`, `write_snapshot` and `read_snapshot` need a mesh with tile slots (`mesh.tiles.len > 0`).
- A snapshot carries no builder, cache or crowd state.

## See also

- [Wire format](navigation_snapshot_format.md) for tool authors.
- [Navigation](navigation.md) and [navigation grids](navigation_grids.md).
- [Authored navigation serialization](serialization_reference.md#navigation-and-character).
