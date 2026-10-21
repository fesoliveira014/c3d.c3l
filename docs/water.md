# Water

The `c3d::landscape::water` module of the `c3d_landscape` add-on draws water. A `Water` component on a node is a lake (`BODY`) or an ocean that reaches the horizon (`OCEAN`). Its wave heights come from up to four Gerstner waves, a damped wave simulation stepped on the CPU, or a wind-sea spectrum evolved on the GPU ([wave models](water_wave_models.md)). The library owns the draw material, the child node that carries the water's [medium volume](fog.md#medium-volumes) and the mirror camera nodes. The application renders the mirror views and installs the buoyancy sampler.

The water surface refracts the scene behind it, reflects from a planar mirror, a screen-space march or the environment, shades foam and sun glints with the Standard shading parts, and shows Snell's window from below. A CPU twin of the wave sum answers height, normal and velocity queries.

The module imports the standard library, core (`c3d`), `c3d::landscape` and `c3d::landscape::terrain`. It never imports `gpu`, `c3d::render` or `c3d::physics`. The spectral model needs the `C3D_LANDSCAPE_GPU` feature, which adds the module `c3d::landscape::water_gpu`; it imports `c3d::render` to record the spectral passes. Without the feature, preparing a `SPECTRAL` body faults `UNSUPPORTED`. Core never imports the package.

Water uses the shared [frame origin](large_world.md): put the viewing camera's absolute position in `FrameInfo.reference_position` before rendering the mirror and main views.

## Quick start

Select `c3d_landscape` in `project.json` as [release.md](release.md) lists, then register the module once per scene, add a body to a node whose world matrix is current, and call `update` every frame.

```c3
water::register_water(&scene, &assets)!;
lake.layers = WATER_LAYER; // a layer bit of its own, so the mirror cameras leave the lake out
scene.update_world();

WaterDesc desc = water::default_water_desc();
desc.extent = 120;
water::add_water(
    scene:  &scene,
    assets: &assets,
    node:   lake,
    desc:   desc,
)!;

// every frame, after moving the cameras
scene.update_world();
water::update(
    scene:         &scene,
    assets:        &assets,
    wind_velocity: wind,
    time:          now, // the FrameInfo.time the frame renders with
);
renderer.render_view(&scene, camera, view)!;
```

`default_water_desc()` is a clear lake with two calm crossing waves. `extent` has no default. Without a mirror view, the surface reflects by screen-space march or from the environment; [The mirror](#the-mirror) adds the planar reflection.

## Frame order

1. Move the cameras and, for an ocean, the ocean node; call `scene.update_world()`.
2. Call `terrain::update` and `foliage::update` if the scene has them.
3. Call `water::update`.
4. For each viewing view and body, call `water::update_mirror` and follow the clip plane ([The mirror](#the-mirror)).
5. Take `water::surface_view`, set the `WaterFluid` time and current, call `physics.update(delta)`, then `scene.update_world()` ([Buoyancy](#buoyancy)).
6. Open the frame with `renderer.begin_frame(info)`. With spectral bodies, call `water_gpu::update` before `prepare_scene_trace` and before any view that draws the water.
7. Render each viewing view's mirror views, then the view itself.

## Concepts

- **Body and ocean.** A `BODY` is one grid of `ceil(extent / cell_size)` cells per side, centred on the node, or application geometry. Its waves live in the node's local XZ plane, so node scale scales them and node rotation turns them. An `OCEAN` is a quadtree of chunks that each view selects ([Ocean](#ocean)); its waves are anchored to the world.
- **Wave models.** `WaterDesc.wave_model` chooses how heights are computed and cannot change after the body exists.

  | Model | Surface | Agreement of the CPU twin with the drawn surface |
  | --- | --- | --- |
  | `GERSTNER` (default) | `waves`, summed in the vertex stage | 1 cm; `WaterSample.residual` reports the inversion's last step |
  | `SIMULATED` | A damped wave equation over the built grid | 1 cm; `residual` is 0 |
  | `SPECTRAL` | A JONSWAP sea, evolved and inverse-transformed on the GPU | A statistical bound, `WaterRuntime.spectral_bound` |

- **Library-owned nodes and assets.** The material, the medium node and the mirror camera nodes belong to the body; do not edit or remove them. A built grid is shared per shape and stays in the store after the body goes, and application geometry stays the application's. Remove the `Water` component or the node to remove the body.
- **Pending and prepared.** `attach_water` validates a desc and attaches `Water` without creating the mesh, material, medium or mirror cameras; `prepare` completes it. `add_water` does both. [Owner readiness](owner_readiness.md) states the shared rules for pending owners and their retry behavior. `update` skips pending water.
- **Time.** The vertex stage reads `FrameInfo.time` as a float. `sample_surface` and `update` take a `double` and narrow it the way the frame does, so queries see the time the surface is drawn at. Float time rounds visibly after 65,536 s (about 18 hours): wrap the application's clock and call `render::reset_view_history` at the wrap.

## Create a water body

- `register_water(scene, assets)` runs once per scene. It registers `Water`, `WaterRuntime` and `WaterMirror` and installs the remove hook with the store, which outlives the scene.
- `add_water(scene, assets, node, desc)` needs a node without `Mesh`, `InstancedMesh`, `Water` or `WaterRuntime`, with a current world matrix. It adds the shared shader, the grid, the owned double-sided material, the medium node, `max_mirrors` mirror camera nodes and the node's `Mesh` (an `InstancedMesh` for an ocean). It is all or nothing: a fault leaves the node, the scene and the store as they were.
- `attach_water`, `is_prepared`, `prepare` and `prepare_subtree(scene, assets, root = null)` split the same work. Publish world matrices before preparation.
- `set_desc(scene, assets, node, desc)` is the only way to change a prepared body. It checks the new desc first; a fault keeps the old state. `WaterRuntime.desc` holds the checked copy that `update`, the mirror and the queries read, so editing `Water.desc` directly has no effect. `set_desc` ends a running Gerstner sea-state blend (a spectral blend runs on) and writes the medium again. Every body keeps its `mode` and `wave_model`; an ocean, a simulated body and a spectral body also keep their `extent` and `cell_size`, and a spectral body keeps its `spectrum`. A change faults `INVALID_ARGUMENT`. It invalidates `Camera` pointers when `max_mirrors` shrinks.
- `update(scene, assets, wind_velocity, time)` runs every frame. It removes the parts of removed bodies, scrolls the ripples, advances sea-state blends, steps simulated bodies, advances spectral clocks and blends, and re-anchors oceans whose node moved. It takes no camera and places no mirror. It invalidates `Mesh`, `InstancedMesh` and `WaterRuntime` pointers when a `Water` was removed.
- Remove the `Water` component or the node. The next `update` removes the `Mesh` (or `InstancedMesh`), the medium node, `WaterRuntime` and the mirror nodes of a body whose `Water` is gone. Call `update` between removing and re-adding water on one node. Removing `WaterRuntime` or a mirror node directly is unsupported. Destroy the scene before the store.

The [reference](water_reference.md) lists every `WaterDesc` field with its rule, the constants and the faults.

## Query the surface

```c3
SurfaceView view = water::surface_view(&scene, &assets, lake.id)!;
WaterSample sample = water::sample_surface_detail(
    view:    &view,
    world_x: x,
    world_z: z,
    time:    now,
)!;
// sample.height, sample.normal, sample.velocity, sample.residual
```

- `surface_view` copies the body's waves and pose into a value. It requires a node with translation and rotation about Y only, and faults `INVALID_ID` for a dead node, a node without prepared water or a removed material. A `GERSTNER` or `SPECTRAL` view is a value that several threads may query. A `SIMULATED` view borrows the body's grid and answers the surface of the last `update`: take it after `update` and use it on the thread that steps.
- `sample_surface` returns the world height of the drawn surface on the vertical through a point. `sample_surface_detail` also returns the unit `normal`, the `velocity` of the surface point in m/s (the orbital velocity of the water) and `residual`. A point outside the rest rectangle faults `NOT_FOUND`.
- A Gerstner wave shifts points horizontally, so a query inverts the shift with fixed-point steps until a step is shorter than `WATER_QUERY_TOLERANCE` (0.1 mm) or `MAX_INVERSION_ITERATIONS` (8) steps ran. Validation keeps the mean steepness below 1, which makes the steps converge. `residual` is the length of the last step in metres.
- During a sea-state blend, `velocity` is that of the blended waves at the frame, not the rate at which the blend itself reshapes the surface.
- A simulated body ignores `time` and interpolates the drawn heights on the mesh's own triangles.
- Take the view again after `update`, after `set_desc` and after an origin shift.

## Set the sea state

```c3
water::set_sea_state(
    scene:              &scene,
    assets:             &assets,
    node:               lake.id,
    wind_velocity:      { wind.x, wind.z },
    transition_seconds: 4,
)!;
```

`set_sea_state` sets the waves to the sea a wind raises. `wind_velocity` is world m/s along x and z; the waves travel along it. The sea depends on the wind speed (capped at 25 m/s) and the fetch, which is the length of the rest rectangle along the wind: at 14 m/s a 120 m lake raises waves of about 0.08 m (significant height) and a 2 km body about 0.32 m. The four waves take fixed shares of the significant height and peak wavelength, and wavelengths floor at the larger of 1 m and two cells of a built grid or four cells of an ocean's finest level (1 m for application geometry). The sea is sized in world metres, so a scaled node draws the same sea.

For a Gerstner body the call writes the target into `Water.desc` and `WaterRuntime.desc` and returns. The next `update` starts a blend over `transition_seconds`; zero switches at once. A second call during a blend starts from the waves drawn then. The blend keeps the wave phase continuous. A saved scene keeps the target, not the blend. A spectral body keeps its wind in the prepared state only and writes neither desc: a saved scene does not keep the wind, and a loaded body starts from `DEFAULT_SPECTRAL_WIND`.

| Body | Result |
| --- | --- |
| `GERSTNER`, pending | Writes the target into `Water.desc` only |
| `GERSTNER`, prepared | Blends the four waves |
| `SPECTRAL`, prepared | Builds a new spectrum for the wind and blends to it |
| `SPECTRAL`, pending; `SIMULATED` | Faults `UNSUPPORTED` |

It faults `INVALID_ID` for a dead node or one without `Water`, and `INVALID_ARGUMENT` for a non-finite wind or a negative or non-finite transition.

## Ripples and wind

`WaterDesc.ripples` is a `STANDARD` material whose normal map the shader samples twice, at two crossing scales, through the reference's own UV transform, sampler and `normal_scale`, and adds to the wave normal. `uv0` is the rest position in metres, so the transform's scale sets the tile size (a `scale` of 0.25 repeats the map every 4 m). Other maps of that material are ignored. `update` turns the wind into two scroll velocities (`ripple_drift` m/s per m/s of wind) and starts a new scroll segment when they change, so the ripples never jump. A steady wind uploads nothing. The wind scrolls ripples only; the waves follow `set_sea_state`.

The ripple map has `COLOR` semantics with a linear encoding of `0.5 + 0.5 · n` in `RGBA16_FLOAT` or `RGBA32_FLOAT`. The shader reads the length of the stored vector at the sampled mip to widen the specular lobe where a minified map averaged slopes away; only that format keeps the length. An sRGB map is not valid. `NORMAL_*` semantics widen nothing and sparkle more. In `RGBA8_UNORM` the 8-bit rounding reads as shortening and roughens random texels.

## The mirror

The library places the mirror cameras and the application renders them. A body holds `max_mirrors` slots; each viewing view owns one slot of every body it sees and gives the body's material the slot's render target as a [view texture](views.md#view-textures) at `reflection_view_slot`.

`update_mirror(scene, body, slot, viewing_camera)` sets the slot's camera node to the viewing camera reflected across the image of the node's local XZ plane. The mirror camera copies the viewing camera's lens and drops the water node's layers. The call also writes `WaterRuntime.clip_plane`, the rest plane lowered by the total wave amplitude (a simulated body's reach), so everything above the deepest trough stays in the reflection. It returns `PLACED`. The viewing camera must be a root node; `update_mirror` reads its `local`, so it may run before or after `update_world`.

When the viewing camera is under the rest plane, `update_mirror` returns `BELOW`, leaves the pose and clip plane unchanged and puts the camera on no layer. Skip that mirror view and clear the view texture at the slot. The test is the rest plane, not the waves. `release_mirror(scene, body, slot)` frees a slot's camera for a viewing view that goes away and invalidates `Camera` pointers; the next `update_mirror` of the slot adds it again.

Once per viewing view and body, create the mirror target and view, after `add_water` and a first `update_mirror`:

```c3
RenderTargetId mirror_target = render::create_render_target(
    renderer,
    render::render_target_desc(viewer_size.x, viewer_size.y),
)!;
ViewDesc mirror_desc = render::texture_view_desc(mirror_target);
mirror_desc.render_scale = 0.5f; // a quarter of the pixels
mirror_desc.post.anti_aliasing = AntiAliasing.NONE;
mirror_desc.clip_plane = scene.get(lake, WaterRuntime).clip_plane;
ViewId mirror_view = render::create_view(renderer, mirror_desc)!;
```

Every frame, after `update_mirror` and before `begin_frame`, follow the clip plane. `set_desc`, a moved lake, the start and end of a sea-state blend, and a simulated body's reach or a spectral body's envelope all change it, and `configure_view` resets that view's history, so write it only when it changed.

```c3
Plane clip_plane = scene.get(lake, WaterRuntime).clip_plane;
ViewDesc current = renderer.views.get(mirror_view).desc;
if (clip_plane.normal != current.clip_plane.normal || clip_plane.d != current.clip_plane.d) {
    current.clip_plane = clip_plane;
    render::configure_view(renderer, mirror_view, current)!;
}
```

Set the viewing camera's `Camera.aspect` to the viewer's extent, once and when the output size changes, so the mirror's projection at its scaled extent equals the viewer's:

```c3
scene.get(viewing_camera, Camera).aspect = (float)viewer_size.x / (float)viewer_size.y;
```

In the frame, for each viewing view: render the mirror fitted to the viewing camera, give the view its texture, then render the view.

```c3
// A viewer under the water (BELOW) renders no mirror and gets no texture at the slot.
RenderTargetId target;
if (mirror_state == MirrorState.PLACED) {
    Node* mirror = scene.node(scene.get(lake, WaterRuntime).mirrors[slot]);
    renderer.render_view(
        scene:         &scene,
        camera_node:   mirror,
        view:          mirror_view,
        shadow_camera: viewing_camera,
    )!;
    renderer.finish_view(mirror_view)!;
    target = mirror_target;
}
renderer.set_view_texture(view, desc.reflection_view_slot, target)!;
renderer.render_view(&scene, viewing_camera, view)!;
renderer.finish_view(view)!;
```

- **Per view.** Give each viewing view its own slot, mirror view and target, and give each target to its own viewing view. A view given another view's target shows that view's reflection. A view with none reads the slot as absent and falls back to the march, then the environment.
- **Several bodies in one view.** Bodies a view sees need distinct `reflection_view_slot` values, so a view reflects at most `MAX_VIEW_TEXTURES` (4) bodies. Each body has its own plane and needs its own mirror view. Give bodies one layer bit each to see one body in another's mirror; a level body never reflects another level body's top surface.
- **Order.** Render a viewing view's mirrors, then the view, then the next viewing view's mirrors. The renderer holds one shadow set at a time: the first mirror records the set fitted to the viewing camera and the others bind it ([shadow sets](shadows.md#shadow-sets)). A view with another camera between a mirror and its viewing view records over the mirror's set.
- **Resize.** `resize_render_target` keeps the target id; the view texture and the material follow its revision.
- **Cost.** One mirror view per viewing view and body, at the viewer's extent scaled by `render_scale`.

The reflection source follows the first row that applies:

| Condition | Reflection |
| --- | --- |
| The viewing view provides the reflection slot | The planar sample, never rejected |
| `march_reflections` is on | A 24-step screen-space march over four times the pixel's view distance; a miss falls through |
| Otherwise | The environment's specular cube, else the frame's ambient |

## Ocean

`WaterDesc.mode = OCEAN` draws a sea that reaches the horizon as an `InstancedMesh` quadtree under [box ranges](instancing.md#box-ranges), like the [terrain](terrain.md). Each node is an instance of one shared chunk of `OCEAN_CHUNK_CELLS` (64) cells per side, and each view selects the nodes it draws. The node's local XZ plane is the rest plane; mirrors, the clip plane, `surface_view`, the queries and `fluid_sample` work on it as for a body.

```c3
WaterDesc desc = water::default_water_desc();
desc.mode = OCEAN;
desc.extent = 20000;   // metres
desc.depth = 200;
desc.wave_count = 0;   // flat until set_sea_state: the default's 3.5 m wave is under the four-cell floor
water::add_water(
    scene:  &scene,
    assets: &assets,
    node:   sea,
    desc:   desc,
)!;

// every frame, before water::update: follow the view in whole steps
float step = water::ocean_snap_step(&desc);
sea.local.position.x = math::round(camera_position.x / step) * step;
sea.local.position.z = math::round(camera_position.z / step) * step;
scene.update_world();
```

- **Extent.** A chunk is `cell_size * OCEAN_CHUNK_CELLS` metres wide at the finest level and doubles at each level above. The tree has the next power of two of chunks per side at or above `extent / chunk`, at most `MAX_OCEAN_CHUNKS` (256), so it covers up to twice the requested extent, centred on the node. `WaterRuntime.rest_min` and `rest_max` hold what it covers; queries outside answer `NOT_FOUND`. At the default 1.25 m cell, 256 chunks cover 20 km and need 87,381 nodes.
- **Levels.** Each view selects its own levels with the terrain's defaults (split at 512 px, hysteresis 0.25, morph band 0.25). Tune the split threshold in place on the node's `InstancedMesh.quadtree.split_pixels` ([tuning in place](instancing.md#quadtree-selection)); `set_desc` keeps it. Vertices morph toward the coarser level, so level changes show no crack or pop.
- **Filtering.** Far levels draw a surface filtered of waves shorter than their lattice shows; CPU queries return the unfiltered surface. Where every wave is at least four cells of a level long, drawn and queried surfaces agree within 1 cm. Validation asks for four cells of the finest level, so the finest level draws every wave whole.
- **Anchoring.** An ocean's waves are anchored to the world: crests stay in place when the node moves, and queries read the same offsets. Move the node by multiples of `ocean_snap_step(&desc)`, so each level's vertices keep their world positions and the surface does not swim. `Scene.shift_origin` moves the node and `world_shift` together and uploads nothing ([origin rebasing](origin_rebasing.md)).
- **Far-field regularity.** A four-wave sea shows a regular pattern in the far levels where its crests cross, faint at 6 m/s and visible from 12 m/s. A `SPECTRAL` ocean shows none; use it for an ocean seen at high wind.
- **No tracing.** An ocean casts no shadow and `trace` faults `INVALID_ARGUMENT`.
- **Several oceans.** Two oceans with different anchors drift apart during a sea-state blend and keep the difference. Use one ocean per scene.

## Underwater

A body owns one child node, `WaterRuntime.medium_node` (named `water_medium`), that carries a core [`MediumVolume`](fog.md#medium-volumes). The view's fog pass absorbs and scatters through the water, and a camera can stand in it. The desc maps to the medium per colour channel:

- `absorption = -ln(absorption_color) / absorption_distance`, per metre;
- `scattering = absorption · a / (1 - a)` with `a = min(scatter_color, MAX_SCATTER_ALBEDO)` as the single-scattering albedo;
- `anisotropy = MEDIUM_ANISOTROPY` (0.6), forward-leaning;
- the box is the rest rectangle, `WaterDesc.depth` deep (`DEFAULT_WATER_DEPTH`, 40 m).

The fog pass cannot tell water from a submerged rock, so the box's top hangs `total amplitude + MEDIUM_SKIN` under the rest plane and no drawn surface falls inside it. Water not deeper than that has no medium. Absorption and scattering are per world metre; the box's extents, `depth` and offset are in the node's frame. An `absorption_color` of 1 on every channel is clear water and writes no medium.

- **Layers.** The medium node carries the body's layers; `update` and `set_desc` copy them again. A view that does not see the body does not take its medium.
- **Lifecycle.** `add_water`, `prepare` and `set_desc` write the medium; a sea-state blend writes it when it starts and ends. The node is the library's. A `MediumVolume` the application puts on the body's own node is its own: it adds to the water's where they overlap and stays when the body goes. Serialization omits the medium node; a loaded body adds it on `prepare`.
- **Where it applies.** Main, split and mirror views that keep the node take it, and a view keeps its nearest four media. A mirror view clips it at its plane. Probe updates, reflection captures and the path tracer take no media: a water surface they draw shows the bed unabsorbed.
- **From below.** The material is double-sided. When the viewing camera is under the rest plane, a back face shades from below: the ray refracts (index ratio 1.33 to 1) and shows the scene above inside the critical angle (48.75°, Snell's window), or reflects back into the water outside it (total internal reflection), by march if `march_reflections` is on, else from the environment. The window's edge fades into the reflection. Sun glints and foam do not run from below. Seen from above, back faces draw nothing.

## Scene traces

`WaterDesc.trace` puts the displaced grid of a `BODY` in [scene traces](scene_trace.md); an ocean is not traced. Ray-traced reflections and ambient occlusion, path-traced views, probe updates and global illumination then see the water surface, not the bed under it. Without `trace`, the water is absent from every trace.

- The mesh is the drawn one, not a [trace proxy](scene_trace.md#trace-proxies). The shader's `trace_pose.single` form ([trace pose](custom_shaders.md#trace-pose)) poses the grid every frame the time moves, so the traced surface is the one drawn in the same frame. A frame at an unchanged time poses nothing. A built grid carries a normals stream; application geometry without one traces with face normals.
- Cost: one posed slot, one dispatch with a thread per vertex and one refit or bottom-level update per traced body per frame. The cost follows the vertex count, so `cell_size` is its lever. A body that finds no posed slot is left out of the trace and counted in `Stats.trace_deform_overflow` ([capacity](scene_trace_reference.md#custom-trace-poses)).
- A hit on the water shades as any custom-material hit does: grey under Lambert lighting, with no foam, refraction, reflection or ripples.
- The water casts no shadow, so traced sun shadows ignore it. Traced shadows on the water work.
- Traced rows have front faces only (`Mesh.trace_facing` is `FRONT`), so a ray from under the surface passes through it. A [probe](probe_volumes.md) under the rest plane hits the back face and is excluded when more than a quarter of its rays do.

## Buoyancy

The physics add-on's `Buoyancy` component samples a fluid the application installs per world ([buoyancy](buoyancy.md)). `fluid_sample` is a ready sampler over one water body with the physics `FluidSampleFn` signature, and the water module does not import physics:

```c3
WaterFluid lake_fluid = { .view = view, .time = now, .current = { 0.5f, 0, 0 } };
physics.set_fluid_sampler(&water::fluid_sample, &lake_fluid);
```

`WaterFluid` holds the `SurfaceView`, the `FrameInfo.time` of the physics update's first step and a uniform current in m/s. `fluid_sample` returns the height `sample_surface_detail` finds at `time + step_offset` and writes the orbital velocity plus the current. Outside the rest rectangle it faults `NOT_FOUND`: no fluid there.

Each frame, after `water::update` and `set_desc`, take the view again, set the time and current, then call `physics.update`. Take the view again after an origin shift too. For several bodies, hold one `WaterFluid` per body and write a sampler that returns the first body that does not fault.

## Limits

- **Mirror.** One mirror per body and viewing view, at most `MAX_MIRRORS` (8) slots per body, and a view reflects at most `MAX_VIEW_TEXTURES` (4) bodies. Receivers outside the viewing camera's cascades read unshadowed in the reflection. The clip plane sits at the deepest trough, so geometry between a trough and the local surface can appear in the reflection.
- **March.** Opaque, masked and sky pixels of this view only; no blends, nothing off-screen or behind the camera.
- **Blends.** The water writes depth, so blended surfaces under it are hidden.
- **Temporal readers.** SSGI and temporal AO readers keep camera-only velocity ([screen-space GI](screen_space_gi.md), [temporal AO](ambient_occlusion.md#temporal)), so moving waves smear under TAA there.
- **Wave edits.** A `set_desc` that changes waves gives one frame of wrong motion vectors. A `set_sea_state` blend has exact vectors, but stretches the pattern about the node origin, so the per-frame height step grows with distance from it; a longer transition spreads it.
- **Ocean.** Finite (20 km at most at the default cell size) and moved by the application with the view. Far levels draw a filtered surface that queries do not. No tracing.
- **Queries.** They require translation plus rotation about Y; drawing takes any node transform. The twin of a spectral body is statistical.
- **Waterline.** The medium's top lies under the deepest trough, while the mirror and from-below tests use the rest plane. A camera between the box's top and a crest can stand under the water outside the medium, unfogged, and a camera within the wave reach of the plane takes the plane's side.
- **Lighting.** The sun lights glints and foam. The water's own colour is the medium's in-scatter, with no occluder shadowing and no indirect light.
- **Underwater views.** No light shafts or caustics. The window and reflection show this view's snapshot, and the environment past the frame's edge.
- **Grids and geometry.** Built grids are shared per shape and live as long as the store. Bodies do not match waves at a shared edge; two oceans match outside a blend.
- **References.** The ripple material contributes its normal map only; foam shows only with a foam reference.

## See also

- [Wave models](water_wave_models.md): Gerstner waves, the simulated surface and the spectral surface.
- [Reference](water_reference.md): `WaterDesc`, constants and faults.
- [Terrain](terrain.md) and [vegetation](vegetation.md): the rest of the landscape package.
- [Buoyancy](buoyancy.md), [sky](fog.md#medium-volumes), [views](views.md#view-textures), [scene tracing](scene_trace.md), [large worlds](large_world.md).
- The `water` example (`python3 scripts/build.py --example water`) builds a lake, an ocean and floating crates; `water_gpu` adds the spectral model.
