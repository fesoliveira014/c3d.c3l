# Terrain reference

Reference for the `c3d::landscape::terrain` module: the desc rules, tile-set types, constants, functions and faults. The [terrain guide](terrain.md) explains how to use them.

## TerrainDesc

`default_terrain_desc()` sets `lod_threshold = 512`, `lod_hysteresis = 0.25`, `morph_band = 0`, `slope_projection = TOP`, `triplanar_sharpness = 4`, both shadow flags and `trace = false`. The maps, scales and layers are the application's. `add_terrain` and `attach_terrain` check every value and fault rather than assert, because descs also come from files.

| Field | Rule |
| --- | --- |
| `height_map` | `R16_UINT`, one mip, 2D, square, `CHUNK_CELLS · 2ⁿ + 1` texels per side: 129, 257, 513, 1025, 2049 or 4097 |
| `control_map` | Optional linear `RGBA8_UNORM` weights of layers 0 to 3 over the whole extent; unset shows layer 0 alone |
| `cell_size` | Metres between texel centres along x and z; positive |
| `height_scale` | Metres at texel 65535: `height = height_scale × texel / 65535`; positive |
| `layers` | Up to four live `STANDARD` materials, leading; zero ids after the last one; layer 0 is required |
| `lod_threshold` | Projected node diameter, in pixels of the view's working extent, above which a node splits; finite, zero or more |
| `lod_hysteresis` | A split node merges below `lod_threshold / (1 + lod_hysteresis)`; finite, zero or more |
| `morph_band` | Share of each selection range over which chunk vertices morph toward their parent level; finite, zero or more, at most `(1 − lod_hysteresis) / 2`. A positive band also needs a `lod_threshold` above zero |
| `slope_projection` | `TOP` projects the layers from above; `TRIPLANAR` along all three axes |
| `triplanar_sharpness` | Exponent of the plane weights, `MIN_TRIPLANAR_SHARPNESS` (1) to `MAX_TRIPLANAR_SHARPNESS` (64), finite; read and checked only under `TRIPLANAR` |
| `cast_shadow`, `receive_shadow` | Copied onto the batch at every `update`; `cast_shadow` also onto the trace grid |
| `trace` | Adds a trace-only grid, so [scene traces](scene_trace.md) see the terrain; baked at preparation |
| `trace_level` | Grid cells span `2^trace_level` texels: 0 is one vertex per texel. Stays below the map's level count (1 at 257 texels, 3 at 1025); read and checked only with `trace`, baked at preparation |

## Tile-set types

| Type | Fields and rule |
| --- | --- |
| `TerrainSet` | On the parent node: `texels`, `cell_size`, `height_scale` shared by every tile. `tile_extent()` is `(texels − 1) · cell_size`. `is_linked(tile)`, `neighbour(tile, direction)` and `propagate_edit(scene, assets, tile, rect)` read and keep the links and seams |
| `TerrainTile` | On each tile: grid coordinates `x`, `z` (signed) |
| `TerrainNeighbour` | `WEST`, `EAST`, `NORTH` (toward lower z), `SOUTH`, `NORTH_WEST`, `NORTH_EAST`, `SOUTH_WEST`, `SOUTH_EAST` |
| `TexelRect` | `x`, `z`, `columns`, `rows` of a height-map region; columns run along x |

[Tile sets](terrain.md#tile-sets) in the guide shows their use.

## Tile rules

`prepare` checks a tile that carries `TerrainTile` and faults `INVALID_ARGUMENT` on any mismatch, leaving it pending and never linked. A tile must:

- be a direct child of a node that carries `TerrainSet`;
- have a height map of exactly the set's `texels`, and the set's `cell_size` and `height_scale`;
- have the same `lod_threshold`, `lod_hysteresis`, `morph_band` and `layers` as every tile already linked;
- have a `PARENT`-space transform relative to the set node that is a pure translation to `(x · tile_extent, 0, z · tile_extent)`, with no rotation and unit scale, within 1e-4;
- not share its `(x, z)` with a linked tile. The first tile prepared at a coordinate keeps it.

Floats compare exactly. Tiles may differ in height map, control map and shadow flags. `prepare` on a prepared tile re-validates and relinks it; on a mismatch it faults, leaves the terrain drawing and leaves the tile unlinked. `TerrainSet.neighbour` returns `NOT_FOUND` for a tile that is not linked or has no linked neighbour in the direction.

## Border ring

A tile shades its edge texels from central differences, so it needs the texel just outside its border. Each tile owns an `R16_UINT` texture of `texels × 4` in material slot 2, one row for each edge neighbour in the order north, south, west and east. A row holds the neighbour's texels one step inside the neighbour's own border; the shared edge is duplicated, so that is the texel outside this tile. `TerrainParams.border_edges` is a four-bit mask of the valid rows.

- The fragment stage reads a ring row only where a central difference crosses a present edge. An edge without a linked neighbour stays one-sided. The ring has no corners.
- `TerrainRuntime.ring_edges` mirrors the mask for CPU reads. `terrain::ring_strips(texels, edges)` returns the one-texel strip along each masked border, the texels whose smooth normals read the ring.
- The ring is created with the tile at `prepare` and removed with its terrain. A terrain without `TerrainTile` has none: slot 2 is empty and the mask is zero. The ring costs 1,032 bytes at 129 texels and 8,200 bytes at 1,025, on the CPU and on the GPU.
- The ring rebuilds from the neighbours' height texels when an edge neighbour links or unlinks; a diagonal link leaves it alone. A tile that leaves its set gets an empty ring. A neighbour whose height map no longer conforms counts as missing.
- `terrain::refresh_neighbour_rings(scene, assets, tile, rect)` rebuilds the rings that read an edit of the tile's texels. It reaches only the neighbours across an edge whose outer two texel bands (the shared edge and the row inside it) the rectangle intersects, and changes a ring's revision only when a texel or the mask changed. `propagate_edit` calls it; call it alone only when the application keeps neighbours' edge texels equal itself.

## Other values

| Type | Meaning |
| --- | --- |
| `HeightView` | Captured texels, side, scales, ring and node matrix for CPU queries |
| `TerrainHeightRange` | `minimum`, `maximum` world heights of a prepared terrain |
| `TerrainCollisionInput` | `height_map`, `scale` (`{ cell_size, height_scale, cell_size }`) and `neighbours` (west, east, north, south) for a collider |
| `BoundsJob` | Snapshot of a detached bounds build: `range_count()`, `run_range(first, count)` |
| `TerrainRuntime` | Written by the library: derived bounds, owned `material`, `border_ring`, `ring_edges`, the refresh log, `trace_grid`, `trace_error` and `drawn_deviation` |

## Functions

| Function | Purpose |
| --- | --- |
| `register_terrain(scene, assets)` | Register the four components and their remove hooks, once per scene |
| `default_terrain_desc()` | Tunables at their defaults with shadows on |
| `add_terrain(scene, assets, node, desc)` | Attach and prepare a terrain |
| `attach_terrain`, `is_prepared`, `prepare`, `prepare_subtree(scene, assets, root = null)` | Split authoring and runtime |
| `update(scene, assets)` | Refresh changed bounds, publish node records, apply LOD and shadow fields |
| `mark_dirty(scene, assets, node, rect)` | Record texels written in place |
| `refreshed_since(scene, node, revision)` | Union of the rectangles refreshed after a revision |
| `height_view(scene, assets, node)` | Capture a `HeightView` |
| `sample_height(view, x, z)`, `sample_normal(view, x, z)`, `sample_smooth_normal(view, x, z)` | CPU height and normals |
| `height_range(scene, node)` | World height range of a prepared terrain |
| `collision_input(scene, node)` | Collider values for a node |
| `ring_strips(texels, edges)`, `refresh_neighbour_rings(scene, assets, tile, rect)` | Border ring helpers |
| `bounds_job(scene, assets, node, scratch)`, `commit_bounds(scene, assets, job)` | Detached bounds build |

## Constants

| Constant | Value | Meaning |
| --- | --- | --- |
| `CHUNK_CELLS` | 128 | Cells per chunk edge at every level |
| `MAX_TERRAIN_LEVELS` | 6 | Quadtree levels, reached at 4097 texels |
| `DEFAULT_LOD_THRESHOLD` | 512 | Split threshold in pixels |
| `DEFAULT_LOD_HYSTERESIS` | 0.25 | Merge hysteresis |
| `REFRESH_HISTORY` | 4 | In-place refreshes the log keeps |
| `MIN_TRIPLANAR_SHARPNESS`, `MAX_TRIPLANAR_SHARPNESS`, `DEFAULT_TRIPLANAR_SHARPNESS` | 1, 64, 4 | Plane-weight exponent range and default |
| `COLLISION_SIDES` | 4 | Collider sides that continue into a tile: west, east, north, south |

## Faults

| Where | Fault | When |
| --- | --- | --- |
| `register_terrain` | `c3d::CAPACITY_EXCEEDED` | No component type slot left |
| `add_terrain` | `c3d::INVALID_ID` | Dead height map, control map or set layer |
| `add_terrain`, `height_view`, `update` | `c3d::UNSUPPORTED` | Height map not `R16_UINT`, not a `MIP_ZERO` source, or a layered, 3D or cube texture |
| `add_terrain` | `c3d::UNSUPPORTED` | Control map not `RGBA8_UNORM` |
| `add_terrain`, `height_view`, `update` | `c3d::INVALID_ARGUMENT` | Not square, a side outside the list, pixel bytes not `side² × 2` |
| `add_terrain` | `c3d::INVALID_ARGUMENT` | A non-positive scale; a negative or non-finite tunable; a `morph_band` outside its limit or positive with a zero `lod_threshold`; a `TRIPLANAR` terrain with a `triplanar_sharpness` outside its range or not finite; a `trace` terrain whose `trace_level` is not below the level count; no layer 0, a layer after an unset one, a layer that is not `STANDARD`; a shared key naming another asset kind |
| `add_terrain`, `prepare` | `c3d::INVALID_ARGUMENT` | A tile that does not match its set, or shares a coordinate with a linked tile |
| `add_terrain`, `prepare`, `update` | `c3d::UNSUPPORTED` | The node carries a `LodGroup` |
| `add_terrain` | `c3d::CAPACITY_EXCEEDED` | Store pool full or an allocation failed |
| `TerrainSet.neighbour` | `NOT_FOUND` | The tile is not linked, or has no linked neighbour in the direction |
| `TerrainSet.propagate_edit` | `c3d::INVALID_ARGUMENT` | The tile is not linked |
| `mark_dirty` | `c3d::INVALID_ID` | The height map was removed |
| `mark_dirty` | `c3d::INVALID_ARGUMENT` | A replacement of another side length is in place |
| `update` | `c3d::INVALID_ID` | The height map was removed |
| `update` | `c3d::INVALID_ARGUMENT` | A revision whose side differs from the accepted one; an edited `lod_threshold` or `lod_hysteresis` that is negative or not finite; an edited `morph_band` outside its limits |
| `sample_height`, `sample_normal`, `sample_smooth_normal` | `NOT_FOUND` | The point is outside the extent |
| `refreshed_since` | `NOT_FOUND` | The log does not reach back to the revision |
| `collision_input` | `c3d::INVALID_ID` | A dead node or a node without `Terrain` |
| `collision_input` | `c3d::UNSUPPORTED` | A world axis length of the node differs from 1 by more than 1e-4 |
| `height_range` | `c3d::INVALID_ID` | A dead node or a node without `Terrain` |
| `height_range` | `terrain::NOT_PREPARED` | A pending terrain |
| `bounds_job` | the faults of `add_terrain` (pending) or `update` (prepared) | The value and height-map checks that precede the leaf bounds |
| `bounds_job` | `c3d::INVALID_ARGUMENT` | A prepared terrain with nothing to rebuild, or with only a `mark_dirty` rectangle |
| `bounds_job` | `c3d::CAPACITY_EXCEEDED` | The scratch allocator failed |
| `commit_bounds` | `landscape::STALE` | A source the job read changed |
| `commit_bounds` | the faults of `prepare` or `update` | The call the commit stands in for |

## See also

- [Terrain](terrain.md), [vegetation](vegetation.md) and [water](water.md).
