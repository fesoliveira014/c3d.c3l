# Billboards

Billboard centers are packed relative to the shared [frame origin](large_world.md).
Changing the reference preserves sizes, directions, rotations, colors and source
indices, and uploads an unchanged consumed batch once across all views.

`c3d::scene::BillboardBatch` draws fixed-capacity arrays of view-facing quads.
Billboards use the existing transparent material, culling, sorting and view
pipeline. The renderer never advances the application data that populates them.

## Create and update a batch

Given a live scene and a blended material ID, with `c3d::scene` imported:

```c3
Billboard[2] values = { scene::BILLBOARD_DEFAULT, scene::BILLBOARD_DEFAULT };
values[0].position = { -1, 0, 0 };
values[1].position = { 1, 0, 0 };
values[1].color = { 1, 0.5f, 0.2f, 0.5f };
Node* node = scene.add_billboards(
    material: material_id,
    capacity: 128,
    billboards: values[..],
)!;
scene.update_world();

BillboardBatch* batch = scene.get(node, BillboardBatch);
batch.billboards[0].position.y = 1;
scene.mark_billboards_dirty(node);
```

The scene copies the input into one capacity-sized allocation. `count` identifies
the live prefix. `set_billboards` copies a replacement prefix; `resize_billboards`
changes its length and initializes newly exposed entries to unit white quads.
Neither grows capacity. Invalid record data returns `INVALID_ARGUMENT`; exceeding
capacity returns `CAPACITY_EXCEEDED`. Faults leave existing records unchanged.

Records require finite values and nonnegative dimensions. Zero dimensions and
zero direction are allowed. Direct edits to records, facing or material require
`mark_billboards_dirty`; direct count edits must stay within capacity. The
aggregate cache is library-owned. Component pointers are short-lived ECS borrows.

## Orientation and units

Positions and directions are node-local. `size` is full width/height, `rotation`
is an additional in-plane angle in radians, and `color` is straight linear RGBA.
World dimensions multiply width by the node world's X-axis length and height by
its Y-axis length. Node reflections do not reverse the billboard UVs.

- `CAMERA` aligns to each view's right/up axes.
- `DIRECTIONAL` aligns its long (+Y) axis with the world direction projected onto
  the view plane. Zero or nearly view-parallel directions use camera axes.

Both apply `rotation` after alignment. The same records serve perspective and
orthographic views. A second view changes neither the scene nor its revision.
For a WORLD child with identity authored pose, positions/directions are already
world-space; the parent still owns the subtree and supplies inherited visibility.
Layer masks remain independent. See [scene nodes](scene.md).

## Materials and supported paths

This delivery supports `AlphaMode.BLEND`: Basic, Standard, Toon,
non-transmissive Physical and Custom materials with no custom vertex stages.
Core supplies the billboard vertex stage and ordinary fragment inputs, including
UV0/UV1, world position, facing normal, tangent and per-record colour. Both UV
sets cover the same quad. Custom fragments use normal scene-read declarations.

`BlendMode` controls source-over or additive composition. Additive RGB preserves
destination alpha. Depth testing follows the material; blended draws do not
write depth. Fog and per-view clip planes use the existing material/view rules.
Transparent camera velocity keeps its normal behaviour.

Opaque/masked billboards, custom billboard vertex deformation, billboard shadow
casting, object-motion velocity and ray-traced billboard geometry are not part
of this delivery. Unsupported or dead material references are skipped and
counted as dangling draws. Billboard data cannot be read by a mesh vertex form
retained after a failed custom-shader replacement; that draw is skipped.

## Bounds, queries and lifetime

A sphere of radius half the width/height diagonal bounds every facing and
in-plane rotation. CPU batch bounds cache the union by revision and node world;
GPU culling tests individual spheres and sorts survivors by centre depth.
Blended instances still sort when culling is disabled. Sorting is within each
batch, with the existing unsorted fallback on arena overflow, rather than a
global ordering across all transparent surfaces.

Linear picking and `SceneIndex` include individual conservative bounds.
`PickHit.billboard` identifies the component; `instanced` is true and
`instance_index` is the original record index. Triangle requests fall back to
bounds with `triangle_hit = false`, because the query API has no view. Include
each billboard in the index capacity and refresh after structural changes.

Removing the node or an ancestor frees its records through the scene hook.
Shared materials/textures remain in the asset store. GPU records are 64 bytes
per capacity entry, uploaded only after a revision/node-world change and retired
through normal frame completion after an absence. The renderer owns one shared
quad. Empty batches create no billboard upload, draw, cull, sort or scene-read
request. Zero-area records produce no visible geometry or singular normal matrix.
