# c3d_nav

Navigation meshes for c3d: module `c3d::nav`, an add-on package that depends on core `c3d` only.
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

Not ported: `rcContext` logging and timers (failures are faults), the unsigned-short and flat-list
rasterization overloads, `rcCalcBounds` (merge `Aabb` values instead), watershed and layer regions
(`rcBuildRegions`, `rcBuildLayerRegions`), the distance field (`rcBuildDistanceField`), the detail
mesh (`RecastMeshDetail.cpp`), `rcMergePolyMeshes` and `rcCopyPolyMesh`; from Detour, the 32-bit ref
split, single-tile `dtNavMesh::init`, tile state save and restore (`storeTileState`,
`restoreTileState`), endian swapping, the batched `dtPolyQuery` overload of `queryPolygons`, the
tile cache and the crowd.

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

## Tests

`python3 scripts/build.py --test` runs the `nav_test` target, or directly:

```bash
c3c test nav_test --path addons/c3d_nav.c3l
```

The upstream Catch2 sections for rasterization and filtering are ported as tests.
