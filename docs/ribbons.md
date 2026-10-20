# Ribbons

`c3d::scene::RibbonBatch` draws a fixed-capacity array of points as camera-facing strips: trails, beams, tracers, ropes
seen from afar. Each strip is a run of segments, and every segment is a quad whose width axis turns to face each view.
Ribbons use the transparent material, sorting and view pipeline of [billboard batches](billboards.md). The renderer never
advances the application data that populates them.

## Create and update a batch

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

The scene copies the input into one capacity-sized allocation. `count` identifies the live prefix. `set_ribbons` copies a
replacement prefix; `resize_ribbons` changes its length and initializes newly exposed points to `RIBBON_POINT_DEFAULT`
(unit width, white, at the origin). Neither grows capacity. Invalid data returns `INVALID_ARGUMENT`; exceeding capacity
returns `CAPACITY_EXCEEDED`. Faults leave existing points unchanged.

A `RibbonPoint` holds a `position`, a `width`, a straight linear RGBA `color`, a texture coordinate `v` and `flags`.
Points require finite values, a nonnegative `width` and no flag bit other than `RIBBON_BREAK`. Direct edits to points,
count or material require `mark_ribbons_dirty`; the count must stay within capacity. The aggregate cache is
library-owned. Component pointers are short-lived ECS borrows.

## Strips, breaks and segments

Segment `i` joins point `i` to point `i + 1`, so `n` points draw at most `n - 1` segments. A segment is not drawn when:

- point `i + 1` carries `RIBBON_BREAK`, which starts a new strip at that point;
- point `i + 1` has zero `width`;
- its two points coincide.

A strip may begin on a zero-width point and taper in; it cannot end on one, because the segment that reaches a
zero-width point is the one that is dropped. A batch with fewer than two points draws nothing.

## Placement

Positions are node-local and use the node world, as billboards do. `width` is metres across the strip before the node
scale, and the node scales it by the mean scale of its world: the cube root of the determinant's magnitude. A reflected
node keeps its strips. For a WORLD child with identity authored pose, points are already world-space.

## Orientation

Each view turns every strip to face it, including mirror views and views with other cameras. At a point the side axis
is the cross product of the strip's tangent and the direction to the eye; an orthographic view uses its view axis for the
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
texture-space convention of the [billboard quad](billboards.md#sprite-sheets) and of glTF: `v = 0` is the first stored row
of an image, its top. A strip whose travel points up the screen and whose `v` rises along it therefore shows an image
upside down, with its top at the start; author `v` falling along the travel to put the top of the image toward the head.

The vertex stage writes UV0 and UV1 as `(u, v)`, `v_billboard` (location 8) as `(u, v, 0)`, the normal facing the eye,
the tangent along the strip and the point colour, interpolated. Materials that sample UV0 or UV1 need no ribbon-specific
setup; custom fragments read the varyings as described in [custom shaders](custom_shaders.md#billboard-varying).

## Materials and supported paths

Ribbons follow the billboard rules: `AlphaMode.BLEND` with Basic, Standard, Toon, non-transmissive Physical and Custom
materials, where a custom material has a fragment stage and no vertex stage. Unsupported or dead material references are
skipped and counted as dangling draws. `BlendMode`, depth testing, fog and per-view clip planes follow the material and the
view. In a view with `transparency = WEIGHTED`, a source-over batch with a built-in material, or a custom fragment with a
[weighted form](custom_shaders.md#weighted-transparency), records in the weighted pass.

- **Order.** A batch draws its segments in index order and is not sorted by depth within itself. Overlapping source-over
  segments, and a strip that crosses itself, blend in that order; additive blending or weighted transparency is
  order-independent. Batches still sort against each other by their centre depth.
- **No shadows and no tracing.** Ribbons cast no shadows and are absent from ray tracing and scene tracing.
- **Velocity.** Blended draws write no velocity, so a ribbon is seen with camera motion only.
- **No per-segment culling.** The CPU culls the batch by its bounds; every segment of a visible batch is drawn.

## Bounds, queries and lifetime

CPU batch bounds are the union of the world points, each grown by half its scaled width on every axis, cached by revision
and node world. They bound the strip in every view. Linear picking and `SceneIndex` treat the batch as one entry with
these bounds: `PickHit.ribbon` is set, `instanced` is false and triangle requests fall back to bounds. A batch with fewer
than two points is not picked. A `SceneIndex` counts one entry per ribbon batch against its capacity.

Removing the node or an ancestor frees its points through the scene hook. Shared materials and textures remain in the
asset store. GPU records are 48 bytes per capacity point plus one terminating record, uploaded only after a revision, node
world or [frame origin](large_world.md) change and retired through normal frame completion after an absence. The renderer
shares the billboard quad: one instance per segment, six vertices each. Empty and single-point batches create no upload
and no draw.

## Serialization

`c3d.RibbonBatch` is a core codec at version 1. It carries the material, the capacity and the live points, and applies the
point rules above on read and write. See [serialization](serialization.md).
