# Landscape add-on

`c3d_landscape` adds height-mapped terrain, instanced vegetation and water to c3d. It extends the scene layer: terrain and foliage draw through core's instanced path, and water through a custom material the package owns. Core never imports the package and carries no flag for it; selecting the library is the gate.

| Module | Provides |
| --- | --- |
| `c3d::landscape::terrain` | `Terrain`: an `R16_UINT` height map drawn as a per-view quadtree of chunks, tile sets, CPU height queries on the physics height-field convention |
| `c3d::landscape::foliage` | `Foliage`: deterministic scatter of one geometry and material over a terrain, with wind sway, fade and whole-object LOD |
| `c3d::landscape::water` | `Water`: lakes and oceans with Gerstner, simulated or spectral waves, refraction, reflection, underwater fog, CPU surface queries and a buoyancy sampler |
| `c3d::landscape::water_gpu` | Records the spectral water passes; present only under `C3D_LANDSCAPE_GPU` |
| `c3d::landscape` | Generated constants of the package's shader package, the shared `STALE` fault and hash helpers |

## Boundaries

The scene modules import the standard library and core (`c3d`). `foliage` and `water` also import `terrain`, and `water_gpu` imports `c3d::render` under `C3D_LANDSCAPE_GPU`. The package never imports `gpu`, `sdl`, `imgui`, `b3`, `c3d::shader`, `c3d::physics` or another add-on. The serialization adapter imports `c3d::serial` only under `C3D_LANDSCAPE_SERIAL`. The binding rules are in [AGENTS.md](https://github.com/fesoliveira014/c3d.c3l/blob/main/AGENTS.md) and [architecture](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/architecture.md).

## Select the package

List `c3d_landscape` next to `c3d` and core's dependencies in `project.json`; the [release guide](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/release.md) lists the names. Applications that connect water to physics or terrain to navigation also select `c3d_physics` and `b3`, or `c3d_nav`; the package imports neither.

| Feature | Effect | Also select |
| --- | --- | --- |
| `C3D_LANDSCAPE_GPU` | Enables `water_gpu` and the `SPECTRAL` water model; without it, preparing a spectral body faults `UNSUPPORTED` | core's GPU dependencies |
| `C3D_LANDSCAPE_SERIAL` | Registers terrain, foliage and water authoring codecs | `c3d_serial` |

## Quick start

```c3
terrain::register_terrain(&scene, &assets)!;
foliage::register_foliage(&scene)!;
water::register_water(&scene, &assets)!;

terrain::add_terrain(scene: &scene, assets: &assets, node: ground, desc: terrain_desc)!;
foliage::add_foliage(scene: &scene, assets: &assets, node: grass, desc: grass_desc)!;
water::add_water(scene: &scene, assets: &assets, node: lake, desc: water::default_water_desc())!;

// every frame
scene.update_world();
terrain::update(&scene, &assets)!;
foliage::update(&scene, &assets, wind_velocity)!;
water::update(scene: &scene, assets: &assets, wind_velocity: wind_velocity, time: now);
renderer.render_view(&scene, camera, view)!;
```

Each component's descriptor is the application's. The guides give the descriptors, the frame order and the rules of each module.

## Ownership

- The application owns the height map, the control map, the density map and every material and geometry a descriptor names.
- The library owns the terrain's material, shared grid and trace-grid node, a tile's border ring, the foliage cells and their runtime, and the water material, medium node and mirror cameras. Do not edit, remove or reparent them.
- Replacing a height map with one of the same side length refreshes the whole terrain. Another side length hides the terrain until a conforming revision.
- Foliage copies its optional LOD descriptor, levels and parts into scene-owned storage. Do not replace or free its pointer or slices.
- `attach_terrain`, `attach_foliage` and `attach_water` validate and attach authoring without creating runtime. `is_prepared`, `prepare` and `prepare_subtree(scene, assets, root = null)` complete it, and `add_*` does both with rollback on failure. Prepare terrain before dependent foliage, and publish node world matrices before preparing foliage or water. Failed preparation of terrain or water removes only the cache assets the attempt created and keeps shared assets of earlier owners. The shared readiness rules are in [owner readiness](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/owner_readiness.md).
- Foliage can scatter as ranges on any scheduler with `foliage::scatter_job` and `foliage::commit_scatter`, and terrain can build its bounds the same way with `terrain::bounds_job` and `terrain::commit_bounds`. The package does not import `c3d_job`.
- Destroy physics worlds first, then the scene, then the store.

## Serialization

Select `c3d_serial` and enable `C3D_LANDSCAPE_SERIAL` to register the codecs. Reads restore pending owners without generated assets or nodes; call `prepare` afterwards. See [serialization](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/serialization.md#landscape-particle-and-audio-adapters).

## Tests and examples

| Target | Kind |
| --- | --- |
| `landscape_test`, `landscape_gpu_test` | CPU tests; the second needs `C3D_LANDSCAPE_GPU`. The first selects `c3d_physics` and `c3d_nav` for its checks |
| `landscape_serial_test`, `landscape_serial_policy_test` | Serialization adapter tests under `C3D_LANDSCAPE_SERIAL` |
| `terrain_acceptance`, `water_acceptance`, `water_gpu_acceptance` | Manual Vulkan acceptance in `test/gpu`; not part of CI |
| `terrain`, `vegetation`, `water`, `water_gpu` | Examples; `python3 scripts/build.py --example <name>` builds and runs one |

```bash
c3c test landscape_test --path addons/c3d_landscape.c3l
python3 scripts/build.py --example vegetation
```

The [development guide](https://github.com/fesoliveira14/c3d.c3l/blob/main/docs/development.md) covers the build and the acceptance projects.

## Guides

- [Terrain](https://github.com/fesoliveira14/c3d.c3l/blob/main/docs/terrain.md) and its [reference](https://github.com/fesoliveira14/c3d.c3l/blob/main/docs/terrain_reference.md)
- [Vegetation](https://github.com/fesoliveira14/c3d.c3l/blob/main/docs/vegetation.md) and [whole-object LOD](https://github.com/fesoliveira14/c3d.c3l/blob/main/docs/lod.md)
- [Water](https://github.com/fesoliveira14/c3d.c3l/blob/main/docs/water.md), its [wave models](https://github.com/fesoliveira14/c3d.c3l/blob/main/docs/water_wave_models.md) and [reference](https://github.com/fesoliveira14/c3d.c3l/blob/main/docs/water_reference.md)
