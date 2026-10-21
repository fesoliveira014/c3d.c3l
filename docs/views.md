# Views and render targets

A view is a renderer-owned record that renders the scene from one camera into one output: the window or an
application-owned render target. The default view (`renderer.default_view`) writes the window; the application creates
further views. One frame renders any number of views in application order and submits them together. Everything here
lives in `c3d::render`; every `ViewDesc` field, fault and capacity is in the [views reference](views_reference.md).

## Quick start

A producer view renders into a target and the window view shows the scene, using a live `Renderer renderer`, `Scene
scene` and two camera nodes. Import `c3d::material`, `c3d::render` and `c3d::render::post`.

```c3
RenderTargetId capture = render::create_render_target(&renderer,
    render::render_target_desc(512, 512, PixelFormat.RGBA8_SRGB))!;
defer (void)render::destroy_render_target(&renderer, capture);

ViewDesc desc = render::texture_view_desc(capture, OutputMode.DISPLAY_LDR);
desc.post.anti_aliasing = AntiAliasing.NONE;
ViewId capture_view = render::create_view(&renderer, desc)!;
defer (void)render::destroy_view(&renderer, capture_view);

// Each frame:
renderer.begin_frame(info)!;
defer catch render::abort_frame(&renderer);
renderer.render_view(&scene, producer_camera, capture_view)!;
renderer.finish_view(capture_view)!;
renderer.render_view(&scene, camera, renderer.default_view)!;
renderer.finish_view(renderer.default_view)!;
renderer.end_frame()!;
```

Create and configure views and targets between frames. Destroy views before the targets they write.

Run `python3 scripts/build.py --example views`. Its panel resizes the capture target, switches it between display and
linear output, and shows a mirror floor built with the [planar reflection](#planar-reflections) recipe. For
`--gpu-timings`, build the example with the profiler add-on:

```bash
c3c build views --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL
./examples/build/views --gpu-timings
```

## Concepts

- **Output.** A `WINDOW` view writes the swapchain image; a `TEXTURE` view writes a render target. A headless
  renderer's window views hold no images and record nothing.
- **Working extent.** A view renders at `working_extent(viewport, output_width, output_height, render_scale)`, at least
  one pixel per dimension. `render_scale` below 1 renders cheaper than the viewport and above 1 supersamples, up to
  `MAX_RENDER_SCALE` (2.0). The view owns its working images at that extent: `hdr_color`, `depth`, scene snapshots,
  post and effect images. A raster view also owns fixed-size sky tables ([sky](sky.md)).
  [Images per setting](views_reference.md#images-per-setting) lists them.
- **History.** A view keeps the camera, poses and accumulated state of its last rendering for temporal effects. The
  history is keyed by scene identity, so replacing a scene needs no reset. `render::reset_view_history(&renderer,
  view)`, called with no frame open, is the camera cut: it forgets the previous pose, adapted exposure and focus, and
  the fog and cloud history. Every `configure_view` and every resize resets the history except the [adapted
  exposure](post.md#auto-exposure) and [adapted focus](post.md#auto-focus), which a resize or a parameter edit keeps.
- **Frame order.** The application orders the views inside a frame. A producer view renders before the view that
  samples its target. There is no render graph.
- **Frame origin.** Set `FrameInfo.reference_position` to the current absolute camera position when rendering far from
  the origin. `begin_frame` selects one shared origin before any view or trace work, and producer and mirror views use
  it too. The default reference is zero. Clip planes stay absolute at the API boundary. See
  [camera-relative rendering](large_world.md).

## Create a render target

```c3
RenderTargetId target = render::create_render_target(&renderer,
    render::render_target_desc(1024, 1024, PixelFormat.RGBA16_FLOAT))!;
```

`render_target_desc(width, height, format = RGBA16_FLOAT)` accepts `RGBA16_FLOAT`, `RGBA32_FLOAT`, `RGBA8_UNORM` and
`RGBA8_SRGB`; other formats fault `c3d::UNSUPPORTED`. Every target is a color attachment, sampled, and a transfer
source.

- `resize_render_target(&renderer, target, width, height)` keeps the id, recreates the image once outstanding frames
  complete, increments the target's revision and resizes every view that writes it. It allocates the new image and
  every view's new images before it releases an old one, so a fault leaves the target, its revision and its views
  unchanged.
- `destroy_render_target` faults `c3d::RESOURCE_IN_USE` while a live view writes the target; destroy the views first.
- A full pool faults `c3d::CAPACITY_EXCEEDED`; see [capacities](views_reference.md#capacities).
- Renderer teardown releases the remaining views, then the targets.

## Create a view

`create_view(&renderer, desc)` allocates the view's images and returns a `ViewId`; `configure_view(&renderer, view,
desc)` replaces its configuration; `destroy_view(&renderer, view)` releases it after submitted work completes.

```c3
ViewDesc desc = render::default_view_desc();
desc.msaa = MsaaSamples.FOUR;
render::configure_view(&renderer, renderer.default_view, desc)!;
```

- Start from `default_view_desc()` (a full-window `DISPLAY_LDR` view) or `texture_view_desc(target, color =
  LINEAR_HDR)`, then change fields. The [reference](views_reference.md#viewdesc) lists every field and default.
- `LINEAR_HDR` keeps scene-linear color in physical units and needs a float target. `DISPLAY_LDR` grades, tone maps
  and optionally anti-aliases.
- `configure_view` waits for outstanding frames and reallocates when the extent or output changes; otherwise it
  allocates what the new settings need and retires what they drop. It allocates before it releases, so a fault leaves
  the view's configuration, images and history as they were. Near capacity it needs room for the old and the new
  images at once.
- Validation faults are listed under [faults](views_reference.md#faults). `destroy_view` on the default view faults
  `c3d::INVALID_ARGUMENT`.
- A window resize resizes every window view; a target resize resizes every view on that target.

## Render a frame

```c3
renderer.begin_frame(info)!;
defer catch render::abort_frame(&renderer);
renderer.render_view(&scene, camera, view)!;
renderer.finish_view(view)!;
renderer.end_frame()!;
```

- `render_view` extracts, uploads and records the scene passes, debug lines, velocity and motion blur.
  `finish_view` records depth of field and writes the view's output: `DISPLAY_LDR` grades, tone maps and optionally
  anti-aliases into the output rectangle; `LINEAR_HDR` copies the scene-linear image into the target, divided by the
  view's [pre-exposure](post.md#pre-exposure).
- `render_view(scene, camera_node, view, debug = null, shadow_camera = null)`. `debug` is a `DebugDraw` sink drawn
  after transparency. `shadow_camera` is the camera the view's [shadow set](shadows.md#shadow-sets) is fitted to; null
  uses `camera_node`. A `shadow_camera` without a `Camera` faults `c3d::INVALID_ARGUMENT` and aborts the frame.
- Between `render_view` and `finish_view`, a compute dispatch may read the view's depth and read or write its scene
  image ([custom shaders](custom_shaders.md#views)).
- `end_frame` faults `c3d::INVALID_ARGUMENT` when a rendered view was not finished. It records pending uploads and
  environment preparations, submits when the frame recorded a clear, draw, dispatch, upload or preparation, presents
  only when a window image was acquired, and discards a frame that recorded nothing. Neither `begin_frame` nor
  `end_frame` advances animation or flushes scene removals.
- A window view records nothing while the window is dormant (`renderer.has_output` is false); a texture view always
  records. Draw overlays only when `has_output` is true ([overlay](overlay.md), [GUI](gui.md)).
- When the window output changed, `begin_frame` resizes the swapchain and then every window view. If the new images
  fault, `begin_frame` returns the fault, the window views keep their previous size, and the next `begin_frame`
  retries; render nothing until a `begin_frame` succeeds. A swapchain rebuilt at a zero extent (a minimized window)
  leaves the window views as they are, so their images stay allocated while the window is minimized.
- `Renderer.render(scene, camera)` is the default-view convenience for one frame.
- `set_view_overlay(view, list)` gives a view an overlay list of items anchored in the world for one frame;
  `finish_view` draws it over the view's output after post, tested against the view's depth ([world-space overlay
  items](overlay_world.md)).

### Frame queries

- `Renderer.frame_was_submitted(frame)` reports whether the frame that had the index `frame` (a value of `frame_index`
  read while it was open) was submitted. It is false for the open frame, for a frame that faulted or was discarded,
  and for a frame more than `FRAMES_IN_FLIGHT` indices behind `frame_index`. Commit CPU state that mirrors GPU work
  only when it is true.
- `Renderer.view_depth_frame(view)` returns the index of the last submitted frame whose rendering of the view wrote its
  depth image. It faults `render::NOT_READY` before the first such frame and after a resize or a `configure_view` that
  recreates the images, and `c3d::INVALID_ID` for a dead view. A path-traced rendering never sets it; a view switched
  to `PATH_TRACED` in place keeps reporting its last raster frame. A dispatch that names
  `read_view_depth(view)` before the view's `render_view` of the open frame reads the depth of the frame this reports,
  so a reader that kept that frame's camera knows the two belong together. A view the application does not render
  every frame reports an older frame; the reader decides whether that depth still serves.

### Render once

`render_to(scene, camera, target, color = LINEAR_HDR, info = {})` renders and finishes one frame into a target through
a view it creates and destroys, without touching the window. It waits for completion, so it is a bake path, not a
per-frame one. It takes a view slot and must run with no frame open.

## Sample a target in a material

```c3
Material* monitor = &assets.material(monitor_material).data;
monitor.basic.map.texture = { .kind = RENDER_TARGET, .target = capture };
assets.mark_material_dirty(monitor_material);
```

A `TextureRef` of kind `RENDER_TARGET` resolves to the target's current sampled view when the material is packed. The
packed binding carries the target revision, so a resize repacks the material without an edit. A dead target resolves
to the built-in white texture.

- Before a view's first pass, the renderer transitions every target its materials reference to fragment read, except
  the view's own output.
- The application orders the producer view before the consumer and keeps the consumer's surfaces out of the producer
  camera's layers, so no view samples the image it is writing.
- Use `DISPLAY_LDR` output on an sRGB target for an unlit "monitor" surface, and `LINEAR_HDR` on a float target for
  reflection or composition inputs.

## View textures

```c3
TextureSlot[material::MAX_CUSTOM_TEXTURE_SLOTS] slots = material::CUSTOM_SLOTS_DEFAULT;
slots[0] = material::view_texture_slot(0);
MaterialId surface = assets.add_material(material::custom(shader, slots: slots))!;

renderer.set_view_texture(first_view, 0, first_capture)!;
renderer.set_view_texture(second_view, 0, second_capture)!;
```

A custom-material slot of kind `VIEW` names a texture the drawing view supplies, so one material shows a different
target in each view. `set_view_texture(view, slot, target)` binds a render target to the view's `slot`, below
`MAX_VIEW_TEXTURES` (4); a zero target clears the slot. The stage reads the slot through the frame
([view-provided slots](custom_shaders.md#view-provided-slots)); a view that provides nothing for it reads the slot as
absent, and the stage's own fallback runs.

- **Faults.** A dead view or target faults `c3d::INVALID_ID`. A view's own output target faults
  `c3d::INVALID_ARGUMENT`, as does a `configure_view` that would make a provided target the view's output.
- **Lifetime.** Bindings belong to the view. `configure_view`, a resize included, keeps them; `destroy_view` drops
  them. A target destroyed after it was provided reads as absent.
- **Ordering.** Before the view records, the renderer transitions each live provided target to the sampled state, as
  for a target in a material slot. Render the producer view before the consumer view.
- **Frame roots.** The view's depth prepass, G-buffer, velocity and scene-read passes share its frame root and see its
  textures. Shadow layers, probe updates and the path tracer provide none, so a view-provided slot reads as absent
  there: a shadow layer is rendered from the light and shared by the views that borrow its set.
- **Scope.** Only custom-material slots take a `VIEW` reference. A built-in material, or slot 0 of a masked custom
  material, faults `c3d::UNSUPPORTED` when uploaded. A `view_slot` of `MAX_VIEW_TEXTURES` or above faults
  `c3d::INVALID_ARGUMENT`, as does an [overlay](overlay.md#coordinates-colors-textures) rectangle with a `VIEW`
  reference.
- **Cost.** 16 bytes of `FrameRoot` per view per frame. The material block is written once per revision.
- **Use.** A [water](water.md#the-mirror) body samples its planar reflection at the view texture slot named by its
  `reflection_view_slot`. The application renders each mirror, calls `set_view_texture(viewing_view, slot,
  mirror_target)`, then renders the viewing view.

## Read a target back

`renderer.read_render_target(target, pixels)` copies a render target into caller memory. It runs with no frame open,
waits for every submitted frame and then for its own copy, so it is for stills, tests and captures rather than every
frame.

- `pixels.len` must equal width x height x the texel size (`render_target_texel_bytes`: 4 for `RGBA8_UNORM` and
  `RGBA8_SRGB`, 8 for `RGBA16_FLOAT`, 16 for `RGBA32_FLOAT`), otherwise it faults `c3d::INVALID_ARGUMENT`. A dead
  target faults `c3d::INVALID_ID`.
- Rows are tight and top row first, and the bytes come back as stored: sRGB-encoded for `RGBA8_SRGB`, half floats for
  `RGBA16_FLOAT`.
- A `DISPLAY_LDR` view writes linear values and relies on an sRGB format to encode them. Capture display output for
  an image file on an `RGBA8_SRGB` target and write it with `image::write_png`. An `RGBA8_UNORM` target would
  write a dark PNG.

## Clip plane

`ViewDesc.clip_plane` drops the geometry on one side of a world plane, for planar reflections (water, floor and wall
mirrors) and section views. A point stays when `dot(normal, point) + d >= 0`, the rule `maths::Plane` states; the
normal is unit length. The zero plane (`{}`) clips nothing, and both constructors produce it.

```c3
ViewDesc desc = render::texture_view_desc(mirror_target);
desc.clip_plane = { .normal = { 0, 1, 0 }, .d = -water_level }; // keeps y >= water_level
ViewId mirror_view = render::create_view(&renderer, desc)!;
```

| Pass or effect | Clipped |
| --- | --- |
| Depth prepass, G-buffer, forward opaque, scene reads, transparent | Yes, per vertex; every `EQUAL` pass tests against the same clipped depth |
| Geometry velocity | Yes, in the built-in and in custom velocity forms |
| TAA, motion blur, depth of field, ambient occlusion, screen-space GI, cluster depth | Through the clipped depth and velocity |
| Sky | No; it fills what the plane removed |
| Debug lines | No |
| Shadow atlas | Never; casters behind the plane still cast |
| Ray-traced shadows, ambient occlusion and reflections | No; secondary rays trace the whole scene |
| Probe updates, light extraction, picking | No |

- Every mesh vertex stage writes `gl_ClipDistance[0]` from the world position that feeds `gl_Position`, so the depth
  prepass, the G-buffer, `EQUAL` shading and velocity agree along the cut. Custom vertex stages clip through
  `write_mesh_outputs` or `view_clip.glsl` ([custom shaders](custom_shaders.md#vertex-contract)).
- `FrameRoot.clip_plane` holds `(normal, d)` when `FRAME_CLIP_PLANE` is set in `FrameRoot.flags`, and zero otherwise;
  any stage may read it.
- A `PATH_TRACED` view rejects a non-zero plane with `c3d::INVALID_ARGUMENT`, like the other raster-only settings.
- Extraction drops a mesh or batch whose world bounds lie wholly behind the plane and counts it in `Stats.culled`. A
  batch that straddles the plane is drawn whole: GPU instance culling ignores the plane, so its instances behind it
  are clipped, not culled.
- Changing only the plane through `configure_view` allocates and retires nothing, but like every configuration it
  resets the view's history. Set the plane once for a water level or a wall mirror; the mirror camera moves every
  frame, the world-space plane does not.
- Every mesh vertex stage declares `ClipDistance`, so the device must support `shaderClipDistance`; `create_renderer`
  faults `c3d::UNSUPPORTED` without it. Adapter selection prefers a discrete adapter without checking the feature, so
  on a machine whose discrete adapter lacks it, `create_renderer` faults even when another adapter has it.

### Planar reflections

A mirror view renders the scene from the main camera reflected across the plane, clipped to the plane's front side,
into a target that the reflective surface samples.

```c3
Plane floor_plane = { .normal = { 0, 1, 0 }, .d = -floor_level };
// Every frame, after moving the main camera and before scene.update_world():
Mat4 mirrored = maths::reflection_matrix(floor_plane).mul(camera_node.local.to_mat4());
mirror_node.local = maths::transform_from_affine(mirrored)!;
scene.get(mirror_node, Camera).aspect = main_aspect;
scene.get(camera_node, Camera).aspect = main_aspect;
// In the frame: the mirror first, fitted to the main camera, then the main view.
renderer.render_view(
    scene:         &scene,
    camera_node:   mirror_node,
    view:          mirror_view,
    shadow_camera: camera_node,
)!;
renderer.finish_view(mirror_view)!;
renderer.render_view(&scene, camera_node, main_view)!;
```

- `reflection_matrix(plane)` maps `p` to `p - 2 (n·p + d) n`; `transform_from_affine` stores the reflection as a
  negative x scale. The mirror camera's world matrix then has a negative determinant, and the renderer flips the
  view's front face for it, so single-sided surfaces keep their faces.
- The recipe reads `local` before `update_world`, so the reflection has no frame of lag, and assumes both camera nodes
  are roots. For a parented node, reflect the main camera's world matrix and express the result relative to the mirror
  node's parent.
- Exclude the reflective surface's layer from the mirror camera's `Camera.layers`, so the view never draws the surface
  that samples its target.
- Set both cameras' `Camera.aspect` to the main view's. The mirror records the main camera's
  [shadow set](shadows.md#shadow-sets) at its own working extent; with an explicit aspect the projections match at any
  mirror size, and the main view binds that set instead of recording one.
- The surface's fragment stage samples the target at `gl_FragCoord.xy / frame.camera_params.zw`: the mirror view
  projects a point on the plane where the main view does.
- Render the mirror view first and the view that shows the surface right after it. The renderer holds one shadow set
  at a time, so a view with another camera between them records over the mirror's set.
- A mirror view stays `LINEAR_HDR`, so it ignores auto exposure; the view that shows the surface meters the
  composited reflection as part of its image. The target holds physical radiance: the surface's stage multiplies the
  sample by `pre_exposed` ([pre-exposure](custom_shaders.md#pre-exposure)).
- World-space overlay items draw in a mirror view when their layers match its camera, reflected as the view shows them
  ([world-space overlay items](overlay_world.md)).
- Under [fog or an atmosphere](sky.md#where-fog-applies) a mirror view fogs only the path behind its plane, from the
  plane to the reflected surface. The view that shows the surface fogs the path to it, so the reflection carries the
  reflected path's fog once. Its [medium volumes](sky.md#medium-volumes) follow the same cut. The mirror view owns its
  own sky tables.
- Water from the landscape add-on places its mirror cameras and clip plane for you and reads each reflection from a
  view texture; see [water](water.md#the-mirror).

## Limits

- Views and targets are created and configured between frames only.
- There is no render graph: the application orders views, and a view must not sample a target it writes.
- A full view or target pool faults `c3d::CAPACITY_EXCEEDED`; `render_to`, `bake_impostor` and the reflection captures
  borrow a view slot for the length of the call.
- `LINEAR_HDR` needs a float target.
- A `PATH_TRACED` view rejects raster-only settings such as a clip plane, TAA and clustered lights.

## See also

- [Views reference](views_reference.md) for `ViewDesc`, faults, capacities and counters.
- [Shading paths](shading_paths.md), [MSAA](msaa.md) and [preparation](preparation.md).
- [Lights](lights.md) and [shadows](shadows.md) for per-view light selection and shadow sets.
- [Post-processing](post.md) for the display route and temporal effects.
- [Camera-relative rendering](large_world.md) for the frame origin.
