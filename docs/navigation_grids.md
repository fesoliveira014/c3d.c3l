# Navigation grids

A tile map, a voxel grid or a height field builds navmesh tiles without triangles. The application answers each cell's floors, and `c3d::nav` feeds them into the same heightfield pipeline that scene geometry uses. This page covers grid sources, tile builders, the cached grid coordinator `GridCache`, bounded scene surfaces and sub-cell clearance. The [navigation guide](navigation.md) covers scene-built meshes, queries and crowds.

## Quick start

Describe the floors of a cell, build a tile, and install it. This sketch uses the default grid configuration with a 1 m cell.

```c3
fn usz map_floors(void* context, int cell_x, int cell_z, GridFloor[] out_floors) {
    Map* map = context;
    if (!map.inside(cell_x, cell_z)) return 0;

    out_floors[0] = { .height = map.height_at(cell_x, cell_z), .ceiling = float::max, .area = nav::WALKABLE_AREA };
    return 1;
}

NavBuildConfig config = nav::default_grid_build_config(1.0f);
GridSourceDesc source = {
    .origin     = { 0, 0, 0 },
    .min_height = -1,
    .max_height = 20,
    .floors     = &map_floors,
    .context    = &map,
};
GridTileBuilder tiles = nav::create_grid_tile_builder(mem, config, source)!;
defer nav::destroy_grid_tile_builder(&tiles);
NavMesh mesh = nav::create_nav_mesh(mem, tiles.mesh_desc(9))!;
defer nav::destroy_nav_mesh(&mesh);

char[] tile_mesh = tiles.build(0, 0)!;
mesh.install_tile_mesh(
    tile_mesh:   tile_mesh,
    connections: {},
    params:      {
        .tile_x          = 0,
        .tile_z          = 0,
        .walkable_height = config.agent_height,
        .walkable_radius = config.agent_radius,
        .walkable_climb  = config.agent_max_climb,
        .build_bv_tree   = true,
    },
)!;
```

## Concepts

- **One voxel per cell.** Walls follow cell edges. Erosion trims `ceil(agent_radius / cell_size)` whole cells, and neighbouring floors connect when their height difference is within the agent's climb.
- **Regions.** Regions split where the floor height changes, so each polygon lies on one floor. A vertex on a step takes the higher floor's height, so a polygon beside a step slopes up to it. A grid whose heights differ from cell to cell, such as a height map, yields a region and a polygon per cell in the default `DetailMode.COARSE`. Use [bounded detail](#bounded-scene-surfaces) for such grids.
- **Tiles.** A tile is `NavBuildConfig.tile_size` cells wide plus a border of `TileConfig.border_size` cells that its build reads from the neighbours.
- **Configuration.** `default_grid_build_config(cell_size)` takes the default build configuration with 5 cm floor steps, every island kept and walls on cell edges.

## Describe the floors

An application answers a cell through a `GridFloorsFn` (infallible) or a `GridFloorsTryFn` (returns a fault for a source failure). Each fills up to `MAX_GRID_FLOORS` (16) `GridFloor` values, bottom to top, and returns how many; 0 is an empty or out-of-map cell.

| `GridFloor` field | Meaning |
| --- | --- |
| `height` | World Y of the top of the solid below the surface |
| `ceiling` | World Y of the next solid above; `float::max` when open |
| `area` | `WALKABLE_AREA` or a custom area id below 64; `NULL_AREA` is solid but not walkable |
| `floor_kind`, `ceiling_kind` | `GridSurfaceKind.FLAT` (default) or `CORNERS`; corners need `BOUNDED` |
| `floor_corners`, `ceiling_corners` | Four heights ordered (0,0), (1,0), (1,1), (0,1) in XZ, read under `CORNERS` |
| `diagonal` | `MIN_MIN_TO_MAX_MAX` or `MAX_MIN_TO_MIN_MAX`, shared by the selected corner floor and ceiling |

- Floors must be strictly ordered over the whole cell, including the centre where different diagonals cross. A ceiling below its floor, or cutting through the next floor, is invalid; an equal floor and ceiling is valid blocked geometry. An open flat ceiling is still limited by the next authored floor.
- Whole-cell mode requires each complete cell to pass slope and headroom classification. Sub-cell mode clips the admissible fragments first.
- Shared edges keep only the reciprocal intervals that satisfy climb and headroom, with the minimum rise and a stable floor order resolving competing neighbours. Rejected intervals remain walls for pathfinding, raycasts, local movement and crowd boundaries.
- Zero-initialized kinds are flat, and inactive scalar or corner fields are ignored.

`GridSourceDesc` carries the lattice and the callback:

| Field | Meaning |
| --- | --- |
| `origin` | World XZ of the minimum corner of cell (0, 0); Y is unused |
| `min_height`, `max_height` | World Y range every floor and ceiling lies in |
| `floors` or `capture` | Exactly one of `GridFloorsFn` or `GridFloorsTryFn`; source faults propagate without publication |
| `context` | Passed to the callback |
| `cell_size` | Zero lets a generic floors callback leave the pitch to the build configuration; a nonzero value must match `NavBuildConfig.cell_size` |

## Build and install tiles

`create_grid_tile_builder(allocator, config, source, scratch_bytes = DEFAULT_GRID_SCRATCH_BYTES)` allocates one heightfield and one arena. `GridTileBuilder.build(tile_x, tile_z)` returns the tile's `TileMesh` blob, or an empty blob when nothing is walkable. The blob lives in the arena until the next build, and a build allocates nothing else.

`GridTileBuilder.mesh_desc(max_tiles)` gives the matching `NavMeshDesc`. `NavMesh.install_tile_mesh(blob, connections, params)` replaces the tile at `params.tile_x`, `params.tile_z` and `params.tile_layer`, or only removes it when the blob is empty. It invalidates every `PolyRef` into the replaced tile and faults `NO_FREE_LINKS` without changing the mesh.

When the application edits a cell, it rebuilds the edited cell's tile and every neighbour whose border of `tile_config.border_size` cells reaches the cell. Do this before `crowd_update` in the frame of the edit, so the crowd replans its corridors through the replaced tiles. `grid_dirty_tiles(cells, tile_size, border_size, extent)` selects those tiles.

## Sample a height field

`grid_height_source(&view, min_height, max_height)` adapts a borrowed `GridHeightView` of row-major float vertices. `width` and `height` count vertices, `row_stride` counts samples and must be at least `width`. `origin.xz` is vertex (0, 0), `cell_size` is its pitch, and each world height is `sample * height_scale + height_offset`; origin Y is unused. Select `area` and `diagonal` explicitly. The source lattice must match the navigation grid.

`grid_sampled_source(&sampler, min_height, max_height)` adapts a `GridHeightSampler`. Its fallible callback receives world XZ and returns a `GridHeightSample { height, present }`. Both adapters capture four corners into one open-ceiling floor over the chosen two triangles, so they require `DetailMode.BOUNDED`, and they do not sample continuous features between corners.

- An out-of-array cell, or any missing sampled corner, makes the cell empty. A successful present sample with a non-finite height faults `INVALID_ARGUMENT`. Callback faults stay distinct from absence.
- Captured heights must lie within the declared range.
- Both adapters borrow the view or sampler; keep their metadata fixed while the source is borrowed.

[Terrain](terrain.md#navigation) shows a sampler over a terrain height map.

### Edit ranges

`GridRange` is a half-open range in XZ. `grid_vertex_cells(vertices)` expands changed height vertices to every incident cell. `grid_world_cells(bounds, origin, cell_size)` encloses a closed world-space edit and includes both sides of exact cell boundaries. `grid_dirty_tiles(cells, tile_size, border_size, extent)` selects every configured tile whose full capture window intersects the edited cells, empty and negative coordinates included; pass the actual `TileConfig.border_size`. Empty ranges stay empty, and unrepresentable coordinate expansion faults.

## Cached grid updates

`GridCache` owns a fixed grid extent, detached build slots and one `TileCache`. It needs no scene, native system or worker scheduler. Direct `GridTileBuilder` use stays available.

```c3
GridCacheDesc desc = nav::default_grid_cache_desc(
    { .min_x = 0, .min_z = 0, .max_x = 2, .max_z = 2 },
    config,
);
GridCache grid = nav::create_grid_cache(
    allocator: mem,
    desc:      desc,
    source:    source,
    identity:  (GridSourceId)1,
    revision:  1,
)!;
defer nav::destroy_grid_cache(&grid);
NavMesh mesh = nav::create_nav_mesh(mem, grid.mesh_desc())!;
defer nav::destroy_nav_mesh(&mesh);

grid.mark_dirty({ .min_x = 15, .min_z = 3, .max_x = 16, .max_z = 4 }, 2)!;
GridUpdateResult progress = grid.update(&mesh, 1);
```

- **Creation and budget.** Creation marks every coordinate dirty. Each `update` budget unit attempts one complete XZ source replacement or obstacle rebuild; zero publishes nothing. `GridUpdateResult.pending` counts remaining work, including source jobs and obstacle queues. Repeated edits coalesce.
- **Capacity.** `GridCacheDesc` sets `max_cached_layers`, `build_slots` and the two scratch capacities; `config.tile_size` is at most 255. Exhaustion returns explicit faults, and failed publication stays pending for retry. A held slot can make `capture_next` return `NO_FREE_SLOT`.
- **Identity and revision.** Source identity is application-defined and nonzero. `mark_dirty(cells, revision)` names the current source revision, which never decreases (a lower one faults `INVALID_ARGUMENT`). `set_source(source, identity, revision)` replaces the source and requests the whole extent. It faults `INVALID_ARGUMENT` for a zero identity, for the current identity with a revision that does not exceed the current one, and for a changed origin or declared height range. Job identity, revision and a per-coordinate request generation reject superseded results, so a stale completion cannot overwrite newer resident or pending data. The installed identity and revision are in `tiles`.
- **Atomic publication.** A replacement publishes all layers at one XZ together with the retained source data and the installed revision. A failure keeps every old layer, reference and query link usable. Different coordinates publish independently, so neighbouring tiles may hold different revisions while work drains across frames.
- **Detached builds.** `capture_next()` copies the full source window and halo into an exclusive slot on the owner thread; source descriptors, height arrays and callback contexts are borrowed during that call. `build_grid_cache_job(job)` then runs on a worker using only that copy. The owner calls `commit(job)` after the worker finishes, which returns `GridCommitResult.STAGED` or `STALE`, and `update` publishes staged output. Join outstanding workers before destroying the cache.
- **Obstacles.** `grid.cache.add_obstacle(base, radius, height)`, `add_box_obstacle(box)`, `add_oriented_box_obstacle(centre, half_extents, yaw_radians)` and `remove_obstacle(ref)` queue changes; moving an obstacle is a removal followed by an addition. `grid.update` processes them and shares the source budget. Obstacle-only rebuilds use the retained floors, ceilings, diagonals, labels and halo without calling the source callbacks again. Bounded mode rejects a footprint that touches more than `MAX_TOUCHED_TILES` (8) layers before changing anything; coarse mode marks only the first eight. Obstacle, request and update capacities are fixed.
- **Rebasing.** `GridCache.shift_origin(offset)` moves the cache's own source origin and every world-space layer it holds without rebuilding a tile or changing a dirty mark, revision or request. The source behind the cache belongs to the application: subtract the offset from a `GridHeightSampler.origin` or `GridHeightView.origin` and retake views taken from absolute data. A later `set_source` takes `GridCache.source_origin()` as its origin, because the cache refuses any other. A floors callback that takes cell indices needs nothing on a rebase. A bare `GridTileBuilder` keeps no cache and has no `shift_origin`: move the `origin` of its `source`, or create it again. [Origin rebasing](origin_rebasing.md#navigation-grid-caches) states the order across owners.

## Bounded scene surfaces

Set `NavBuildConfig.detail_mode = DetailMode.BOUNDED` to retain the quantized scene surface inside each polygon. `detail_max_error` is the largest vertical difference in metres from the reference surface, plus a local floating-point allowance of `max(1e-5 m, 32 * FLT_EPSILON * max(1 m, reference height range))`. The default is `DetailMode.COARSE`.

- **Reference.** A four-triangle fan per compact heightfield cell. Its centre uses the span's quantized height; each corner uses the highest incident span connected locally by reciprocal walkable transitions. This is a reconstructed surface, not the original source triangles. Slope and headroom are checked on it before whole-cell erosion. Separate floors keep separate references.
- **Polygon detail.** The builder keeps a coarse polygon fan only when its full reference overlay and boundary profile meet the bound; otherwise it retains clipped reference triangles. `max_detail_vertices` and `max_detail_triangles` bound the storage of a tile (65534 each, which is also the largest accepted value; 0 faults `INVALID_ARGUMENT`). A bounded runtime tile keeps its local coarse vertices as well, 12 bytes per coarse vertex. Insufficient storage, scratch or precision returns `CAPACITY_EXCEEDED`; no coarse fallback is published. Invalid numeric inputs return `INVALID_ARGUMENT`.
- **Atomic replacement.** A failed build, retained-cache replacement or runtime install keeps the previous usable data and stays retryable. `NavBuilder.commit` stages the complete XZ layer set, and `nav_sync` publishes its cache references, revision and runtime tiles together only after every replacement layer succeeds. Cached bounded layers keep the source reference and its halo before erosion; obstacles and area edits change admissibility, not source heights. Neighbouring bounded tiles need a compatible source pitch, agent settings and reciprocal reference identities; incompatible precision data, including coarse next to bounded tiles, is rejected before installation.
- **Queries.** `NavQuery.poly_surface(ref, point)` returns the selected ground triangle's height and upward unit normal. `poly_height`, the closest and nearest queries, random points and off-mesh landings use the same surface, and a supplied polygon reference selects the side at a height step. `poly_surface` rejects an off-mesh reference. `move_along_surface_projected` returns the actual final polygon and projects onto its surface even when the visited slice is truncated; corridor and crowd movement use projected heights. A normal describes the retained triangle; vertical error alone does not bound its angular error. Queries allocate no detail data.
- **Rebasing.** Origin shifts move the detail basis and keep local detail vertices and valid polygon references.

## Sub-cell clearance

Set `clearance_mode = ClearanceMode.SUB_CELL` together with `detail_mode = DetailMode.BOUNDED` and a positive `clearance_max_error` in metres. `WHOLE_CELL` is the default. Any other combination faults `INVALID_ARGUMENT` at build creation.

For an agent radius `r` and error `e`, the output stays inside the radius-clear region and retains the `(r + e)`-clear region before configured small-region removal. A radius of zero uses the same conservative rule and retains at least the `e`-clear region.

- Clearance follows the locally connected floor through reciprocal edge intervals. An unrelated overlapping deck is a separate floor, and off-mesh links do not join clearance regions.
- The builder clips the reference by slope, headroom, blocking areas and obstacles, then admits globally aligned microcells. Their subdivision and a conservative numerical margin consume the error budget. Polygonization keeps the admitted union, and portal endpoints decode to the same stored shared coordinates.
- A capacity or precision failure returns `CAPACITY_EXCEEDED` before replacement; the builder does not reduce the subdivision.
- Scene, retained-cache and authored-grid builds use this policy, and a change to one cached layer still publishes the whole XZ set atomically.
- Neighbouring precision tiles need the same source pitch, subdivision, clearance mode and error.
- The builder scratch capacities also bound fragment clipping, clearance queues and polygonization. Raise `slot_scratch_bytes`, `cache_scratch_bytes` or the grid builder's `scratch_bytes` when a build faults `CAPACITY_EXCEEDED`.

## Strict floating-point math

Precision arithmetic requires IEEE binary64 round-to-nearest operations with gradual underflow. Consumers that use bounded detail or sub-cell clearance select `"fp-math": "strict"` in `project.json`, or pass `--fp-math=strict` to `c3c`. The package's example and test project sets this option.

## Limits

- A cell holds at most `MAX_GRID_FLOORS` (16) floors.
- A source whose declared height range spans 8191 or more voxels (`1 + round((max_height - min_height) / cell_height)`) faults `INVALID_ARGUMENT` at creation; the default `cell_height` of 0.05 m allows about 409 m.
- `set_source` refuses a changed origin or height range; create a new `GridCache` and `NavMesh` to change them.
- Retained cache records are runtime build records with checked versions, not a portable format.

## See also

- [Navigation](navigation.md): scene builds, queries and crowds.
- [Terrain](terrain.md#navigation): a height-map sampler and its edit order.
- [Origin rebasing](origin_rebasing.md#navigation-grid-caches): rebasing across owners.
- The `grid` example (`python3 scripts/build.py --example grid`) builds a tile map with a bridge, steers a crowd and rebuilds the tiles of edited walls (through a `GridCache` with `--cache`).
