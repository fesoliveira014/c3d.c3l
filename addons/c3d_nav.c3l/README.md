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

Not ported: `rcContext` logging and timers (failures are faults), the unsigned-short and flat-list
rasterization overloads, `rcCalcBounds` (merge `Aabb` values instead), watershed and layer regions
(`rcBuildRegions`, `rcBuildLayerRegions`), the distance field (`rcBuildDistanceField`), the detail
mesh (`RecastMeshDetail.cpp`), `rcMergePolyMeshes` and `rcCopyPolyMesh`.

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

The `navmesh` example builds a level of ramps, a stair, walls, a movable platform and a mud volume
and draws tiles, polygons and the spans of the slot being rasterized:

```bash
python3 scripts/build.py --example navmesh
```

## Tests

`python3 scripts/build.py --test` runs the `nav_test` target, or directly:

```bash
c3c test nav_test --path addons/c3d_nav.c3l
```

The upstream Catch2 sections for rasterization and filtering are ported as tests.
