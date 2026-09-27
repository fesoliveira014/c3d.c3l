# c3d_nav

Navigation meshes and crowds for c3d: module `c3d::nav`, an add-on package that depends on core
`c3d` only.
Applications select it explicitly; core never imports it.

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

- tile data with its BV tree and off-mesh connections (`dtCreateNavMeshData`), without detail arrays:
  polygon heights come from each polygon's vertex fan, the triangles upstream builds when no detail
  mesh is given;
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

A `NavMesh` from `create_nav_mesh_for(builder)` receives the tiles: `nav_sync` turns every committed
`TileMesh` into a `TileData` blob with `create_tile_data`, adds it with `add_tile` and links it to its
neighbours. `NavLink` components author off-mesh connections; adding, changing (`mark_changed`) or
removing one relinks the tiles under its endpoints without rebuilding them. Every install advances
the tile's salt, so a `PolyRef` into a reinstalled tile stops resolving and is found again with a
nearest-polygon query.

With `NavBuilderDesc.cache_layers`, `build_tile` stops at the heightfield layers and `commit`
stores them in the builder's `TileCache`; `nav_sync` rebuilds mesh tiles from the cached layers
within its budget, marking `NavVolume` areas and obstacles at rebuild time. A volume change then
rebuilds its tiles from the layers without rasterizing again. `NavObstacle` components author
cylinder, box and yawed box obstacles; `mark_changed` re-adds one at the node's current transform,
and removing the component or the node removes the obstacle. A builder without `cache_layers`
skips obstacles and counts them in `NavSyncResult.skipped`.

A `NavQuery` from `create_nav_query(allocator, &mesh, max_nodes)` answers the queries; it allocates
its node pools once and no query allocates. `find_nearest_poly` snaps a point to the mesh,
`find_path` fills a caller slice with the polygon corridor (`partial` when the goal is unreachable,
`truncated` when the slice is short), `straight_path` pulls the corridor into points and marks the
start of each off-mesh connection, and `raycast` walks a straight line along the surface.
`init_sliced_find_path`, `update_sliced_find_path` and `finalize_sliced_find_path` spread one A*
search over several calls; a `NavQuery` runs one sliced search at a time, and the A* and Dijkstra
queries on the same query corrupt it until it is finalized. The local queries serve steering:
`find_polys_around_circle` and `find_polys_around_shape` list the reachable polygons by cost,
`find_local_neighbourhood` the non-overlapping ones, `move_along_surface` slides a point along the
walls, `find_distance_to_wall` and `poly_wall_segments` report the boundary, and
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
`move_along_surface`, and shows `find_distance_to_wall` as a circle around it:

```bash
python3 scripts/build.py --example navmesh
```

With `--cache` the same level builds through cached layers, with a door obstacle that `O` opens
and closes and a crate that becomes an obstacle wherever it stops; the walker reroutes around the
closed door:

```bash
c3c build navmesh --path addons/c3d_nav.c3l && addons/c3d_nav.c3l/build/navmesh --cache
```

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
so a polygon beside a step slopes up to it.

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

## Crowds

A `Crowd` from `create_crowd(allocator, desc, &mesh, scene)` steers up to `desc.max_agents` agents
over the mesh; it allocates every array at creation and `Crowd.update` allocates nothing. Each update
checks corridors, answers move requests with a short sliced search and then the path queue,
shortens corridors, gathers neighbours and walls, steers toward the next corners, samples a velocity
that avoids both, integrates, pushes overlapping agents apart and moves every agent along the
surface. Agents pick one of the crowd's 16 query filters and 8 avoidance configurations by index; a
target further than `CROWD_MAX_PATH` polygons is reached partially.

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

## Tests

`python3 scripts/build.py --test` runs the `nav_test` target, or directly:

```bash
c3c test nav_test --path addons/c3d_nav.c3l
```

The upstream Catch2 sections for rasterization, filtering and `dtMergeCorridorStartMoved` are ported
as tests.
