# Geometry edits

Edit a geometry's vertex arrays in place, tell the store which streams changed, and let the renderer upload only those
vertices. For meshes whose positions change every frame, `Mesh.vertex_motion` also gives the velocity pass the previous
positions, so motion blur and temporal effects see the deformation. The calls live on `AssetStore` in `c3d::asset`; the
flag lives on `Mesh` in `c3d::scene`.

## Quick start

```c3
Geometry* data = &assets.geometry(geometry_id).data;
data.positions[0].y += 0.1f;
assets.mark_geometry_range_dirty(
    geometry: geometry_id,
    streams: { .positions = true },
    first_vertex: 0,
    vertex_count: 1,
);
```

Publish the edit before the frame that draws it. The renderer uploads the named range at the next resolve.

## Publishing geometry edits

An in-place edit of `assets.geometry(id).data` reaches the renderer through one of three calls. Each advances the geometry
revision.

| Call | The renderer copies |
| --- | --- |
| `mark_geometry_streams_dirty(id, streams)` | Every vertex of each named stream |
| `mark_geometry_range_dirty(id, streams, first_vertex, vertex_count)` | The named vertices of each named stream |
| `mark_geometry_dirty(id)` | The whole block |

`streams` is a `GeometryStreams` bitstruct: `positions`, `normals`, `tangents`, `uv0`, `uv1`, `colors`, `joints`, `weights`
and `custom`.

- The marked streams exist in the geometry, `vertex_count` is positive and the range lies inside the vertex count. Each is
  a contract.
- A stream mark names only data the edit changed. An unmarked edit is not uploaded.
- Index and morph-target edits have no stream. Publish them with `mark_geometry_dirty`.
- The record keeps one vertex range per stream since the renderer last held the geometry. A second mark before the next
  resolve extends that union, so two distant ranges of one stream cover the vertices between them.
- With an unchanged layout and only stream ranges marked, the renderer stages each stream's range and copies it into the
  existing block. `Stats.upload_bytes` counts the staged bytes.
- The renderer uploads the whole block after `mark_geometry_dirty`, after a replacement, when a stream appears or
  disappears, when the vertex or index count, the morph target count or the joint packing width changes, and for a geometry
  it has never uploaded or whose upload an aborted frame dropped.
- A renderer whose copy is at another revision, such as a second renderer on the same store, uploads whole. Ranges are
  relative to the revision the last resolving renderer held.

The store recomputes derived data only from the marked streams: the 16-bit joint packing width when `joints` is marked, and
the skin and morph bounds when `positions`, `joints` or `weights` is marked. `mark_geometry_dirty` recomputes all of it.
A mark never recomputes `Geometry.bounds`; call `Geometry.finalize` after editing positions. Traced and temporal consumers
read only the revision, so they behave the same for every call.

## Edited vertices

`Mesh.vertex_motion = true` gives an ordinary mesh (not a batch, crowd or LOD group) velocity for CPU-edited positions.
Edit `assets.geometry(id).data.positions` in place, recompute normals when needed, and publish the edit before recording
the frame.

- Vertex indices keep naming the same vertices. A new correspondence needs a new `GeometryId`, or a call to
  `Mesh.reset_vertex_history()` that makes views reject their prior vertex history. A changed vertex count starts over.
- Each temporal view copies the base positions of the flagged meshes it drew into its pose history: 12 bytes per vertex,
  allocated on first use or a count change and freed with the history.
- When the geometry revision differs from the copy, the velocity pass uploads the copy through the frame ring and composes
  it with the previous morph, skin and model, so a stationary node shows its deformation. An unchanged revision keeps the
  ordinary rule. `Stats.vertex_history_bytes` counts the bytes uploaded per frame.
- A first observation, another geometry or count, re-enabling after an untracked rendering, a reset, a missing previous
  rendering or an aborted capture writes zero motion and sets the rejection channel (`DRAW_VERTEX_HISTORY_INVALID`). TAA,
  screen-space GI, temporal ambient occlusion and the reflection history drop history for those pixels only.
- A temporal view faults `c3d::ASSET_DATA_UNAVAILABLE` from `render_view`, before recording, when a flagged mesh's CPU
  positions were released. Its published history stays as it was.
- A geometry that a dispatch writes ([geometry writes](compute.md#geometry-writes)) takes its previous positions from a
  renderer-owned buffer instead. Such a mesh needs no CPU positions and nothing travels through the frame ring.
- Blended surfaces keep the velocity of the surface behind them.

## Limits

- Edited vertices need `Mesh.vertex_motion` on a plain mesh; batches, crowds and LOD groups have no vertex history.
- Two distant ranges of one stream upload everything between them.
- A mark does not update `Geometry.bounds`; call `Geometry.finalize` after moving positions.

## See also

- [Anti-aliasing](anti_aliasing.md#velocity-and-history) for the velocity image and history rules.
- [Cloth](cloth.md) for a producer of edited vertices.
- [Asset store](assets.md) for revisions across kinds.
- [Compute dispatch](compute.md#geometry-writes) for geometry written on the device.
