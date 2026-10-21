# Navigation add-on

`c3d_nav` adds navigation meshes and crowds to c3d: module `c3d::nav`. It builds tiled navmeshes from scene geometry, tile maps, voxel grids and height fields, answers path and surface queries, steers agents, and saves baked meshes to portable bytes. It is a port of Recast, Detour and DetourCrowd.

## Port notice

This package is an altered C3 port of [recastnavigation](https://github.com/recastnavigation/recastnavigation) at commit `9f4ce64` (2026-02-27), by Mikko Mononen and contributors. It is not the original software. Algorithms, thresholds and iteration order follow upstream. The upstream zlib licence is in `LICENSE-recastnavigation.txt`. The [port page](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/navigation_recast_port.md) lists what is ported, what differs and what is left out.

## Boundaries

`c3d::nav` imports the standard library and core (`c3d`). It never imports `gpu`, `sdl`, `imgui`, `b3` or `c3d::physics`, and creates no GPU object. Core never imports it and carries no navigation flag; selecting the library is the gate. The serialization adapter imports `c3d::serial` only under `C3D_NAV_SERIAL`. The binding rules are in [AGENTS.md](https://github.com/fesoliveira014/c3d.c3l/blob/main/AGENTS.md) and [architecture](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/architecture.md).

## Select the package

List `c3d_nav` next to `c3d` and core's dependencies in `project.json`; the [release guide](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/release.md) lists the names. The package needs no other dependency.

| Setting | Effect |
| --- | --- |
| `"fp-math": "strict"` | Required for bounded detail and sub-cell clearance (`--fp-math=strict` for `c3c`); the package's own project sets it |
| `C3D_NAV_SERIAL` | Registers the authoring codecs with `nav::register_serial_codecs()`; also select `c3d_serial`. See [serialization](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/serialization.md#navigation-adapter) |

## Quick start

```c3
nav::register_nav(&scene)!;
scene.add_nav_sources(scene.root); // a walkable source per Mesh node

NavBuilderDesc desc = nav::default_nav_builder_desc(
    bounds: { .min = { -50, -1, -50 }, .max = { 50, 10, 50 } },
);
NavBuilder builder = nav::create_nav_builder(mem, &scene, desc)!;
NavMesh mesh = nav::create_nav_mesh_for(mem, &builder)!;
NavQuery query = nav::create_nav_query(mem, &mesh, 2048)!;

// each frame, after scene.update_world()
nav::nav_sync(builder: &builder, mesh: &mesh, scene: &scene, assets: &assets, budget: 8);

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
```

Destroy the query, mesh and builder (with `destroy_nav_query`, `destroy_nav_mesh` and `destroy_nav_builder`) before the scene.

## Targets and examples

| Target | Kind |
| --- | --- |
| `nav_test` | CPU tests |
| `nav_serial_test`, `nav_serial_policy_test` | Serialization adapter tests under `C3D_NAV_SERIAL` |
| `navmesh`, `crowd`, `grid` | Windowed examples: a scene-built mesh, a crowd, and a tile map with tile edits |
| `nav_persistence` | CPU example: save, replace and query a baked snapshot |

```bash
c3c test nav_test --path addons/c3d_nav.c3l
python3 scripts/build.py --example navmesh
```

The [development guide](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/development.md) covers the build and the test targets.

## Guides

- [Navigation](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/navigation.md): building meshes from scene geometry, queries, crowds and rebasing
- [Navigation grids](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/navigation_grids.md): grid sources, cached updates, bounded detail and sub-cell clearance
- [Baked snapshots](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/navigation_persistence.md) and the [wire format](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/navigation_snapshot_format.md)
- [Recast and Detour port](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/navigation_recast_port.md)
