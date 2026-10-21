# Camera-relative rendering

The scene keeps absolute float transforms. The renderer subtracts one shared origin, the frame origin, before it
composes GPU models, bounds, camera matrices and trace data, so distant content keeps its precision on the GPU. This page
owns the coordinate contract for the renderer and every consumer of its packed values. To move the origin while a game
runs, see [origin rebasing](origin_rebasing.md).

## Quick start

Choose a reference near the cameras whose precision matters for this frame, and pass it in `FrameInfo`:

```c3
scene.update_world();
FrameInfo info = {
    .time = time,
    .delta = delta,
    .reference_position = camera_node.world_position(),
};
renderer.begin_frame(info)!;
renderer.render_view(&scene, mirror_camera, mirror_view)!;
renderer.finish_view(mirror_view)!;
renderer.render_view(&scene, camera_node, main_view)!;
renderer.finish_view(main_view)!;
renderer.end_frame()!;
```

`Renderer.render` and `render_to` accept the same `FrameInfo`. A zero reference selects origin zero. A nonfinite
reference faults `c3d::INVALID_ARGUMENT` before changing frame state.

## Concepts

### Origin selection

`render::frame_origin_for` rounds each reference coordinate to the nearest multiple of 256 metres. Half-cell ties go
toward positive infinity: 128 selects 256 and -128 selects zero. The selected `Renderer.frame_origin` stays fixed from
`begin_frame` through submission or abort. The first frame and camera cuts use the current explicit reference; view
order does not select it.

Every view, shadow camera, producer view, trace preparation and probe update in the frame uses that origin. Cameras far
apart still share one origin, so pick a reference that suits the intended views. There is no independent coordinate
space per view.

### Coordinate contract

| Values | Space |
| --- | --- |
| Scene nodes, asset data, CPU picking, spatial queries, simulation | Absolute world or declared local space |
| `FrameInfo.reference_position`, `ViewDesc.clip_plane`, debug line endpoints | Absolute world |
| `FrameRoot.origin.xyz` | Absolute origin; `w` is zero |
| Current draw models, GPU instance models, frame camera, light and probe positions, trace rows and rays | Absolute world minus the frame origin |
| Current view and projection matrices, clip plane, reconstructed scene positions | The same relative space |
| Geometry, joint palettes, morphs, instance placement sources, water waves | Existing local spaces |
| Previous models and previous view projection | The origin recorded with that view's previous rendering |

The renderer converts before it transforms retained local bounds and composes local instance placements. Subtracting the
origin from an already rounded absolute AABB or composed instance matrix cannot recover lost detail. `maths::rebase`
preserves an affine matrix's basis, scale and homogeneous row. Spatial bound helpers accept an optional origin;
omitting it keeps their absolute-world result.

The shader ABI appends `FrameRoot.origin` at byte 512; `FrameRoot` is 640 bytes. Rebuild consumer shader packages against
the current generated headers.

## Usage

### Write custom shader stages

Custom stages that use the published mesh, lighting, fog, scene-read and trace helpers receive compatible relative
values. Application-provided absolute positions in custom payloads must be converted before they combine with these
values. Add `frame.origin.xyz` only when an absolute value is required; doing so reintroduces float precision limits.
Directions and local positions do not receive this offset. Do not subtract the origin again from core-packed models.

### Persistent data and history

- Resident mesh, billboard and LOD records carry the origin used to pack them. An unchanged batch reuses its allocation
  and data within a cell. Crossing a cell rewrites each consumed batch once, shared by all views.
- Raster history records its origin with its view projection and pose. A reference change preserves valid temporal
  history: previous models and camera reprojection account for the origin difference. Camera velocity combines the
  clip-to-clip mapping in double precision on the CPU before narrowing it for the shader.
- LOD placement history has an independent origin, because its last rendering need not match another view. Aborting a
  staged view invalidates that history.
- Path accumulation resets when the packing origin changes, then resumes on unchanged frames, so it never mixes samples
  from different trace transforms.
- `prepare_scene_trace` inside a frame uses the frame's origin. Between frames it uses the most recently selected origin,
  initially zero. A later frame with a different origin rewrites the top-level data before use, and local acceleration
  data stays reusable. The root address is stable, but its contents and coordinate space can change; see
  [scene tracing](scene_trace.md#prepare-a-scene-trace).

### Shadows, effects and add-ons

- Directional cascades fit relative camera and caster bounds while keeping a world-fixed shadow texel lattice. Changing
  only the render reference preserves that lattice. Physically translating the whole scene can change its phase against
  the lattice, and with it the sampled shadow edge.
- Sway compensates for the origin in its packed phase, including previous-frame sway. Distance fade compares relative
  anchors and cameras.
- Height fog converts its base height with the camera. An atmosphere's cache identity keeps absolute physical altitude,
  and a camera's altitude is its packed y plus the origin's y ([sky](sky.md#units-and-the-altitude-datum)). Probe
  movement tracking stays absolute, so reference changes preserve atlas storage and partial sweep progress.
- Terrain, water, foliage and particle rendering use the same contract. Their CPU simulation, authoring coordinates,
  seeds and local wave functions are unchanged. Impostor baking selects a reference for its capture scene.
- Simulation add-ons (physics, character, navigation, particles, audio) keep their own state in absolute coordinates;
  [origin rebasing](origin_rebasing.md) moves them together with the scene.

## Limits

- Camera-relative rendering improves calculations after the scene has accepted float inputs. It does not restore
  precision lost when storing absolute positions, updating a distant hierarchy or running a simulation. Nearby local
  placements keep more detail when their parent translation is removed before composition. The application owns
  simulation precision and scene-coordinate policy.
- One origin per frame; views far apart share it.
- The shadow lattice phase can change when the scene translates by a fraction of a texel.

## See also

- [Origin rebasing](origin_rebasing.md) for shifting the scene, renderer and simulation owners together
- [Views](views.md), [scene tracing](scene_trace.md), [sky](sky.md), [shadows](shadows.md)
