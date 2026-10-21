# Landscape serialization

Saves terrain, terrain tile sets, foliage and water as portable authoring under `C3D_LANDSCAPE_SERIAL`. The serialization model is in [Serialization](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/serialization.md). Component versions, restore phases and what older payloads read as are in the [versions table](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/serialization_reference.md#versions-and-older-payloads).

## Enable and register

Select `c3d_landscape` and `c3d_serial`, enable `C3D_LANDSCAPE_SERIAL`, register the landscape stores and hooks, then call `landscape::register_serial_codecs()`. The plain landscape package has no serialization dependency. Registration creates no scene or asset state. Shared LOD, transform and effect values come from `serial::register_core_value_types()`.

The portable components are `terrain`, `terrain_set`, `terrain_tile`, `foliage` and `water`.

## What is saved

- `terrain`, `terrain_tile` and `water` save `TerrainDesc`, `TerrainTile` and `WaterDesc` directly. A standalone `Wave` defaults to zeros; the water constructor supplies its two calm waves.
- `terrain_set` saves `texels`, `cell_size` and `height_scale`, never the neighbour table.
- `foliage` saves every `FoliageDesc` field. `lod` is a zero-or-one-element `LodDesc` array, and attachment copies the descriptor, levels and parts.
- Defaults come from the terrain, foliage and water descriptor constructors.

## What restarts

A read restores pending authoring and creates no geometry, material, batch, cell or mirror. Neither `TerrainRuntime`, `FoliageRuntime`, `FoliageCellOwner`, `WaterRuntime` nor `WaterMirror` is saved. The set's neighbour links rebuild when the tiles prepare.

## Order of read and preparation

`terrain`, `terrain_set` and `terrain_tile` restore in `VALUE`; `foliage` and `water` restore in `OWNER`, so their ground already carries `Terrain`. A water `ground` must name a node that carries `Terrain` in the same exported subtree.

Prepare terrain before foliage through the explicit prepare calls; water prepares independently. Owner validation faults propagate unchanged. See [owner readiness](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/owner_readiness.md).

## Export

Export borrows authoring and changes nothing. Pending and prepared owners write the same authoring.

- It omits the generated draw components on a terrain or water node, a prepared water body's medium child node with its `MediumVolume`, and a prepared terrain's trace grid, which `TerrainRuntime.trace_grid` names.
- It omits foliage cell nodes and water mirror nodes only after their runtime ownership checks out. An external mirror, one per slot, is omitted when it belongs to the selected subtree.
- Exporting a mirror or a foliage cell on its own faults `INVALID_ARGUMENT`. So does an application-authored child or component on an omitted generated node. Ordinary authored children of owner nodes stay in the document.

## Targets

```bash
c3c test landscape_serial_test --path addons/c3d_landscape.c3l
c3c test landscape_serial_policy_test --path addons/c3d_landscape.c3l
```

`landscape_serial_test` runs the adapter with the feature on. `landscape_serial_policy_test` checks every landscape component slot for its policy. `landscape_test` is the feature-off check. `scripts/build.py --test` runs all three.
