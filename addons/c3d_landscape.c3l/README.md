# Landscape add-on

Select `c3d_landscape` to use [terrain](../../docs/terrain.md),
[foliage](../../docs/vegetation.md) and [water](../../docs/water.md).
Core never imports this package. Scene modules import the standard library and
core; terrain/water shader sources are built through the package shader manifest.

Foliage supports one geometry/material pair or a copied `FoliageDesc.lod`
description. LOD cells own one core instanced group; all parts share scatter,
tint, sway and fade. The null descriptor keeps the single-mesh path.
See [whole-object LOD](../../docs/lod.md) for ownership and selection contracts.

```powershell
c3c test landscape_test --path addons/c3d_landscape.c3l
python scripts/build.py --example vegetation
```

Manual terrain/water Vulkan acceptance lives in `test/gpu`; the data tests do
not create a device.
