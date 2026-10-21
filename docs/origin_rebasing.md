# Origin rebasing

An application whose active area drifts far from the origin can move the origin between frames. The scene, the renderer's
retained state and each simulation owner subtract the same horizontal offset, so nothing restarts and static nodes do not
read as moved. This page owns the shift protocol. The renderer's coordinate contract is in
[camera-relative rendering](large_world.md).

## Quick start

```c3
scene.shift_origin(offset);
scene.shift_particles(offset);
scene.update_world();
scene.shift_foot_contacts(offset);
physics.shift_origin(&scene, offset);
scene.shift_characters(offset);
nav_mesh.shift_origin(offset);
builder.shift_origin(offset);
crowd.shift_origin(offset);
grid_cache.shift_origin(offset);
scene.shift_navigation(offset);
scene.shift_foliage();
audio.shift_origin(offset);
renderer.shift_origin(&scene, offset);
scene_index.refresh(&assets, &scene)!;
```

Call only the owners the application has. The offset has `y == 0`. A good choice is `render::frame_origin_for(focus)` with
`y` set to zero: a 256 m cell multiple near the focus. Pass `FrameInfo.reference_position` in the shifted space on the next
frame.

## Concepts

### Protocol

Call the shift between `end_frame` and the next simulation update. A shift after an update loses that frame's velocity:
it reads as zero motion. No frame may be open (`Renderer.shift_origin` requires `!frame_open`). Join background work that
reads positions first. Each owner the application has gets the same offset, in this order:

1. `scene.shift_origin(offset)`.
2. `scene.shift_particles(offset)`, before `update_world`: it resets the world-space draw child that `Scene.shift_origin`
   moved.
3. `scene.update_world()`.
4. `scene.shift_foot_contacts(offset)` shifts retained `FootIk` contacts. A standalone `FootContact` uses its own
   `shift_origin` instead; do not shift one state through both owners. Support-local anchors stay unchanged, and support
   owners supply their already-shifted frame before the next contact update.
5. The simulation owners shift their state. `PhysicsWorld.shift_origin` takes the scene, and `Scene.shift_characters`
   moves characters. Navigation shifts the mesh, the builder (join tile builds on other threads first), the crowd, a
   `GridCache` (join its workers first) and `Scene.shift_navigation`; a `NavQuery` the application holds itself needs
   `NavQuery.shift_origin`. See [navigation grid caches](#navigation-grid-caches).
6. `scene.shift_foliage()` stores the current node worlds as the scatter poses so no layer re-scatters.
   `AudioSystem.shift_origin(offset)` moves positioned one-shots; emitters follow their nodes.
7. `renderer.shift_origin(&scene, offset)`, last, so it reads the final worlds.
8. `SceneIndex.refresh(&assets, &scene)` when the application keeps one.

### Scene

`Scene.shift_origin` subtracts the offset from `local.position` of every live root child and every live world-space node,
each once. Nested nodes keep their locals. `Scene.world_shift` accumulates the total offset in double precision. The
root must have an identity rotation and scale. World matrices are stale until `update_world`.

For a cell-multiple offset, a root child's or world-space node's world translation after `update_world` is exactly
`old - offset` when the node now sits nearer the origin. A nested node's world is recomposed at the smaller magnitude
and can differ from `old - offset` by up to one ulp of the old magnitude (3.9 mm at 50 km).

### Renderer

`Renderer.shift_origin(scene, offset)` touches only state keyed to that scene's identity; other scenes the renderer draws
are untouched. It does not change `frame_origin`, which `begin_frame` recomputes from the reference position.

| State | Change |
| --- | --- |
| View history of the scene | Previous models are set from the current node worlds, so every static node has zero rebase-frame motion, nested nodes and world-space draw children included; the history origin moves by the offset |
| LOD placement history of the scene | Both recorded origins move by the offset |
| `ViewDesc.clip_plane` of views that last rendered the scene | The plane distance moves so the same points stay inside |
| Resident instance, billboard and LOD records of the scene | Stored world and origin move by the offset |
| Scene trace of the scene | Baseline rows and origin move by the offset |
| Probe volumes of the scene | The traced grid origin of the fill state moves |

Every view that last rendered the scene, temporal or not, gets its stored clip plane shifted. An application that keeps
its own `ViewDesc` copy re-reads it after the shift, or `configure_view` restores the old plane. A view that has not
rendered the scene yet is the application's to set.

`ViewHistory.view_proj` is not refreshed, so a camera on a nested node (for example a character camera) can show up to
one old ulp of camera motion on the rebase frame, about 3.9 mm at 50 km. That is no more than its per-frame noise before
the shift.

Sway reads `Scene.world_shift`, so the gust phase of a fixed absolute anchor does not change across a shift. A second
scene the application does not rebase keeps its phase.

## Usage

### Application-owned state

The application shifts, or retakes after the shift:

- `spatial::SceneIndex`: call `refresh` after the shift.
- `HeightView`, `SurfaceView` and other query views taken from absolute data.
- Buoyancy surfaces and any callback returning absolute heights or positions.
- `GridHeightSampler.origin`, `GridHeightView.origin` and floor callbacks of navigation sources; see
  [navigation grid caches](#navigation-grid-caches).
- Absolute positions held in application structures, such as camera targets.
- A `ViewDesc` the application stores for `configure_view`: re-read it after the shift.

### Navigation grid caches

A `GridCache` holds world positions of its own: the source origin, cached and staged layers, obstacles and the jobs it has
captured. `GridCache.shift_origin(offset)` moves them without rebuilding a tile, and leaves dirty marks, revisions and
requests as they are. Within the protocol above, the navigation owners go in this order:

1. `scene.shift_origin(offset)` and `physics.shift_origin(&scene, offset)`.
2. `NavMesh.shift_origin`, `NavQuery.shift_origin` and `Crowd.shift_origin`. The mesh a cache publishes into is the
   application's.
3. `GridCache.shift_origin(offset)`, with no worker running a cache job.
4. The source behind the cache: subtract the offset from a `GridHeightSampler.origin` or `GridHeightView.origin`, and
   retake views taken from absolute data (see [terrain](terrain.md#navigation)). World-space obstacle positions and
   floor callbacks the application keeps follow the offset.

A later `GridCache.set_source` passes `GridCache.source_origin()` as its x and z origin and faults
`c3d::INVALID_ARGUMENT` for any other. Use the 256 m multiples of the rebase step, which keep origins exactly
representable. Another offset also works; the shifted layers then agree with a build at the new origin within float
rounding, and seams between shifted and later rebuilt tiles rely on the link tolerance.

### Shadow lattice

The cascade texel lattice snaps in absolute coordinates. An offset that is not a multiple of the texel size moves the
lattice phase once, so shadow edges can shift by a fraction of a texel on the rebase frame.

## Cost

With a per-axis cell-multiple offset and shifted nodes that are root children or world-space nodes, the next frame packs
bitwise the same relative data as without the shift. There is no instance re-upload, no top-level rebuild and no
accumulation reset. Nested content, whose worlds gained precision, repacks its trace rows once, without motion; its
instance records hold no world and do not rewrite.

An offset that is not a cell multiple changes the packing origin like any reference change: trace rows and billboard
records rewrite once and path accumulation resets.

Other renderer caches key on the relative values or recompute per frame and need no change: volumetric fog, ambient
occlusion, auto exposure, reflection captures, the atmosphere (it keys on altitude, which a horizontal shift keeps),
shadow sets, decals, clusters, terrain selection, water mirrors and particle draws.

## Limits

- The offset is horizontal: `y == 0`.
- The scene root needs an identity rotation and scale.
- No frame may be open, and background work that reads positions must be joined first.
- An offset that is not a multiple of 256 m rewrites trace rows and billboard records once and resets path accumulation.
- Rebasing does not restore precision lost in simulation state held far from the origin.

## See also

- [Camera-relative rendering](large_world.md)
- [Terrain](terrain.md#navigation) for height sources, [navigation add-on](../addons/c3d_nav.c3l/README.md) for grid caches
- The shadows example's Rebase button runs the protocol with the camera's frame origin and shifts its orbit target
