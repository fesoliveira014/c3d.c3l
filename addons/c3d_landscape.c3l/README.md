# Landscape add-on

Select `c3d_landscape` to use [terrain](../../docs/terrain.md),
[foliage](../../docs/vegetation.md) and [water](../../docs/water.md).
Core never imports this package. Scene modules import the standard library and
core; terrain/water shader sources are built through the package shader manifest.

Foliage supports one geometry/material pair or a copied `FoliageDesc.lod`
description. LOD cells own one core instanced group; all parts share scatter,
tint, sway and fade. The null descriptor keeps the single-mesh path.
See [whole-object LOD](../../docs/lod.md) for ownership and selection contracts.

The terrain's material and grid, and the water material, are owned by their components. Do not replace or edit
them. The height map and control map belong to the application: replacing the height map with the same side
length refreshes the whole map; another side length hides the batch until a conforming revision.

```powershell
c3c test landscape_test --path addons/c3d_landscape.c3l
python scripts/build.py --example vegetation
```

Manual terrain/water Vulkan acceptance lives in `test/gpu`; the data tests do
not create a device.

## Pending authoring and preparation

`terrain::attach_terrain`, `foliage::attach_foliage` and `water::attach_water`
validate and attach authored components to existing nodes. They create no
runtime component, generated node, draw batch or asset. Foliage copies its
optional LOD descriptor, levels and parts into scene-owned authoring storage.
Attach ground `Terrain` authoring before dependent `Foliage` authoring.

Each namespace provides `is_prepared(scene, node)`, `prepare(scene, assets, node)`
and `prepare_subtree(scene, assets, root = null)`. A null root selects the whole
scene; a supplied root is included. Prepare terrain before dependent foliage.
Preparing foliage while its ground terrain is pending returns `terrain::NOT_PREPARED` and
retains the foliage authoring. Water has no landscape preparation dependency.
Publish node world matrices before preparing foliage or water.

A prepared owner is a no-op for preparation. Each pending owner either receives
complete runtime or remains pending with its authoring intact. A subtree pass
attempts all matching owners and returns its first fault; successful owners are
retained. Failed terrain/water preparation removes only cache assets that the
attempt created, preserving shared assets used by prior owners.

Ordinary updates skip pending owners. A pending terrain has no generated
`InstancedMesh`, pending foliage has no generated cells, and pending water has
no generated `Mesh` or mirror camera. They produce no generated draws. Existing
`add_terrain`, `add_foliage` and `add_water` combine attachment and preparation,
retaining their immediate-ready behavior and rollback on failure.

The copied foliage LOD data belongs to the component; do not replace or free its
pointer or slices. Prepared foliage also owns a separate frozen runtime copy.
Removing authored foliage frees its authoring copy immediately. Existing runtime
and cells remain valid until the next foliage update removes the orphans.

## Serialization

Select `c3d_serial` and enable `C3D_LANDSCAPE_SERIAL` to register terrain, foliage and water authoring codecs. Reads restore pending owners without generated assets or nodes. See [the serialization contract](src/serial/README.md) for ownership, preparation order and the feature-on test targets.
