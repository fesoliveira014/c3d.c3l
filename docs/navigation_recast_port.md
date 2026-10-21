# Recast and Detour port

`c3d::nav` is an altered C3 port of [recastnavigation](https://github.com/recastnavigation/recastnavigation) at commit `9f4ce64` (2026-02-27), by Mikko Mononen and contributors. It is not the original software. Algorithms, thresholds and iteration order follow upstream, and where the port differs it says so below. The upstream zlib licence is in `addons/c3d_nav.c3l/LICENSE-recastnavigation.txt`; the package ships it.

This page lists what the package contains. [Navigation](navigation.md) shows how to use it.

## From Recast

- Heightfield rasterization of triangles and walkable-slope marking (`Recast.cpp`, `RecastRasterization.cpp`).
- The low-hanging obstacle, ledge and low-clearance span filters (`RecastFilter.cpp`).
- The compact heightfield with neighbour links (`rcBuildCompactHeightfield`).
- Area erosion, the median filter, and box, convex polygon and cylinder area marking with polygon offsetting (`RecastArea.cpp`).
- Monotone region partitioning with small-region removal and merging (`rcBuildRegionsMonotone`).
- Contour tracing, simplification and hole merging (`RecastContour.cpp`).
- The polygon mesh with tile-border vertex removal and portal edges (`rcBuildPolyMesh`).
- Heightfield layers, the non-overlapping height slices of a tile (`RecastLayers.cpp`).
- The per-tile configuration, bounds and stage order of RecastDemo's `Sample_TileMesh::buildTileMesh`.

## From Detour

- Tile data with its BV tree and off-mesh connections (`dtCreateNavMeshData`). Coarse polygon heights use the vertex fan; bounded surfaces use the package's reference and detail arrays.
- The tiled navmesh: tile add and remove, internal, portal and off-mesh links, and 64-bit salted references (`DetourNavMesh.cpp` with `DT_POLYREF64`).
- The search node pool and priority queue (`DetourNode.cpp`) and the geometry helpers (`DetourCommon.cpp`).
- The query filter, with typed pass and cost hooks, and the queries nearest polygon, polygons in a box, closest point, closest boundary point, polygon height, A* path, straight path and raycast (`DetourNavMeshQuery.cpp`).
- The sliced A* search with its any-angle option and both finalizes, the circle and shape Dijkstra searches and the path read back from them, the local neighbourhood, move along surface, distance to wall, polygon wall segments and random points (`DetourNavMeshQuery.cpp`).
- The tile cache: layer regions, contours and polygon mesh; cylinder, box and yawed box area marking (`DetourTileCacheBuilder.cpp`); and the cache of layers with obstacles, its request and rebuild queues and the budgeted update (`DetourTileCache.cpp`). Layers are stored uncompressed.

## From DetourCrowd

- The path corridor and its three merges (`DetourPathCorridor.cpp`), the local boundary (`DetourLocalBoundary.cpp`), velocity sampling on a grid and in adaptive rings against circles and wall segments (`DetourObstacleAvoidance.cpp`), the proximity grid (`DetourProximityGrid.cpp`) and the round-robin path queue (`DetourPathQueue.cpp`).
- The crowd update with its validity, request, topology, neighbour, corner, off-mesh, steering, avoidance, integration, collision and traversal phases (`DetourCrowd.cpp`).

## Differences from upstream

- The any-angle shortcut ray crosses up to 32 polygons. Upstream passes an empty path that stops it at the first.
- `find_random_point` weights every polygon of the mesh by area. Upstream first picks a tile uniformly.
- An agent added to a freed crowd slot drops that slot's off-mesh traversal, where upstream carries it over.
- The adaptive avoidance pattern of an even division count stores its last sample in the slot it counts, where upstream writes one slot past it.
- The crowd's debug info names an agent by its crowd slot, where upstream compares its place in the active list.
- A queued path cut short by the slot's capacity reports `partial`.
- Failures are faults, not log messages or status flags.

## Not ported

- From Recast: `rcContext` logging and timers, the unsigned-short and flat-list rasterization overloads, `rcCalcBounds` (merge `Aabb` values instead), watershed and layer regions (`rcBuildRegions`, `rcBuildLayerRegions`), the distance field (`rcBuildDistanceField`), the detail mesh (`RecastMeshDetail.cpp`), `rcMergePolyMeshes` and `rcCopyPolyMesh`.
- From Detour: the 32-bit reference split, single-tile `dtNavMesh::init`, tile state save and restore (`storeTileState`, `restoreTileState`), endian swapping, the batched `dtPolyQuery` overload of `queryPolygons`, the tile cache's compressor and allocator interfaces, and layer save and load. A package-owned [snapshot format](navigation_persistence.md) replaces the save and load of baked tiles.
- From DetourCrowd: the parallel arrays of `dtObstacleAvoidanceDebugData`, which an `AvoidanceSample` slice replaces.

## Without an upstream counterpart

- Grid sources: `GridTileBuilder` feeds the floors of a tile map or voxel grid into the same heightfield instead of rasterizing triangles ([navigation grids](navigation_grids.md)), and the contour flag `refine_region_edges` it builds with keeps the corners of edges between regions as upstream keeps those of walls.
- Bounded scene surfaces and sub-cell clearance.
- The scene integration: `NavSource`, `NavVolume`, `NavLink`, `NavObstacle` and `NavAgent` components, `NavBuilder` and `nav_sync`.

## See also

- [Navigation](navigation.md), [navigation grids](navigation_grids.md) and [baked snapshots](navigation_persistence.md).
