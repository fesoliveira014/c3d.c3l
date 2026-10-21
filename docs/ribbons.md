# Ribbons

`c3d::scene::RibbonBatch` draws a fixed-capacity array of points as camera-facing strips: trails, beams, tracers, ropes
seen from afar. Each strip is a run of segments, and every segment is a quad whose width axis turns to face each view.
Ribbons use the transparent material, sorting and view pipeline of [billboard batches](billboards.md). The renderer
never advances the application data that populates them.

## Quick start

Given a live scene and a blended material ID, with `c3d::scene` imported:

```c3
RibbonPoint[3] points = { scene::RIBBON_POINT_DEFAULT, scene::RIBBON_POINT_DEFAULT, scene::RIBBON_POINT_DEFAULT };
points[0].position = { 0, 0, 0 };
points[1].position = { 0, 1, 0 };
points[2].position = { 1, 2, 0 };
points[2].v = 1;
Node* node = scene.add_ribbons(
    material: material_id,
    capacity: 64,
    points: points[..],
)!;
scene.update_world();

RibbonBatch* batch = scene.get(node, RibbonBatch);
batch.points[2].position.x = 2;
scene.mark_ribbons_dirty(node);
```

The scene copies the input into one capacity-sized allocation; `add_ribbons` requires `capacity > 0`. `count` identifies
the live prefix. `set_ribbons` copies a replacement prefix; `resize_ribbons` changes its length and initializes newly
exposed points to `RIBBON_POINT_DEFAULT` (unit width, white, at the origin). Neither grows capacity. Invalid data
returns `INVALID_ARGUMENT`; exceeding capacity returns `CAPACITY_EXCEEDED`. Faults leave existing points unchanged.

| `RibbonPoint` field | Meaning |
| --- | --- |
| `position` | Node-local position. |
| `width` | Metres across the strip before the node scale. Nonnegative. |
| `color` | Straight linear RGBA. |
| `v` | Texture coordinate along the strip. |
| `flags` | `RIBBON_BREAK` starts a new strip at the point. No other bit is allowed. |

Points require finite values. Direct edits to points, count or material require `mark_ribbons_dirty`; the count must
stay within capacity. The aggregate cache is library-owned. Component pointers are short-lived ECS borrows.

## Sources

`RibbonBatch.source` says where the points live. `Scene.add_ribbons` takes it as a trailing `RibbonSource`.

- **`POINTS`**, the default, holds the scene-owned `RibbonPoint` array described above. Core packs it once per revision.
- **`DEVICE`** has no CPU array. Compute writes the records into an application buffer ([Device
  batches](#device-batches)).

`set_ribbons` and `resize_ribbons` apply to `POINTS` batches only, and passing `points` with `DEVICE` returns
`INVALID_ARGUMENT`. A `DEVICE` batch is drawn without its node's world matrix, so its node must keep an identity world;
a WORLD child with an identity pose does. Records are not validated: the owner keeps them finite and their flags to
`RIBBON_BREAK`.

### Device batches

A `DEVICE` ribbon batch follows the [shared device-batch contract](instancing.md#device-batches): buffer layout and
alignment, the bounds override, dispatch ordering, buffer lifetime, cull arena overflow and excluded consumers. The
differences for ribbons:

- **Records.** Compute writes `capacity` `RibbonPointGpu` records (`RIBBON_RECORD_BYTES`, 48 bytes), one terminating
  record and one `uint` count into a buffer from `Renderer.create_buffer`. Every record is relative to
  `Renderer.frame_origin`, which the writer subtracts, and widths are in metres after the node scale.
- **Attach.** `Scene.set_ribbon_device` attaches a `RibbonDevice` with the buffer, the byte offsets of the records and
  of the count word, and the capacity, together with the node-local bound. The capacity must equal the batch's.
- **Count.** The count word is the number of live points. The record at that index must carry `RIBBON_BREAK`, so no
  segment joins a record past the last live point and the tangent search stops there. The draw is `count - 1` segments
  for a count above one and none otherwise. One single-thread dispatch in each view's culling pass copies that figure
  into the indirect draw arguments, clamped to `capacity - 1`. It counts in `Stats.cull_dispatches`, also with
  `instance_culling` off. One buffer serves every view.
- **Culling.** A ribbon batch culls as a whole against its bound. There is no per-segment test. When the cull arena
  cannot hold the draw arguments, the batch draws nothing and counts in `Stats.cull_overflows`.

### Bounds override

`RibbonBatch.has_bounds_override` with `local_bounds` replaces the union of the points' bounds with the node-local box,
transformed by the node, for every source. A `DEVICE` batch needs it because the CPU never reads the records, and
`set_ribbon_device` sets both. The box must contain every strip the buffer can hold, including half of each width, since
extraction culls the whole batch against it.

## Strips, breaks and segments

Segment `i` joins point `i` to point `i + 1`, so `n` points draw at most `n - 1` segments. A segment is not drawn when:

- point `i + 1` carries `RIBBON_BREAK`, which starts a new strip at that point;
- its two points coincide.

A point with zero `width` is an ordinary point: a strip narrows to nothing there, whether at its start or its end, and a
zero-width point inside a strip pinches it. Order of the points does not change this. A batch with fewer than two points
draws nothing.

## Placement

Positions are node-local and use the node world, as billboards do. `width` is metres across the strip before the node
scale, and the node scales it by the mean scale of its world: the cube root of the determinant's magnitude. A reflected
node keeps its strips. For a WORLD child with identity authored pose, points are already world-space.

## Orientation

Each view turns every strip to face it, including mirror views and views with other cameras. At a point the side axis is
the cross product of the strip's tangent and the direction to the eye; an orthographic view uses its view axis for the
eye direction. Strips are always front-facing, in views of either handedness.

- **Tangent.** The tangent at a point is the normalised sum of the directions of the nearest segments on each side
  inside its strip, oriented along the travel of the segment being drawn. Both ends of a segment next to a zero-length
  one therefore share the same tangent, and neighbouring segments share their joint edge. A strip end uses its single
  segment. Zero-length segments are skipped over at most four segments each way.
- **Doubling back.** Where the two directions cancel (the sum is shorter than 0.001), the point keeps the incoming
  direction.
- **No miter.** The width across a joint is the point's width, so a sharp bend narrows the strip at the joint.
- **Edge-on.** A strip that points along the line of sight has no side axis there and collapses to zero width at that
  point, without producing invalid values.

## Texture coordinates

Seen with the direction of travel (increasing point index) pointing up the screen, `u` runs from 0 at the left edge to 1
at the right edge. `v` is the `v` of the points, as authored, interpolated along each segment. Both follow the
texture-space convention of the [billboard quad](billboards.md#sprite-sheets) and of glTF: `v = 0` is the first stored
row of an image, its top. A strip whose travel points up the screen and whose `v` rises along it therefore shows an
image upside down, with its top at the start; author `v` falling along the travel to put the top of the image toward the
head.

The vertex stage writes UV0 and UV1 as `(u, v)`, `v_billboard` (location 8) as `(u, v, 0)`, the normal facing the eye,
the tangent along the strip and the point color, interpolated. Materials that sample UV0 or UV1 need no ribbon-specific
setup; custom fragments read the varyings as described in [custom shaders](custom_shaders.md#billboard-varying).

## Materials and supported paths

Ribbons follow the billboard rules: `AlphaMode.BLEND` with Basic, Standard, Toon, non-transmissive Physical and Custom
materials, where a custom material has a fragment stage and no vertex stage. Unsupported or dead material references are
skipped and counted as dangling draws. `BlendMode`, depth testing, fog and per-view clip planes follow the material and
the view. In a view with `transparency = WEIGHTED`, a source-over batch with a built-in material, or a custom fragment
with a [weighted form](custom_shaders.md#weighted-transparency), records in the weighted pass.

## Bounds, queries and lifetime

CPU batch bounds are the union of the world points, each grown by half its scaled width on every axis, cached by
revision and node world, unless the [override](#bounds-override) replaces them. They bound the strip in every view.
Linear picking and `SceneIndex` treat the batch as one entry with these bounds: `PickHit.ribbon` is set, `instanced` is
false and triangle requests fall back to bounds. A batch with fewer than two points is not picked. A `SceneIndex` counts
one entry per ribbon batch against its capacity ([scene index](picking.md#scene-index)).

Removing the node or an ancestor frees its points through the scene hook. Shared materials and textures remain in the
asset store. GPU records are 48 bytes per capacity point plus one terminating record. A `POINTS` batch uploads them only
after a revision, node world or [frame origin](large_world.md) change and retires them through normal frame completion
after an absence. The renderer shares the billboard quad: one instance per segment, six vertices each. Empty and
single-point batches create no upload and no draw.

## Serialization

`c3d.RibbonBatch` is a core codec at version 1. It carries the material, the capacity and the live points, and applies
the point rules above on read and write. See the [serialization
reference](serialization_reference.md#core-values-and-batches).

## Limits

- **Order.** A batch draws its segments in index order and is not sorted by depth within itself. Overlapping source-over
  segments, and a strip that crosses itself, blend in that order; additive blending or weighted transparency is
  order-independent. Batches still sort against each other by their center depth.
- **No shadows and no tracing.** Ribbons cast no shadows and are absent from ray tracing and scene tracing.
- **Velocity.** Blended draws write no velocity, so a ribbon is seen with camera motion only.
- **No per-segment culling.** The CPU culls the batch by its bounds; every segment of a visible batch is drawn.
- A `DEVICE` batch is not picked, indexed or serialized, and its node must keep an identity world.

## See also

- [Explicit instancing](instancing.md#device-batches) for the shared device-batch contract.
- [Billboards](billboards.md) for quads, sprite sheets and the texture convention.
- [Custom shaders](custom_shaders.md#billboard-varying) for the varyings a custom fragment reads.
- [Particles](particles.md#trails) for a system that publishes ribbon batches.
- [Picking](picking.md#scene-index) for the index capacity rule.
