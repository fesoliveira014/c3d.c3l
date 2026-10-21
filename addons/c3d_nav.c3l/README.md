# c3d_nav

Navigation meshes and crowds for c3d: module `c3d::nav`, an add-on package that depends on core
`c3d` only.
Applications select it explicitly; core never imports it.

Authored shape fields selected by their kind, link endpoints and radius, and
the seven numeric agent parameters must be finite. `add_nav_*` and serialization
share their validators and retain the existing range rules. These entry points
now reject NaN and infinities previously accepted even though those inputs could
not be used by navigation's grid conversion and motion calculations.
Serialization also requires a finite POSITION target; the void target setters
retain their existing contracts. NONE/VELOCITY targets, inactive shape fields
and node transforms preserve their IEEE values. The complete field/domain table
is in [serialization](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/serialization_reference.md#authored-numeric-domains).

## Port notice

This package is an altered C3 port of [recastnavigation](https://github.com/recastnavigation/recastnavigation)
at commit `9f4ce64` (2026-02-27), by Mikko Mononen and contributors. It is not the original software.
Algorithms, thresholds and iteration order follow upstream; where the port diverges, the c3d
architecture records the decision. The upstream zlib license is in `LICENSE-recastnavigation.txt`.

Ported so far, from Recast:

- heightfield rasterization of triangles and walkable-slope marking (`Recast.cpp`,
  `RecastRasterization.cpp`);
- the low-hanging obstacle, ledge and low-clearance span filters (`RecastFilter.cpp`);
- the compact heightfield with neighbour links (`rcBuildCompactHeightfield`);
- area erosion, the median filter, and box, convex polygon and cylinder area marking, with polygon
  offsetting (`RecastArea.cpp`);
- monotone region partitioning with small-region removal and merging (`rcBuildRegionsMonotone`);
- contour tracing, simplification and hole merging (`RecastContour.cpp`);
- the polygon mesh with tile-border vertex removal and portal edges (`rcBuildPolyMesh`);
- heightfield layers, non-overlapping height slices of a tile (`RecastLayers.cpp`);
- the per-tile configuration, bounds and stage order of RecastDemo's `Sample_TileMesh::buildTileMesh`.

From Detour:

- tile data with its BV tree and off-mesh connections (`dtCreateNavMeshData`); coarse polygon
  heights use the vertex fan, while bounded surfaces use the package's reference/detail arrays;
- the tiled navmesh: tile add and remove, internal, portal and off-mesh links, 64-bit salted refs
  (`DetourNavMesh.cpp` with `DT_POLYREF64`);
- the search node pool and priority queue (`DetourNode.cpp`) and the geometry helpers
  (`DetourCommon.cpp`);
- the query filter with typed pass and cost hooks, and the queries nearest polygon, polygons in a
  box, closest point, closest boundary point, polygon height, A* path, straight path and raycast
  (`DetourNavMeshQuery.cpp`);
- the sliced A* search with its any-angle option and both finalizes, the circle and shape Dijkstra
  searches and the path read back from them, local neighbourhood, move along surface, distance to
  wall, polygon wall segments and random points (`DetourNavMeshQuery.cpp`). The any-angle shortcut
  ray crosses up to 32 polygons, where upstream passes an empty path that stops it at the first;
  `find_random_point` weights every polygon of the mesh by area, where upstream first picks a tile
  uniformly.
- the tile cache: layer regions, contours and polygon mesh, cylinder, box and yawed box area
  marking (`DetourTileCacheBuilder.cpp`), and the cache of layers with obstacles, its request and
  rebuild queues and the budgeted update (`DetourTileCache.cpp`). Layers are stored uncompressed.

From DetourCrowd:

- the path corridor and its three merges (`DetourPathCorridor.cpp`), the local boundary
  (`DetourLocalBoundary.cpp`), velocity sampling on a grid and in adaptive rings against circles
  and wall segments (`DetourObstacleAvoidance.cpp`), the proximity grid (`DetourProximityGrid.cpp`),
  the round-robin path queue (`DetourPathQueue.cpp`) and the crowd update with its validity,
  request, topology, neighbour, corner, off-mesh, steering, avoidance, integration, collision and
  traversal phases (`DetourCrowd.cpp`). An agent added to a freed slot drops that slot's off-mesh
  traversal, where upstream carries it over; the adaptive pattern of an even division count stores
  its last sample in the slot it counts, where upstream writes one slot past it; the debug info names
  an agent by its crowd slot, where upstream compares its place in the active list; a queued path
  cut short by the slot's capacity reports `partial`.

Not ported: `rcContext` logging and timers (failures are faults), the unsigned-short and flat-list
rasterization overloads, `rcCalcBounds` (merge `Aabb` values instead), watershed and layer regions
(`rcBuildRegions`, `rcBuildLayerRegions`), the distance field (`rcBuildDistanceField`), the detail
mesh (`RecastMeshDetail.cpp`), `rcMergePolyMeshes` and `rcCopyPolyMesh`; from Detour, the 32-bit ref
split, single-tile `dtNavMesh::init`, tile state save and restore (`storeTileState`,
`restoreTileState`), endian swapping, the batched `dtPolyQuery` overload of `queryPolygons`, the
tile cache's compressor and allocator interfaces, and layer save and load; from DetourCrowd, the
parallel arrays of `dtObstacleAvoidanceDebugData`, which an `AvoidanceSample` slice replaces.

Without an upstream counterpart: the grid source (`GridTileBuilder`), which feeds the floors of a
tile map or voxel grid into the same heightfield instead of rasterizing triangles, and the contour
flag `refine_region_edges` it builds with, which keeps the corners of edges between regions as
upstream keeps those of walls.

## Building a navmesh

Author `NavSource` components on mesh nodes (`Scene.add_nav_source`, or `add_nav_sources` for a
subtree) and `NavVolume` components for area marking, after `register_nav`. A `NavBuilder` covers
world bounds with tiles; `nav_sync` applies source additions, `mark_changed` edits and removals, then
rasterizes, builds and commits up to a budget of tiles on the calling thread. One builder serves a
scene: it installs remove hooks on the nav mirrors, so removing a node that carries a source or a
volume dirties its tiles at the next sync. `build_tile` touches
only its slot, so an application may call `sync_sources` and `rasterize_next` on the main thread,
run `build_tile` on workers and `commit` back on the main thread. Each tile's result is a flat
`TileMesh` blob read through `tile_mesh_view`.

A `NavSource` follows the revision of its geometry. `sync_sources` treats a moved revision (an edit
published with `mark_geometry_dirty`, `mark_geometry_streams_dirty` or `mark_geometry_range_dirty`, or a
`replace_geometry`) as a changed source: it dirties the old and new bounds and
restarts a tile job in progress. A `NavMesh` the application built keeps its tiles until it rebuilds them.

A `NavMesh` from `create_nav_mesh_for(allocator, builder, max_links)` receives the tiles: `nav_sync`
turns every committed `TileMesh` into a `TileData` blob with `create_tile_data`, adds it with
`add_tile` and links it to its neighbours. Internal, portal and off-mesh links come from one
mesh-owned pool sized by `NavMeshDesc.max_links` (24 bytes per `Link`), which defaults to
`DEFAULT_LINKS_PER_TILE` (4096) per tile slot; `free_links` reports the remaining capacity. A large
or streamed world sets `max_links` to its resident budget, sized from `NO_FREE_LINKS`. Every
qualifying polygon edge across a tile border gets a portal link in both directions, with `Link.min`
and `Link.max` normalized along the source edge. Coarse links preserve the legacy 255-step
quantization; bounded links retain accepted float intervals without that quantization.
An install that needs more links than are free faults `NO_FREE_LINKS` and leaves the mesh
unchanged; a failed `install_tile_mesh` over a resident tile keeps the resident tile and its links.
`NavLink` components author off-mesh connections; adding, changing (`mark_changed`) or removing one
relinks the tiles under its endpoints without rebuilding them. Every install advances the tile's
salt, so a `PolyRef` into a reinstalled tile stops resolving and is found again with a
nearest-polygon query.

With `NavBuilderDesc.cache_layers`, `build_tile` stops at the heightfield layers and `commit`
stores them in the builder's `TileCache`; `nav_sync` rebuilds mesh tiles from the cached layers
within its budget, marking `NavVolume` areas and obstacles at rebuild time. A volume change then
rebuilds its tiles from the layers without rasterizing again. `NavObstacle` components author
cylinder, box and yawed box obstacles; `mark_changed` re-adds one at the node's current transform,
and removing the component or the node removes the obstacle. A builder without `cache_layers`
skips obstacles and counts them in `NavSyncResult.skipped`.

A `NavQuery` from `create_nav_query(allocator, &mesh, max_nodes, max_edge_links)` answers the
queries; it allocates its node pools and per-edge portal scratch (`DEFAULT_EDGE_LINKS` = 64, at
least 1) once and no query allocates. `find_nearest_poly` snaps a point to the mesh, `find_path`
fills a caller slice with the polygon corridor (`partial` when the goal is unreachable, `truncated`
when the slice is short), `straight_path` pulls the corridor into points and marks the start of each
off-mesh connection, and `raycast` walks a straight line along the surface. `init_sliced_find_path`,
`update_sliced_find_path` and `finalize_sliced_find_path` spread one A* search over several calls; a
`NavQuery` runs one sliced search at a time, and the A* and Dijkstra queries on the same query
corrupt it until it is finalized. The local queries serve steering: `find_polys_around_circle` and
`find_polys_around_shape` list the reachable polygons by cost, `find_local_neighbourhood` the
non-overlapping ones, `move_along_surface` slides a point along the walls, `find_distance_to_wall`
and `poly_wall_segments` report the boundary (treating a border edge as a wall only when no link on
it passes the filter, and faulting `CAPACITY_EXCEEDED` in `move_along_surface` and
`poly_wall_segments` when an edge has more passable links than `max_edge_links`), and
`find_random_point` and `find_random_point_around_circle` draw points weighted by area through a
caller's `RandomFn`.
A `QueryFilter` from `default_query_filter` passes every built polygon; applications set area costs,
flags or `pass` and `cost` hooks, embedding `QueryFilter` as an `inline` first member to carry their
own data.

The `navmesh` example builds a level of ramps, a stair, walls, a movable platform and a mud volume
and draws tiles, polygons, links and the spans of the slot being rasterized. A walker follows the
straight path to a clicked goal, across tiles and up a two-way link onto the platform; `L` makes
that link one-way, and a walk down reroutes through a second, one-way link. `R` switches the walker
to wandering: it draws goals with `find_random_point_around_circle`, steps toward them with
`move_along_surface_projected`, and shows `find_distance_to_wall` as a circle around it:

```bash
python3 scripts/build.py --example navmesh
```

With `--cache` the same level builds through cached layers, with a door obstacle that `O` opens
and closes and a crate that becomes an obstacle wherever it stops; the walker reroutes around the
closed door:

```bash
c3c build navmesh --path addons/c3d_nav.c3l && addons/c3d_nav.c3l/build/navmesh --cache
```

## Bounded scene surfaces

Set `NavBuildConfig.detail_mode = DetailMode.BOUNDED` to retain the quantized scene surface
inside each polygon. `detail_max_error` is the maximum vertical difference in metres from that
reference, plus floating-point allowance. The default remains `DetailMode.COARSE`.
The local vertical allowance is `max(1e-5 m, 32 * FLT_EPSILON * max(1 m, reference height range))`;
it is separate from `detail_max_error`.

The reference is a four-triangle fan per compact heightfield cell. Its center uses the span's
quantized height; each corner uses the highest incident span connected locally by reciprocal
walkable transitions. This defines a reconstructed heightfield surface; it does not preserve the
original source triangle surface. Reconstructed slope and headroom are checked before whole-cell
erosion. Separate floors keep separate references.

The builder keeps a coarse polygon fan only when its full reference overlay and boundary profile
meet the bound. Otherwise it retains clipped reference triangles. `max_detail_vertices` and
`max_detail_triangles` bound tile storage, with defaults of 65534 each. Insufficient storage,
scratch space or representable precision returns `CAPACITY_EXCEEDED`; no coarse fallback is
published. Invalid selected numeric inputs return `INVALID_ARGUMENT`. A failed build, retained
cache replacement or runtime install preserves the previous usable data and remains retryable.
For a cached source replacement, `NavBuilder.commit` stages the complete XZ layer set.
`nav_sync` publishes its cache references, revision and runtime tiles together only after every
replacement layer succeeds. Failure preserves every old cache and runtime layer at that XZ,
including layers that a successful replacement removes. Other XZ coordinates commit independently.
Cached rebuild budgets count complete XZ sets; an obstacle or link rebuild also replaces all layers
at its coordinate together. Pending source products own their copied blobs until publication or
supersession; runtime staging temporarily owns every replacement layer's payload.

Cached bounded layers retain the source reference and its halo before erosion. Obstacles and
area edits change admissibility; they do not overwrite source heights. Neighboring bounded tiles
require compatible source pitch, agent settings and reciprocal reference identities. Incompatible
precision data, including unsupported coarse/bounded adjacency, is rejected before installation.
`TileMesh`, runtime tile and cached-layer blobs carry checked versions; old layouts are rejected.

`NavQuery.poly_surface(ref, point)` returns the selected ground triangle's height and upward unit
normal. `poly_height`, closest/nearest queries, random points and off-mesh landings use the same
surface. A normal describes the retained triangle; vertical error alone does not bound its angular
error. A supplied polygon reference selects the side at a height step. `poly_surface` rejects an
off-mesh reference; `poly_height` retains its segment interpolation.

`move_along_surface_projected` returns the actual final polygon and projects onto its surface even
when the visited slice is truncated. `move_along_surface` preserves its existing Y behavior.
Ordinary corridor and crowd movement uses projected heights; driven-agent positions and off-mesh
animation keep their existing owners. Queries allocate no detail data. Origin shifts move the
detail basis and preserve local detail vertices and valid polygon references. Bounded runtime
tiles retain local coarse vertices as well, adding 12 bytes per coarse vertex. Their compensated
XZ basis preserves logical grid alignment across shifts; coordinate conversion to world floats
has a separate scale-dependent ULP allowance and does not increase the vertical detail budget.
Each `PathCorridor` reserves a second `max_path` array for atomic movement, adding 8 bytes per
path entry.

The `navmesh` and `crowd` examples accept `--detail`. Add `--cache` for cached scene construction;
the crowd example defaults to cached construction and accepts `--direct` for comparison. Their
panels display the selected height and geometric normal and can draw retained triangles.
Each example reserves 131072 debug segments (4 MiB of vertices) for the complete detailed scene
and diagnostic overlays; its panel reports the previous frame's emitted and dropped segments.
`--frames N` closes either example after N frames.

## Sub-cell clearance

Set `clearance_mode = ClearanceMode.SUB_CELL` with `detail_mode = DetailMode.BOUNDED` and a
positive `clearance_max_error` in metres. `WHOLE_CELL` remains the default. For agent radius `r`
and error `e`, the output stays inside the radius-clear region and retains the `(r + e)`-clear
region before configured small-region removal. Clearance follows the locally connected floor
through reciprocal edge intervals. An unrelated overlapping deck is a separate floor; off-mesh
links do not join these clearance regions.

The builder clips the reference by slope, headroom, blocking areas and obstacles, then admits
globally aligned microcells. Their subdivision and conservative numerical margin consume the
requested error budget. Polygonization keeps the admitted union, and portal endpoints decode to
the same stored shared coordinates. A capacity or precision failure returns `CAPACITY_EXCEEDED`
before replacement; it does not reduce the subdivision. Radius zero uses the same conservative
rule and retains at least the `e`-clear region.

Scene, retained-cache and authored-grid builds use this policy. Cached obstacles and NULL-area
volumes use their convex footprints or exact cylinder cross sections. Cached layers keep the
complete source halo and floor labels needed for rebuilding. Changing one layer still publishes
the whole XZ replacement set atomically. Neighboring precision tiles require the same source
pitch, subdivision, clearance mode and error.

Precision arithmetic requires IEEE binary64 round-to-nearest operations with gradual underflow.
Consumers select `"fp-math": "strict"` in their `project.json`, or pass `--fp-math=strict` to
`c3c`. The package's example and test project sets this option. The existing builder scratch
capacities also bound fragment clipping, clearance queues and polygonization; callers can increase
`slot_scratch_bytes`, `cache_scratch_bytes`, or the grid builder's `scratch_bytes` when needed.

## Grid sources

A tile map or a voxel grid builds navmesh tiles without triangles. The application answers each
cell's floors through a `GridFloorsFn` over its own storage: up to `MAX_GRID_FLOORS` floors, bottom
to top, each a height, a ceiling (`float::max` when open) and an area; a `NULL_AREA` floor is solid
but not walkable. `create_grid_tile_builder(allocator, default_grid_build_config(cell_size),
source)` allocates one heightfield and one arena, and `GridTileBuilder.build(tile_x, tile_z)`
returns the tile's `TileMesh` blob, which stays in the arena until the next build; a build
allocates nothing else. One voxel is one grid cell, so walls follow cell edges, erosion trims
`ceil(agent_radius / cell_size)` whole cells and neighbouring floors connect when their height
difference is within the climb. Regions split where the floor height changes, so each polygon lies
on one floor; a vertex on a step takes the higher floor's height, as upstream's corner heights do,
so a polygon beside a step slopes up to it. A grid whose heights differ from cell to cell, like a
heightmap, therefore yields a region and a polygon per cell and pays for it in polygon count.
These are the `DetailMode.COARSE` defaults.

In `BOUNDED`, `GridFloor.floor_kind` and `ceiling_kind` independently select `FLAT` or `CORNERS`.
The four corner values are ordered `(0,0), (1,0), (1,1), (0,1)`. `diagonal` selects
`MIN_MIN_TO_MAX_MAX` or `MAX_MIN_TO_MIN_MAX` for both selected corner surfaces. The chosen two
triangles are the reference; their heights are not quantized to `cell_height`. Zero-initialized
kinds remain flat, and inactive scalar or corner fields are ignored. An open flat ceiling is
still limited by the next authored floor.

Floors must be strictly ordered over the entire cell, including the center where different
diagonals cross. A ceiling below its floor or cutting through the next floor is invalid. Equal
floor and ceiling is valid blocked geometry. Whole-cell mode requires each complete cell to pass
slope and headroom classification; sub-cell mode clips the admissible fragments first. Shared
edges keep only reciprocal intervals satisfying climb and headroom, with minimum rise and stable
floor order resolving competing neighbors. Rejected intervals remain walls for pathfinding,
raycasts, local movement and crowd boundaries.

`GridSourceDesc` selects exactly one callback: `floors` for `GridFloorsFn`, or `capture` for the
fallible `GridFloorsTryFn`. Both receive the same caller context. Source faults propagate without
publication. A nonzero `GridSourceDesc.cell_size` must match the build configuration; zero leaves
pitch selection to a generic floors callback.

`grid_height_source(&view, min_height, max_height)` adapts a borrowed `GridHeightView` of row-major
float vertices. `width` and `height` count vertices; `row_stride` counts samples and must be at
least `width`. `origin.xz` is vertex `(0,0)`, `cell_size` is its pitch, and each world height is
`sample * height_scale + height_offset`; origin Y is unused. Select `area` and `diagonal`
explicitly. The source lattice must match the navigation grid. Resampling uses the sampler API.

`grid_sampled_source(&sampler, min_height, max_height)` adapts a `GridHeightSampler`. Its fallible
callback receives world XZ and produces `GridHeightSample { height, present }`, with height in
world units. Both adapters capture four corners into one open-ceiling floor using the chosen two
triangles, so they require `DetailMode.BOUNDED`. They do not sample or bound continuous features
between those corners. An out-of-array cell or any missing sampled corner makes a cell empty;
a successful present sample with a non-finite height returns `INVALID_ARGUMENT`. Captured heights
must also lie within the declared height range. Callback faults remain distinct from absence.

`GridRange` is half-open in XZ. `grid_vertex_cells` expands changed height vertices to every incident
cell. `grid_world_cells` encloses a closed world-space edit and includes both sides of exact cell
boundaries. `grid_dirty_tiles` selects every configured tile whose full capture window intersects
the edited cells, including empty coordinates and negative coordinates; pass the actual
`TileConfig.border_size`. Empty ranges stay empty and unrepresentable coordinate expansion faults.

`NavMesh.install_tile_mesh(blob, connections, params)` replaces the tile at `params.tile_x`,
`params.tile_z` and `params.tile_layer`, or only removes it when the blob is empty, and
`GridTileBuilder.mesh_desc` gives the matching mesh layout. The application knows its edits, so it
rebuilds the tiles an edit touches: the edited cell's tile and every neighbour whose border of
`tile_config.border_size` cells reaches the cell. The frame of an edit builds and installs those
tiles before `crowd_update`, which replans the corridors through the replaced tiles.

The `grid` example builds a 48 by 48 cell map of 3 by 3 tiles with walls, terraces, two stairs and
a bridge over a corridor, and steers ten crowd agents. A click sends every agent to the point;
Ctrl+click on the ground or on a wall toggles a wall cell, rebuilds and reinstalls its tiles, and
the panel shows how many tiles the edit rebuilt and how long it took:

```bash
python3 scripts/build.py --example grid
```

With `--fan-in` a wide hall polygon in one tile faces 16 alternating step strips across the tile
border, and the agents cross into the neighbouring tile past the fourth strip:

```bash
c3c build grid --path addons/c3d_nav.c3l && addons/c3d_nav.c3l/build/grid --fan-in
```

`grid --detail` enables the authored-surface patch and its plane/ramp/saddle, diagonal,
sloped-ceiling and narrow-passage controls. The camera starts above that patch. Changing a
surface control updates its geometry and rebuilds the affected navigation tiles.
`grid --sub-cell` also enables bounded clearance. `--radius R` and `--clearance-error E`
set its build parameters at startup; `--frames N` limits the run. For example:

```bash
addons/c3d_nav.c3l/build/grid --sub-cell --radius 0.6 --clearance-error 0.5
```

The `navmesh` and `crowd` examples also accept `--sub-cell`, which enables bounded detail
and clearance together. Their panels show both error settings. Each example supplies an
explicit scratch budget for the selected demonstration; the library's fixed capacity
rules still apply.

## Cached grid updates

`GridCache` owns a fixed grid extent, detached build slots and one `TileCache`. It does not require
a Scene, native system or worker scheduler. Direct `GridTileBuilder` construction remains available.

```c3
GridCacheDesc desc = nav::default_grid_cache_desc(
    { .min_x = 0, .min_z = 0, .max_x = 2, .max_z = 2 }, config);
GridCache grid = nav::create_grid_cache(
    allocator: mem,
    desc: desc,
    source: source,
    identity: (GridSourceId)1,
    revision: 1,
)!;
defer nav::destroy_grid_cache(&grid);
NavMesh mesh = nav::create_nav_mesh(mem, grid.mesh_desc())!;
defer nav::destroy_nav_mesh(&mesh);

grid.mark_dirty({ .min_x = 15, .min_z = 3, .max_x = 16, .max_z = 4 }, 2)!;
GridUpdateResult progress = grid.update(&mesh, 1);
```

Creation marks every coordinate dirty. Each `update` budget unit attempts one complete XZ source
replacement or obstacle rebuild; zero publishes nothing. `pending` counts remaining work, including
source jobs and obstacle queues, rather than unique coordinates. Repeated edits coalesce. Set
`max_cached_layers` for all resident layers, `build_slots` for detached concurrency, and both scratch
capacities for the selected build configuration. Exhaustion returns explicit faults, and failed
publication remains pending for retry. A held slot can cause `capture_next` to return `NO_FREE_SLOT`.

Source identity is application-defined and nonzero. `mark_dirty(cells, revision)` names the current
source revision, which never decreases. `set_source(source, identity, revision)` replaces the source
and requests the entire extent; its origin and declared height bounds must stay unchanged, and
`source_origin()` reads the origin after a shift. Job
identity, revision and per-coordinate request generation reject superseded results. The installed
identity and revision are available in `tiles`; stale completion cannot overwrite newer resident
or pending data.

Source descriptors, height arrays and callback contexts are borrowed during owner-thread capture.
Keep adapter metadata fixed and source data stable during that call. `capture_next` copies the full
source window and halo into an exclusive slot. `build_grid_cache_job(job)` may then run on a worker
using only that copied data and its slot scratch. The owner calls `commit(job)` after the worker
finishes. A successful commit stages output; owner-thread `update` publishes it. Join outstanding
workers before destroying the coordinator. Source changes and live mesh publication stay on the
owner thread; they do not modify a worker's captured data.

A replacement publishes all layers at one XZ together with retained source data and installed
revision. Failure keeps every old layer, reference and query link usable, including layers that a
successful replacement removes. Different coordinates publish independently, so neighboring tiles
may have different revisions while work drains across frames.

Add and remove obstacles through `grid.cache.add_obstacle`, `add_box_obstacle`,
`add_oriented_box_obstacle` and `remove_obstacle`; movement is removal followed by addition. Process
these requests through `grid.update`, sharing the source update budget. Obstacle-only rebuilds use
retained authored floors, ceilings, diagonals, labels and halo without rereading source callbacks.
Source publication applies the same cache's current obstacle state. Bounded mode preserves the
existing eight-touched-layer limit and rejects oversized footprints before mutation; coarse mode
keeps its existing footprint limit. Obstacle, request and update capacities remain fixed.
Retained grid obstacle selection includes agent height and the consumed source border in both modes,
matching runtime marking and erosion. Ordinary coarse heightfield caches retain their existing selection.
Retained grid cache records use checked source kind and version 103. These are runtime build records,
not a portable persistence format.

The grid example's `--cache` mode routes wall and authored-patch edits through this coordinator,
updates at budget one before the crowd, and offers obstacle add/move/remove controls. Its overlay
colors queued, applied and removing obstacle bounds; the panel shows pending work and failed attempts.
The direct mode and existing detail, clearance and fan-in flags remain available.

`--cache-demo` runs the existing 8 by 8 authored patch as four 4 by 4 coordinates, with a second floor
on a narrow bridge. It adds, moves and removes a box obstacle on frames 24, 48 and 72, edits a border
cell on frame 96, and raises a shared height vertex on frame 120. It uses one slot, budget one and a
fixed crowd step, printing events, progress and final installed revisions. It defaults to 160 frames;
`--frames` overrides that limit. The example enables Vulkan validation.

```bash
addons/c3d_nav.c3l/build/grid --cache-demo --sub-cell --radius 0.6 --clearance-error 0.5 --frames 160
```

## Baked snapshots

`NavMesh.snapshot_size`, `write_snapshot` and `read_snapshot` save baked tiles and current polygon
state to portable bytes, then replace an initialized mesh atomically. The caller owns byte buffers
and bounded scratch; replacement uses the mesh allocator and configured capacities. Resolve saved
`NavPolyKey` values after loading because runtime references change.

See [baked navigation snapshots](../../docs/navigation_persistence.md) for the wire format, ownership,
limits and query-state reset contract. The `nav_persistence` CPU example demonstrates save, replacement,
key resolution and querying without a scene or GPU.

## Crowds

A `Crowd` from `create_crowd(allocator, desc, &mesh, scene)` steers up to `desc.max_agents` agents
over the mesh; it allocates every array at creation and `Crowd.update` allocates nothing. Each update
checks corridors, answers move requests with a short sliced search and then the path queue,
shortens corridors, gathers neighbours and walls, steers toward the next corners, samples a velocity
that avoids both, integrates, pushes overlapping agents apart and moves every agent along the
surface. Agents pick one of the crowd's 16 query filters and 8 avoidance configurations by index; a
target further than `CROWD_MAX_PATH` polygons is reached partially, and a polygon whose border edge
is split by many portals caps its local boundary contribution at `MAX_SEGMENTS_PER_POLY` (18) wall
segments.

Agents live on nodes: `Scene.add_nav_agent` authors a `NavAgent`, `set_nav_target`,
`set_nav_velocity` and `clear_nav_target` request motion, and `crowd_update` adds and frees crowd
slots to match the components, steps the crowd and writes each node's position in parent space.
One crowd serves a scene: it installs the remove hook of `CrowdAgentRuntime`, so removing an agent's
node frees its slot at the next `crowd_update`. A `NavAgent` marked `driven` keeps its node's
position: the crowd reads it every update and steers through `CrowdAgent.velocity`, which the
application applies to the node itself.

The `crowd` example builds the navmesh level through cached layers and spawns 40 agents on random
points, each drawing a new random goal every few seconds. A click sends every agent to the point,
or selects the agent clicked; `O` closes the door between the two walls, a tile cache obstacle, and
the agents reroute around the walls; `C` draws the corridors, and the panel shows the selected
agent's state, corners and avoidance samples:

```bash
python3 scripts/build.py --example crowd
```

## Rebasing the origin

After `Scene.shift_origin(offset)`, each navigation owner the application has takes the same offset
(horizontal only, `offset.y == 0`), between frames and after `Scene.update_world`:

```c3
nav_mesh.shift_origin(offset);       // grid origin and resident tiles; every PolyRef stays valid
builder.shift_origin(offset);        // bounds, tile records, cached layers, obstacles, queued removals, jobs
crowd.shift_origin(offset);          // agents, corridors, boundaries, traversals, path requests, queries
grid_cache.shift_origin(offset);     // source origin, cached and staged layers, obstacles, captured jobs
scene.shift_navigation(offset);      // runtime mirrors and POSITION targets
```

Join tile builds on other threads before `NavBuilder.shift_origin` and workers before
`GridCache.shift_origin`. A sliced search in progress on a query the application holds is moved with
`NavQuery.shift_origin`; the crowd moves its own queries. `ProximityGrid` is rebuilt every update and
needs nothing.

A `GridCache` moves the origin of its own source copy and every world-space layer it holds, without
rebuilding a tile or changing a dirty mark, revision or request. The source behind it belongs to the
application. A `GridHeightSampler` or `GridHeightView` keeps world coordinates: subtract the offset from
its `origin`, and retake views taken from absolute data. A floors callback that takes cell indices needs
nothing. A later `set_source` takes `GridCache.source_origin()` as its origin, because the cache refuses
any other. A bare `GridTileBuilder` keeps no cache: move the `origin` of its `source`, or retake the source.

Pass multiples of 256 m, the step of the large-world rebase, so origins stay exactly representable. Other
offsets also work, within float rounding. See [large worlds](../../docs/large_world.md#navigation-grid-caches)
for the order across all owners.

## Tests

`python3 scripts/build.py --test` runs the `nav_test` target, or directly:

```bash
c3c test nav_test --path addons/c3d_nav.c3l
```

The upstream Catch2 sections for rasterization, filtering and `dtMergeCorridorStartMoved` are ported
as tests.
