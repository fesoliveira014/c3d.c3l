# Billboards

Billboard centers are packed relative to the shared [frame origin](large_world.md).
Changing the reference preserves sizes, directions, rotations, colors and source
indices, and uploads an unchanged consumed batch once across all views.

`c3d::scene::BillboardBatch` draws fixed-capacity arrays of view-facing quads.
Billboards use the existing transparent material, culling, sorting and view
pipeline. The renderer never advances the application data that populates them.
Camera-facing strips through a list of points are [ribbons](ribbons.md).

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

Records require finite values, nonnegative dimensions and a finite nonnegative
`frame`. Zero dimensions and zero direction are allowed. Direct edits to records,
facing, atlas or material require `mark_billboards_dirty`; direct count edits must
stay within capacity, and a directly edited atlas must satisfy the rules below. The
aggregate cache is library-owned. Component pointers are short-lived ECS borrows.

## Sources

`BillboardBatch.source` selects where a batch's draw data lives. `add_billboards` takes it as a trailing argument.

- **`BILLBOARDS`**, the default, holds node-local `Billboard` values in `billboards`. Core converts them to world-space
  records once per revision.
- **`RECORDS`** holds world-space `BillboardRecord` values in `records`, in the renderer's 64-byte layout. The owner writes
  `records[:count]`, sets each `facing` to the batch's `BillboardFacing` ordinal and each `direction` to a unit vector
  or zero, and calls `mark_billboards_dirty`. Core subtracts the frame origin as it copies them to the upload, and
  builds no `Billboard`.
- **`DEVICE`** has no CPU array. Compute writes `capacity` `BillboardGpu` records and one `uint` count into an
  application buffer from `Renderer.create_buffer`. Every record is relative to `Renderer.frame_origin`, which the writer
  subtracts. `Scene.set_billboard_device` attaches a `BillboardDevice` naming the buffer, the byte offsets of the records
  and of the count word, and the capacity, which must equal the batch's. The records offset is a multiple of 16, the
  count offset a multiple of 4, and the buffer holds both. `set_billboard_device` requires the two alignments; core does not
  check the buffer size.

A RECORDS or DEVICE batch is drawn without its node's world matrix, so its node must keep an identity world; a WORLD
child with an identity pose does. Records are not validated: the owner keeps them finite. Passing `billboards` with
another source than `BILLBOARDS` returns `INVALID_ARGUMENT`, and `set_billboards` and `resize_billboards` apply to
`BILLBOARDS` batches only. Bounds, picking and `SceneIndex` read `BILLBOARDS` and `RECORDS` batches through
`BillboardBatch.billboard(index)`. The serialization codec faults `UNSUPPORTED` when exporting a `RECORDS` or `DEVICE`
batch.

### Device batches

The renderer culls a DEVICE batch at its capacity and skips the records at or past the count word. It draws the counted
records that are visible and shares one buffer between every view. The draw count and the order of the survivors
therefore come from the GPU: the count word may change every frame, and nothing on the CPU reads it. A batch with no
attached buffer draws nothing.

- The culling dispatch always runs for a DEVICE batch, with an open frustum when the view has `instance_culling` off,
  because the records past the count word hold stale data. When the cull arena cannot hold the batch it draws nothing
  and the frame counts the overflow in `Stats.cull_overflows`, or in `sort_overflows` for a sorted batch.
- A destroyed buffer skips the draw and counts in `Stats.dangling_refs`.
- A `Renderer.dispatch` that names the buffer in `DispatchDesc.writes` orders its writes before every later cull and draw
  of the frame.
- Bounds come from the override below. Picking and `SceneIndex` skip a DEVICE batch.
- The sprite-sheet block that precedes a batch's records in the other sources is written into the frame's upload ring for
  a DEVICE batch, because the application's buffer has no room for it.

### Bounds override

`BillboardBatch.has_bounds_override` with `local_bounds` replaces the union of the records' bounds with the node-local
box, transformed by the node, for every source. It spares the CPU the scan over the records, and a DEVICE batch needs it
because the CPU never reads the records. `set_billboard_device` sets both. The box must contain every record the batch
can hold, since extraction culls the whole batch against it; the per-record test on the GPU is unchanged. Picking and
`SceneIndex` keep reading the records' own bounds.

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

## Sprite sheets

`BillboardBatch.atlas`, a `BillboardAtlas`, lays a sprite sheet over the textures
of the batch's material. It is off while `columns` is 0.

```c3
BillboardAtlas sheet = { .columns = 4, .rows = 4, .frame_count = 14, .inset = { 0.5f / 512, 0.5f / 512 } };
Node* node = scene.add_billboards(
    material: material_id,
    capacity: 128,
    billboards: values[..],
    atlas: sheet,
)!;
scene.set_billboard_atlas(node, sheet)!;
```

- **Frames.** Frames run row-major from the top-left cell of the image as stored:
  frame 0 is the first column of the first stored row. A billboard's `frame` is
  a float. Its integer part, taken modulo `frame_count`, is the current cell; its
  fraction blends toward the next cell, which wraps from the last frame to frame 0.
  Applications wrap `frame` as they advance it and keep it below 2^24, where a float
  still holds whole frames.
- **UVs.** UV0 maps the quad into the current cell and UV1 into the next one. Each
  rectangle is the cell cut by `inset` on all four sides, in UV units of the whole
  texture. The quad's uv origin is its top-left corner, as in texture space and
  glTF: u runs from the left edge to the right edge and v from the top edge down,
  so an image stored top row first draws upright, with or without an atlas, and so
  does the art of every cell. A 1x1 atlas with zero inset is the same as no atlas.
- **Materials.** Every material that samples UV0 steps through the cells, with no
  other change; a map that reads UV1 shows the next cell. A custom fragment blends
  a UV0 sample and a UV1 sample by `v_billboard.z`, the fraction of `frame`.
- **`v_billboard`.** Vertex output location 8 holds (quad u, quad v, fraction of
  `frame`), smoothly interpolated, with v running from the quad's top edge down.
  UV0 no longer holds the quad coordinate under an
  atlas, so a fragment that needs it reads `v_billboard.xy`. Without an atlas the
  third component is 0. Mesh draws write (uv0, 0); see
  [custom shaders](custom_shaders_reference.md#billboard-varying).
- **Validation.** `INVALID_ARGUMENT` from `add_billboards`, `set_billboards`,
  `set_billboard_atlas` and the serialization codec for: a `frame` that is not
  finite or is negative; `columns` of 1 or more with `rows` 0; `frame_count`
  outside 1 to `columns` x `rows`; an `inset` component that is not finite, is
  negative, or is at least half a cell on its axis. A fault leaves the batch
  unchanged. `set_billboard_atlas` bumps the batch revision.

### Edges and mipmaps

Neighbouring cells meet at a texel boundary, so filtering can mix their colours.

- Set `inset` to half a texel of the atlas texture on each axis (0.5 divided by
  the texture's width, and by its height). Bilinear taps at mip 0 then stay inside
  the cell.
- With mipmaps, a tap at level `l` reads texels up to 2^l texels from the sample
  position. Pad each cell with a border of at least 2^(m-1) texels for `m` sampled
  levels (0 to m-1), filled with the cell's own edge colour at zero alpha, so a
  neighbour's colour only ever enters a tap at zero alpha and the premultiplied
  output hides it.
- Anisotropic filtering widens the footprint along one axis without a bound the
  padding rule can name, so it carries no guarantee. Leave it off for atlas
  textures.

## Materials and supported paths

This delivery supports `AlphaMode.BLEND`: Basic, Standard, Toon,
non-transmissive Physical and Custom materials with no custom vertex stages.
Core supplies the billboard vertex stage and ordinary fragment inputs, including
UV0/UV1, world position, facing normal, tangent and per-record colour. Without a
sprite sheet both UV sets cover the same quad, with the origin at its top-left
corner. Custom fragments use normal scene-read declarations.

`BlendMode` controls source-over or additive composition. Additive RGB preserves
destination alpha. In a view with `transparency = WEIGHTED`, a source-over batch
with a built-in material, or a custom fragment that supplies a
[weighted form](custom_shaders_reference.md#weighted-form), records in the
[weighted pass](transparency.md#weighted-transparency) and skips its sort; an additive batch
and a custom fragment without that form keep both. Depth testing follows the material; blended draws do not
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

Linear picking and `SceneIndex` include individual conservative bounds of `BILLBOARDS` and `RECORDS` batches.
`PickHit.billboard` identifies the component; `instanced` is true and
`instance_index` is the original record index. Triangle requests fall back to
bounds with `triangle_hit = false`, because the query API has no view. Include
each billboard in the index capacity and refresh after structural changes.

Removing the node or an ancestor frees its records through the scene hook.
Shared materials/textures remain in the asset store. GPU records are 64 bytes
per capacity entry, plus a 32-byte atlas block per batch, uploaded only after a
revision/node-world change and retired through normal frame completion after an
absence. The renderer owns one shared
quad. Empty batches create no billboard upload, draw, cull, sort or scene-read
request. Zero-area records produce no visible geometry or singular normal matrix.
