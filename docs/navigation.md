# Navigation

The `c3d_nav` add-on (`addons/c3d_nav.c3l`, module `c3d::nav`) builds navigation meshes from scene geometry, answers path and surface queries over them, and steers crowds of agents. It is a port of Recast, Detour and DetourCrowd; [the port page](navigation_recast_port.md) lists what is ported. The module imports the standard library and core (`c3d`), never `gpu`, `sdl`, `imgui`, `b3` or `c3d::physics`. Core never imports it and has no navigation flag; the package's serialization adapter compiles only under `C3D_NAV_SERIAL`.

The shape fields that a volume's or obstacle's `kind` selects, a link's endpoints and radius, and the seven numeric agent parameters (`radius`, `height`, `max_acceleration`, `max_speed`, `collision_query_range`, `path_optimization_range`, `separation_weight`) must be finite; inactive shape fields keep any IEEE value. `add_nav_*` and serialization share the validators; the domain table is in [serialization](serialization_reference.md#authored-numeric-domains).

Tile maps, voxel grids and height fields build through [grid sources](navigation_grids.md). A baked mesh saves and loads through [snapshots](navigation_persistence.md).

## Quick start

Select `c3d_nav` in `project.json` as [release.md](release.md) lists. The example builds one navmesh over the scene's meshes and plans a path.

```c3
nav::register_nav(&scene)!;
scene.add_nav_sources(scene.root); // one walkable source per Mesh node

NavBuilderDesc desc = nav::default_nav_builder_desc(
    bounds: { .min = { -50, -1, -50 }, .max = { 50, 10, 50 } },
);
NavBuilder builder = nav::create_nav_builder(mem, &scene, desc)!;
defer nav::destroy_nav_builder(&builder);
NavMesh mesh = nav::create_nav_mesh_for(mem, &builder)!;
defer nav::destroy_nav_mesh(&mesh);
NavQuery query = nav::create_nav_query(mem, &mesh, 2048)!;
defer nav::destroy_nav_query(&query);

// each frame, until result.pending is 0
scene.update_world();
NavSyncResult result = nav::nav_sync(
    builder: &builder,
    mesh:    &mesh,
    scene:   &scene,
    assets:  &assets,
    budget:  8,
);

QueryFilter filter = nav::default_query_filter();
NearestPoly start = query.find_nearest_poly(from, { 1, 2, 1 }, &filter)!;
NearestPoly goal = query.find_nearest_poly(to, { 1, 2, 1 }, &filter)!;
PolyRef[256] corridor;
PathResult path = query.find_path(
    start_ref: start.ref,
    end_ref:   goal.ref,
    start:     start.point,
    end:       goal.point,
    filter:    &filter,
    out_path:  corridor[..],
)!;
StraightPoint[64] points;
PathResult straight = query.straight_path(
    start:      start.point,
    end:        goal.point,
    path:       corridor[:path.count],
    out_points: points[..],
)!;
```

Destroy the builder before the scene: it installs remove hooks on the scene.

## Concepts

- **Tiles.** A `NavBuilder` covers world `bounds` with square tiles of `NavBuildConfig.tile_size` voxels (32 by default) and builds each from the geometry that overlaps it. The tile count is fixed at creation. `default_nav_build_config()` gives a 0.3 m by 0.2 m voxel and a 2 m tall agent of radius 0.6 m that climbs 0.9 m and walks slopes up to 45 degrees.
- **NavMesh.** Tiles of convex polygons (at most `MAX_VERTS_PER_POLY`, 6, vertices) with links across tile borders and off-mesh connections. A polygon has `flags` (a `ushort`) and an `area` from 0 to 63; `NULL_AREA` (0) is not walkable and `WALKABLE_AREA` (63) is the default. `NavMesh.set_poly_flags`, `poly_flags`, `set_poly_area` and `poly_area` read and write them.
- **Ids and salts.** `PolyRef` and `TileRef` are 64-bit generational ids. Every tile install and removal advances the slot's salt, so a `PolyRef` into a reinstalled tile stops resolving: `NavMesh.is_valid_ref` returns false and queries fault `INVALID_REF`. Find the polygon again with `find_nearest_poly`, or resolve a saved [polygon key](navigation_persistence.md#identify-polygons-across-a-load).
- **Query and crowd.** A `NavQuery` owns its node pools and answers every query without allocating. It holds its search state, so one thread uses it at a time; give each thread its own query over the same mesh while no thread changes the mesh. A `Crowd` steers agents over one mesh and allocates every array at creation.

## Build a navmesh

Author components on nodes, then let `nav_sync` build and install the tiles.

| Component | Role | Add with |
| --- | --- | --- |
| `NavSource` | Geometry rasterized into the mesh. The zero `geometry` id names the node's `Mesh`; `walkable` false rasterizes every triangle as `NULL_AREA`; `area` marks walkable triangles | `Scene.add_nav_source(node, geometry, walkable, area)`; `Scene.add_nav_sources(root, area)` adds one per `Mesh` node under `root` and returns the count |
| `NavVolume` | Area marking in node space: `BOX`, `CONVEX` (3 to `MAX_VOLUME_VERTS`, 12, vertices between `min_y` and `max_y`) or `CYLINDER` | `Scene.add_nav_volume(node, volume)` |
| `NavLink` | An off-mesh connection between two points in node space, searched for landing polygons within `radius`; `flags` 0 means `POLY_FLAG_WALK`; `bidirectional`, `area`, `user_id` | `Scene.add_nav_link(node, link)` |
| `NavObstacle` | A `CYLINDER`, `BOX` or `ORIENTED_BOX` (turned by the node's yaw) that blocks walking. Needs `cache_layers` | `Scene.add_nav_obstacle(node, obstacle)` |

Each `add_nav_*` faults `INVALID_ARGUMENT` for a value outside its domain and `SOURCE_EXISTS`, `VOLUME_EXISTS`, `LINK_EXISTS` or `OBSTACLE_EXISTS` when the node already carries the component. A `NavSource` without geometry needs a `Mesh` on its node.

Call `mark_changed()` on a component after moving its node or editing it; nothing else notices. A `NavSource` follows the revision of its geometry on its own, so an edit published with `AssetStore.mark_geometry_dirty`, `mark_geometry_streams_dirty` or `mark_geometry_range_dirty`, or an `AssetStore.replace_geometry`, rebuilds the tiles under it. Removing a component or its node dirties its tiles at the next sync. One builder serves a scene because it installs those remove hooks.

### Create the builder and mesh

`default_nav_builder_desc(bounds, config)` gives two build slots with 2 MiB of scratch each, 16 volumes per tile and no triangle budget. `create_nav_builder(allocator, scene, desc)` allocates tiles, slots and pools once and faults `INVALID_ARGUMENT` for a bad config or bounds and `CAPACITY_EXCEEDED` for an allocation failure. `create_nav_mesh_for(allocator, builder, max_links = 0)` creates a mesh whose tile grid matches the builder's.

The `NavBuilderDesc` fields are `config`, the world `bounds` the tiles cover, `slots` (tile builds in flight), `slot_scratch_bytes` (the arena of one slot; a tile that needs more faults `CAPACITY_EXCEEDED`), `initial_spans` (the span pool of each slot), `max_volumes_per_tile` (a tile that overlaps more volumes faults `CAPACITY_EXCEEDED`), `rasterize_budget` (triangles per `rasterize_next` call; 0 is unlimited) and `cache_layers` with `max_obstacles`, `cache_scratch_bytes` and `expected_layers_per_tile` ([cached layers](#cached-layers)).

### Sync

`nav_sync(builder, mesh, scene, assets, budget)` applies the scene's source, volume, link and obstacle changes, builds up to `budget` tiles on the calling thread, and installs every built tile into the mesh. Call it after `Scene.update_world`. It invalidates every `PolyRef` into a reinstalled tile. It returns a `NavSyncResult`:

| Field | Counts |
| --- | --- |
| `built` | Tiles rasterized, built and committed |
| `installed` | Tiles added to the mesh, relinks included |
| `pending` | Dirty tiles and unpublished cached source products |
| `skipped` | Sources with released or non-triangle geometry, and obstacles on a builder without `cache_layers` |
| `failed` | Builds, installs, rebuilds or rasterizations that faulted; `builder.last_failure` names the last tile, stage and fault |
| `relayered` | Cached layers rebuilt into the mesh |

A failed tile keeps its previous mesh and retries at the next sync.

To build on worker threads, drive the builder by hand on the main thread: call `builder.sync_sources(&scene, &assets)`, which returns nothing, then `builder.rasterize_next(&scene, &assets)`. `rasterize_next` returns a `TileJob*` that is `READY` when the tile is rasterized, or `RASTERIZING` when `rasterize_budget` ran out (call it again to continue that slot first). It faults `NO_DIRTY_TILES`, `NO_FREE_SLOT` or `CAPACITY_EXCEEDED`. Run `build_tile(job)` on any thread for a `READY` job (it touches only its slot), and call `builder.commit(job)` on the main thread for the `BUILT` or `FAILED` job. For a builder without `cache_layers`, a later `nav_sync` with `budget` 0 installs the committed tiles. `NavBuilder.mark_dirty(Aabb)` requests a rebuild of the tiles under a box, and `NavBuilder.tile_mesh(tile_x, tile_z)` returns a tile's built `TileMesh` blob, which `tile_mesh_view(blob)` borrows as arrays.

### Link pool

Internal, portal and off-mesh links come from one pool in the mesh, sized by `NavMeshDesc.max_links`. It defaults to `DEFAULT_LINKS_PER_TILE` (4096) per tile slot at 24 bytes per `Link`. A large or streamed world sets `max_links` to its resident budget. `NavMesh.free_links()` reports the remaining capacity. An install that needs more links than are free faults `NO_FREE_LINKS` and leaves the mesh unchanged, and a failed `install_tile_mesh` over a resident tile keeps that tile and its links.

Every polygon edge across a tile border that qualifies gets a portal link in both directions. Adding, changing or removing a `NavLink` relinks the tiles under its endpoints without rebuilding them.

### Cached layers

With `NavBuilderDesc.cache_layers`, `build_tile` stops at the heightfield layers and `commit` stores them in the builder's `TileCache`. `nav_sync` then rebuilds mesh tiles from the cached layers within its budget, marking `NavVolume` areas and obstacles at rebuild time. A volume change rebuilds its tiles from the layers without rasterizing again, and `NavSyncResult.relayered` counts the rebuilds.

- `NavObstacle` components author obstacles. `mark_changed` re-adds an obstacle at the node's current transform; removing the component or the node removes it. A builder without `cache_layers` skips obstacles and counts them in `NavSyncResult.skipped`.
- The layer cache and the mesh each hold `expected_layers_per_tile` (4 by default) slots per tile in total, as one pool shared across tiles. A `commit` that finds the cache pool full faults `CAPACITY_EXCEEDED`, and the tile retries.
- A tile (`tile_size` plus its border) may be at most 255 cells wide; `create_nav_builder` faults `INVALID_ARGUMENT` past that.
- One obstacle marks at most `MAX_TOUCHED_TILES` (8) layers. Coarse mode marks only the first eight; bounded mode rejects an oversized footprint before changing anything.
- Obstacle requests queue between updates (`MAX_OBSTACLE_REQUESTS`, 64) and wait while a rebuild is queued.

[Grid sources](navigation_grids.md#cached-grid-updates) use the same cache without a scene.

## Query paths

`create_nav_query(allocator, &mesh, max_nodes, max_edge_links = DEFAULT_EDGE_LINKS)` allocates the node pools and the per-edge portal scratch once (`DEFAULT_EDGE_LINKS` is 64). `max_nodes` and `max_edge_links` are at least 1. A query takes a `QueryFilter` pointer and caller slices for its results; no query allocates.

| Query | Result |
| --- | --- |
| `find_nearest_poly(center, half_extents, filter)` | The nearest passing polygon in a box, its closest point and whether the point lies over it; `NO_POLY` when none |
| `query_polygons`, `closest_point_on_poly`, `closest_point_on_poly_boundary`, `poly_height`, `poly_surface` | Polygons in a box; points and heights on a polygon; the selected ground triangle's height and upward unit normal |
| `find_path(start_ref, end_ref, start, end, filter, out_path)` | An A* corridor of polygons. `PathResult.partial` is set when the goal is unreachable, `truncated` when the slice is short |
| `straight_path(start, end, path, out_points, options)` | The corridor pulled into `StraightPoint` values; `off_mesh_connection` marks the start of a connection |
| `raycast` | A walkability ray along the surface in XZ |
| `init_sliced_find_path`, `update_sliced_find_path(max_iterations)`, `finalize_sliced_find_path`, `finalize_sliced_find_path_partial` | One A* search spread over several calls; `FindPathOptions.any_angle` adds raycast shortcuts |
| `find_polys_around_circle`, `find_polys_around_shape`, `path_from_dijkstra_search`, `find_local_neighbourhood` | Reachable polygons by cost, a path read back from the search, and the non-overlapping neighbourhood |
| `move_along_surface`, `move_along_surface_projected` | Slide a point along the walls and return the final polygon; the projected form also snaps to the polygon surface |
| `find_distance_to_wall`, `poly_wall_segments` | The nearest wall, and a polygon's boundary segments |
| `find_random_point`, `find_random_point_around_circle` | A point weighted by polygon area, drawn through a caller `RandomFn` that returns [0, 1); `find_random_point` is linear in the polygon count |

- **Sliced searches.** A `NavQuery` runs one sliced search at a time. Any A* or Dijkstra query on the same query before `finalize_sliced_find_path` corrupts it. The filter passed to `init_sliced_find_path` must outlive the search.
- **Wall queries.** `move_along_surface`, `move_along_surface_projected`, `find_distance_to_wall` and `poly_wall_segments` fault `CAPACITY_EXCEEDED` when an edge has more passable links than `max_edge_links`. A border edge is a wall only when no link on it passes the filter.
- **Surfaces.** `poly_surface` and the projected move return the retained ground triangle; with [bounded detail](navigation_grids.md#bounded-scene-surfaces) the surface follows the scene to within the configured error.

### Filters

`default_query_filter()` passes every polygon with a nonzero flag (built polygons carry `POLY_FLAG_WALK`) at cost 1 per metre. A polygon whose flags were set to 0 fails every filter. A `QueryFilter` has:

| Field | Meaning |
| --- | --- |
| `include`, `exclude` | A polygon passes when its flags share a bit with `include` and none with `exclude` |
| `area_cost` | Cost per metre by area id. Keep values at 1 or more so the A* heuristic stays admissible |
| `pass` | Optional `PassFn` that may reject a polygon the flags allowed |
| `cost` | Optional `CostFn` that replaces distance times the area cost |

An application embeds `QueryFilter` as an `inline` first member of its own struct to reach its data from the hooks.

## Run a crowd

`create_crowd(allocator, desc, &mesh, scene)` creates a crowd for `CrowdDesc.max_agents` agents (at most `MAX_CROWD_AGENTS`, 16383) and a `max_agent_radius` that sizes its placement queries. One crowd serves a scene because it installs the remove hook of `CrowdAgentRuntime`. Destroy it before the scene.

Agents live on nodes:

```c3
scene.add_nav_agent(node, nav::default_nav_agent_params())!;
scene.set_nav_target(node, destination);

// every frame, after scene.update_world()
nav::crowd_update(&scene, &crowd, delta_seconds);
```

- `Scene.add_nav_agent(node, params)` authors a `NavAgent`; `AGENT_EXISTS` when the node has one. `set_nav_target(node, position)` asks the agent to walk to a world position, snapped to the mesh at the next update. `set_nav_velocity(node, velocity)` asks it to move at a velocity, and `clear_nav_target(node)` stops it.
- `crowd_update(scene, crowd, dt, debug = null)` removes agents whose node lost its `NavAgent`, adds a crowd slot for each new `NavAgent` (counting the ones that did not fit in `crowd.unbound`), steps the crowd, and writes each non-driven node's position in parent space. `dt` is positive.
- A `NavAgent` marked `driven` keeps its node's position. The crowd reads the position every update and steers through `CrowdAgent.velocity`; the application applies that velocity to the node itself.
- A target farther than `CROWD_MAX_PATH` (256) polygons is reached partially. Each agent's corridor holds two `CROWD_MAX_PATH` `PolyRef` arrays (8 bytes per entry, 4 KiB), the second for atomic movement. An agent chooses one of the crowd's 16 query filters (`Crowd.filter(index)`) and 8 avoidance configurations (`set_obstacle_avoidance_params(index, params)`) by index in its params.
- Removing an agent's node frees its slot at the next `crowd_update`.

Applications that manage agents without nodes call `Crowd.add_agent`, `update_agent_params`, `remove_agent`, `request_move_target`, `request_move_velocity` and `reset_move_target`, then `Crowd.update(dt, debug)`.

## Rebase the origin

After `Scene.shift_origin(offset)` and `Scene.update_world`, between frames, every navigation owner the application has takes the same offset. The offset is horizontal (`offset.y == 0`).

```c3
mesh.shift_origin(offset);         // grid origin and resident tiles; every PolyRef stays valid
builder.shift_origin(offset);      // bounds, tile records, cached layers, obstacles, queued removals, jobs
crowd.shift_origin(offset);        // agents, corridors, boundaries, traversals, path requests, queries
grid_cache.shift_origin(offset);   // see navigation_grids.md
scene.shift_navigation(offset);    // runtime mirrors and POSITION targets
```

Join tile builds on other threads before `NavBuilder.shift_origin`, and cache workers before `GridCache.shift_origin`. A sliced search in progress on a query the application holds moves with `NavQuery.shift_origin`; the crowd moves its own queries. Pass multiples of 256 m, the step of the large-world rebase, so origins stay exactly representable; other offsets work within float rounding. [Large worlds](large_world.md#navigation-grid-caches) states the order across all owners.

## Serialization

Select `c3d_serial`, enable `C3D_NAV_SERIAL` and call `nav::register_serial_codecs()` next to `register_nav`. The adapter saves the authored components and rebuilds the runtime mirrors on `nav_sync` and `crowd_update`. See [serialization](serialization_reference.md#navigation-and-character).

## Limits

- The builder's bounds, tile size and tile count are fixed at creation. A mesh holds `max_tiles` tile slots; with `cache_layers` the builder reserves `expected_layers_per_tile` per tile.
- One builder and one crowd serve a scene. A `NavQuery` runs one sliced search at a time.
- Obstacles need `cache_layers`.
- Bounded detail and sub-cell clearance need strict floating-point math ([grid sources](navigation_grids.md#strict-floating-point-math)).
- A corridor holds at most `CROWD_MAX_PATH` polygons per agent; a polygon whose border edge is split by many portals caps its local boundary contribution at 18 wall segments.
- Snapshots and cached-layer queries handle at most 32 layers at one XZ tile coordinate.
- Origin shifts are horizontal only.

## See also

- [Grid sources, cached grids, bounded detail and sub-cell clearance](navigation_grids.md).
- [Baked snapshots](navigation_persistence.md) and the [wire format](navigation_snapshot_format.md).
- [The Recast and Detour port](navigation_recast_port.md).
- [Large worlds](large_world.md), [serialization](serialization_reference.md#navigation-and-character), [terrain](terrain.md#navigation) for a height-map grid source.
- The `navmesh`, `crowd` and `grid` examples (`python3 scripts/build.py --example navmesh`, `crowd` or `grid`).
