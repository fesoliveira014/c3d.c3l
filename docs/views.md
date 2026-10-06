# Views and render targets

A view is a renderer-owned record that renders the scene from one camera into one output: the
window or an application-owned render target. The default view (`renderer.default_view`) writes
the window; further views are created by the application. One frame renders any number of views
in application order and submits them together.

Set `FrameInfo.reference_position` to the current absolute camera position when
rendering far from the origin. `begin_frame` selects one shared origin before
any view or trace work; producer and mirror views use it too. The default
reference is zero. Clip planes stay absolute at the API boundary. See
[camera-relative rendering](large_world.md) for coordinate and history rules.

```bash
python3 scripts/build.py --example views
c3c build views --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL
./examples/build/views --gpu-timings
```

## Render targets

```c3
RenderTargetId capture = render::create_render_target(&renderer,
    render::render_target_desc(512, 512, PixelFormat.RGBA8_SRGB))!;
defer (void)render::destroy_render_target(&renderer, capture);
```

`render_target_desc(width, height, format = RGBA16_FLOAT)` accepts `RGBA16_FLOAT`, `RGBA32_FLOAT`,
`RGBA8_UNORM` and `RGBA8_SRGB`; other formats fault `UNSUPPORTED`. Every target is a color
attachment and sampled. `resize_render_target` keeps the id, recreates the image after outstanding
frames complete, increments the target revision, and resizes every view that writes the target. It
allocates the new image and every view's new images before it releases an old one, so a fault leaves
the target, its revision and its views as they were.
`destroy_render_target` faults `RESOURCE_IN_USE` while a live view selects the target: destroy the
views first. A full pool faults `CAPACITY_EXCEEDED` (`RendererDesc.max_render_targets`, 8 by default; see
[Capacities](#capacities)). Renderer teardown releases remaining views, then targets.

## Views

```c3
ViewDesc desc = render::texture_view_desc(capture, OutputMode.DISPLAY_LDR);
desc.post.anti_aliasing = AntiAliasing.NONE;
ViewId capture_view = render::create_view(&renderer, desc)!;
defer (void)render::destroy_view(&renderer, capture_view);
```

`ViewDesc`:

| Field | Meaning |
| --- | --- |
| `output` | `WINDOW` or `TEXTURE` |
| `target` | The `RenderTargetId` a `TEXTURE` view writes; ignored for `WINDOW` |
| `viewport` | `PixelRect` in output pixels; a zero extent covers the whole output |
| `render_scale` | Working resolution relative to the viewport, in `(0, MAX_RENDER_SCALE]` |
| `lod_bias` | Finite log2 bias for [whole-object LOD](lod.md); zero by default, positive adds detail |
| `color` | `DISPLAY_LDR` runs the display route; `LINEAR_HDR` keeps scene-linear color |
| `post` | The view's `PostStack` (see [display processing](post.md)) |
| `shading` | `FORWARD`, `DEFERRED` (see [Shading path](#shading-path)) or `PATH_TRACED` (see [path tracing](path_tracing.md)) |
| `depth_prepass` | A `FORWARD` view draws its opaque set into depth first and shades it once; on in both constructors |
| `instance_culling` | Batch instances are culled per instance on the GPU in this view, its depth prepass and its shadow layers (see [instancing](instancing.md#instance-culling)); on in both constructors |
| `lights` | `FLAT` or `CLUSTERED` candidate light selection |
| `clusters` | Editable `ClusterDesc`; ignored by `FLAT` |
| `ray_tracing` | `RayTracingDesc`: `shadows` (see [shadows](shadows.md)), `reflections` and `max_reflection_roughness` (see [reflections](reflections.md)); zero disables all |
| `ambient_occlusion` | `AmbientOcclusionDesc`; zero is off (see [ambient occlusion](ambient_occlusion.md)) |
| `screen_space_gi` | `ScreenSpaceGiDesc`; zero is off (see [screen-space GI](screen_space_gi.md)) |
| `path_trace` | `PathTraceDesc`: bounces, samples per frame and sample cap of a `PATH_TRACED` view (see [path tracing](path_tracing.md)) |
| `clip_plane` | World-space `maths::Plane`; geometry on its negative side is not drawn (see [Clip plane](#clip-plane)); the zero plane clips nothing and both constructors produce it |
| `volumetric_fog` | A froxel volume for the view's `HeightFog`, allocated with the view (see [volumetric fog](sky.md#volumetric-fog)); faults `INVALID_ARGUMENT` on a `PATH_TRACED` view |
| `share_shadows` | Binds an earlier view's [shadow set](shadows.md#shadow-sets) when the keys match and publishes its own; on in both constructors |

An installed [static impostor](lod.md#static-impostors) participates in the same
per-view LOD selection and hysteresis. Forward and deferred views share its
reconstructed surface depth. Shadow passes retain the main choice and select
atlas directions from the light. LOD or direction-triplet changes reject the
affected temporal pixels; stable placements retain velocity.

`default_view_desc()` is a full-window `DISPLAY_LDR` view with neutral grading and a depth
prepass and `ray_tracing.max_reflection_roughness` at `RT_REFLECTION_ROUGHNESS_DEFAULT`;
`texture_view_desc(target, color = LINEAR_HDR)` covers a target with the same defaults. `create_view` and `configure_view`
validate between frames: a dead target faults `INVALID_ID`; `LINEAR_HDR` on a window view or on an
RGBA8 target, a viewport outside the output, a render scale outside its range and an invalid post
stack fault `INVALID_ARGUMENT`; a `clip_plane` other than the zero plane with a normal that is not
unit length or a `d` that is not finite, and any non-zero `clip_plane` on a `PATH_TRACED` view, fault
`INVALID_ARGUMENT`; `volumetric_fog` on a `PATH_TRACED` view faults `INVALID_ARGUMENT`; invalid ambient occlusion settings fault `INVALID_ARGUMENT` and
`AoKind.RAY_TRACED` faults `UNSUPPORTED`; a full pool faults `CAPACITY_EXCEEDED` (`RendererDesc.max_views`, 8 by
default; see [Capacities](#capacities)).
`destroy_view` on the default view faults `INVALID_ARGUMENT`.

The view owns its working images (`hdr_color`, `depth`, the scene color and depth snapshots, the
[sky](sky.md)'s 192 × 108 sky-view table and 32³ aerial perspective volume (418 KiB) on raster views, its
[fog volume](sky.md#volumetric-fog) when `volumetric_fog` is on (7.03 MiB at 2560 × 1440), post and
effect images) at the working extent `working_extent(viewport, output, render_scale)`, at least one pixel
per dimension. Reconfiguring with a different extent or output waits for outstanding frames and
reallocates them; every configuration resets the view's history except its
[adapted exposure](post.md#auto-exposure), which a resize or parameter edit keeps. The history is otherwise keyed
by scene identity and needs no reset when a scene is replaced (`reset_view_history` remains the camera cut).
Window resize resizes every window view; target resize resizes every view on that target. A headless renderer's window views
hold no images and record nothing. `configure_view` and both resizes allocate the new images before they release the old
ones: a fault leaves every affected view with its configuration, images and history.

## Light selection

Both view constructors choose `FORWARD` / `FLAT` and initialize `clusters` with
`default_cluster_desc()`: 16 horizontal tiles, 9 vertical tiles, 24 depth slices,
64 finite lights per cell and a clustering far distance of 100 camera-view depth units. To enable it:

```c3
ViewDesc desc = render::default_view_desc();
desc.lights = LightSelection.CLUSTERED;
render::configure_view(&renderer, renderer.default_view, desc)!;
```

Create and configure views only between frames. The cluster fields are mutable:
`tiles_x`, `tiles_y`, `depth_slices`, `lights_per_cluster` and `far_distance`.
`CLUSTERED` requires nonzero dimensions/capacity, a positive finite far distance and
representable storage sizes (`INVALID_ARGUMENT`); a valid grid beyond the device's
compute dispatch limits faults `UNSUPPORTED`.
`FLAT` neither validates nor allocates from `clusters`, even if its fields are zero or
invalid. A zero-initialized descriptor does not acquire cluster defaults merely by
setting `lights = CLUSTERED`: start from a constructor or assign `default_cluster_desc()`.
GPU allocation, recording and wait faults propagate from the existing view operations.

Each drawable clustered view owns one private GPU buffer containing its complete
selected light array, cell ranges, fixed-capacity index segments and overflow counter.
It uses no application `BufferId` slot and is not part of the texture-only `view_targets`.
Grid/capacity changes replace this storage; changing only far distance does not.
Switching to flat retires the old allocation after submitted users complete; resizing,
destroying a view and renderer teardown likewise preserve in-flight ownership.

Selection uses the view's unjittered camera projection and each shaded position, not
the opaque depth buffer. Perspective depth slices are logarithmic; orthographic slices
are linear. Coverage ends at the lesser of the clustering far distance and the camera's
finite far plane. Perspective camera far zero means infinity; orthographic far zero
does not. An empty depth interval disables clustering for that rendering.

Finite point and spot lights are conservatively admitted by their range spheres.
Directional lights and range-zero point/spot lights are globals, evaluated once beside
the cell's finite list. Indices refer to the original selected light array, preserving
receiver layers and shadow mappings. The existing selection budget and dropped-light
policy are unchanged. A cell exceeding capacity, a position outside the grid/depth
interval, or inactive coverage uses the **complete flat list**, not a truncated list
or a clamped edge cell; globals are not appended again on fallback.

Standard, Toon and non-transmitting Physical materials use this selector, including
ordinary alpha-blended surfaces. Physical materials with nonzero prepared transmission
use the flat list for their entire direct-light loop, preserving exit-point lighting.
Existing custom shaders remain flat unless they opt into the
[shared light selector](custom_shaders.md#light-selection).

See [many lights](many_lights.md) for a controlled comparison and
[GUI diagnostics](gui.md#cluster-diagnostics) for slice occupancy and completed counters.

## Frames

```c3
renderer.begin_frame(info)!;
renderer.render_view(&scene, producer_camera, capture_view)!;
renderer.finish_view(capture_view)!;
if (renderer.has_output) {
    renderer.render_view(&scene, main_camera, renderer.default_view)!;
    renderer.finish_view(renderer.default_view)!;
    OverlayContext overlay = renderer.begin_overlay()!;
    gui.record(&overlay)!;
    renderer.end_overlay(&overlay)!;
}
renderer.end_frame()!;
```

`render_view` extracts, uploads and records the scene passes, debug lines, velocity and motion
blur; `finish_view` records depth of field and writes the view's output: `DISPLAY_LDR` grades, tone
maps and optionally anti-aliases into the output rectangle; `LINEAR_HDR` copies the scene-linear
image into the target. Between the two calls a compute dispatch may read the view's depth and read
or write its scene image (see [custom shaders](custom_shaders.md#views)); `end_frame` faults
`INVALID_ARGUMENT` when a rendered view was not finished. A window view records nothing while
the window is dormant (`has_output` false); a texture view always records. When the window output
changed, `begin_frame` resizes the swapchain and then every window view. If the views' new images
fault, `begin_frame` returns the fault, the window views keep their previous size, and the next
`begin_frame` retries; render nothing until a `begin_frame` succeeds. A swapchain rebuilt at a zero
extent (a minimized window) leaves the window views as they are, so their images stay in memory
while the window is minimized. `end_frame` records
pending uploads and environment preparations, then submits when the frame recorded a clear, draw,
dispatch, upload or preparation, presents only when a window image was acquired, and discards a
frame that recorded none. Neither call advances animation or flushes scene removals.

`render_view(scene, camera_node, view, debug = null, shadow_camera = null)`: `shadow_camera` is the camera the view's
shadow set is fitted to; null uses `camera_node`. A view binds an earlier view's set instead of recording one when
their keys match ([shadow sets](shadows.md#shadow-sets)). A `shadow_camera` without a `Camera` faults
`INVALID_ARGUMENT` and aborts the frame.

`Renderer.render(scene, camera)` is the default-view convenience. `render_to(scene, camera, target,
color = LINEAR_HDR, info = {})` renders and finishes one frame into a target through a view it
creates and destroys, without touching the window; it waits for completion and is a bake path, not
a per-frame one.

Pass timings (`Stats.gpu_pass_ms`) sum all measured view/pass instances in the completed
`Stats.gpu_frame_index`. Shadow timings retain all measured layers with their original view
ids. These delayed GPU results may lag the draw, dispatch and light counters; absent pass
measurements display N/A and truncated summaries are partial. See [profiling](profiling.md)
for the required build features and capture configuration.

`Stats.cluster_view`, `cluster_count` and `cluster_overflows` are delayed results read
only after the reused frame slot has completed, independently of GPU timestamp enablement.
They describe that slot's last recorded drawable view, not a sum across views: a later
flat view clears its cluster result, while a dormant/non-recorded view does not replace
it. `cluster_count` is the grid's total cells; `cluster_overflows` counts overflowing
cells, not dropped lights. The readback adds no synchronous wait inside `render_view`.

## Sampling a target

```c3
Material* monitor = &assets.material(monitor_material).data;
monitor.basic.map.texture = { .kind = RENDER_TARGET, .target = capture };
assets.mark_material_dirty(monitor_material);
```

A `TextureRef` of kind `RENDER_TARGET` resolves to the target's current sampled view when the
material is packed; the packed binding carries the target revision, so a resize repacks the
material without an edit. A dead target resolves to the builtin white texture. Before a view's
first pass the renderer transitions every target its materials reference to fragment read, except
the view's own output. The application orders the producer view before the consumer view in the
frame and keeps the consumer's surfaces out of the producer camera's layers, so no view samples the
image it is writing. Use `DISPLAY_LDR` output on an sRGB target for an unlit "monitor" surface and
`LINEAR_HDR` on a float target for reflection or composition inputs.

## Reading a target back

`renderer.read_render_target(target, pixels)` copies a render target into caller memory. It runs
with no frame open, waits for every submitted frame and then for its own copy, so it is for stills,
tests and captures rather than every frame. `pixels.len` must equal width x height x the texel size
(`render_target_texel_bytes`: 4 for `RGBA8_UNORM` and `RGBA8_SRGB`, 8 for `RGBA16_FLOAT`, 16 for
`RGBA32_FLOAT`), otherwise it faults `INVALID_ARGUMENT`; a dead target faults `INVALID_ID`. Rows
are tight and top row first, and the bytes come back as stored: sRGB-encoded for `RGBA8_SRGB`,
half floats for `RGBA16_FLOAT`. A `DISPLAY_LDR` view writes linear values and relies on an sRGB
format to encode them, so capture display output for an image file on an `RGBA8_SRGB` target and
write it with `image::write_png`. Every render target carries transfer-source usage for this.

## Capacities

| `RendererDesc` field | Zero selects | Bound |
| --- | --- | --- |
| `max_views` | `DEFAULT_MAX_VIEWS`, 8 | none beyond memory: a view record is 5.5 KiB |
| `max_render_targets` | `DEFAULT_MAX_RENDER_TARGETS`, 8 | at most the resolved `texture_capacity`, else `create_renderer` faults `c3d::INVALID_ARGUMENT` |
| `texture_capacity` | `gpu::DEFAULT_TEXTURE_CAPACITY`, 1,024 | 65,536 (`gpu::MAX_SHADER_HEAP_CAPACITY`), else `gpu::INVALID_ARGUMENT` |
| `texture_heap_capacity` | `gpu::DEFAULT_TEXTURE_HEAP_CAPACITY`, 4,096 | 65,536, else `gpu::INVALID_ARGUMENT`; past the device's descriptor limits no adapter qualifies and `create_renderer` faults `c3d::UNSUPPORTED` |

The pools are fixed at creation. A full pool faults `c3d::CAPACITY_EXCEEDED`. These take a view slot:

- the default view, from creation to teardown;
- every `create_view`;
- `render_to`, for the length of the call;
- `bake_impostor`, `capture_reflection_probe` and `recapture_reflection_probe`, for the length of the call. Each also
  takes one render-target slot.

An editor with a game view, two viewports and live thumbnails drawn through `render_to` needs `max_views` of at least
1 + 1 + 2 + 1.

Every working image of a view and every render target holds one texture-table entry and one heap slot. A render target
also holds one attachment view. So do a view's `hdr_color`, `depth`, scene snapshots, velocity, G-buffer and SSGI
color, at most 11 per view. gpu.c3l's attachment table holds 4,096 views and cannot be configured: a renderer with
three plain views holds at most 4,090 render targets, whatever `texture_capacity` allows. Asset textures share the
table and the heap with the renderer. `default_asset_store_desc()` holds 4,096 textures and the table 1,024 by
default, so a store filled past about 1,000 uploaded textures faults on upload unless `texture_capacity` is raised.

Images a view allocates at creation, by setting:

| Setting | Images |
| --- | --- |
| Raster view: `hdr_color`, `depth`, sky-view table, aerial perspective volume | 4 |
| `FXAA` | +1 |
| `TAA` | +6 history, +1 debug image with `TaaDebug` |
| `bloom` | +`bloom_params.levels` (5 by default, 8 at most) |
| `depth_of_field` | +4, plus the 2 tile images |
| `motion_blur` | +1, plus the 2 tile images |
| Velocity, under `TAA`, `motion_blur` or `screen_space_gi` | +1 |
| `DEFERRED` G-buffer | +5 |
| `ambient_occlusion` | +2 |
| `screen_space_gi` | +7 |
| `ray_tracing.reflections` | +2 |
| `volumetric_fog` | +1 |
| `PATH_TRACED`: accumulation, no sky images | 3 in all |

`texture_view_desc` and `default_view_desc` hold 5 images. A raster view with `TAA`, eight bloom levels and every
other row except the debug image, reflections and path tracing holds 41. Up to three images are allocated during a
frame: the scene color and depth snapshots inside `render_view` when a material reads the scene, and the FXAA fallback
output inside `finish_view` when FXAA cannot write the output rectangle directly. A headless renderer's default view
holds none.

Exhaustion faults come unchanged from gpu.c3l: a full texture table or attachment table faults `gpu::SLOT_TABLE_FULL`,
a full heap `gpu::DESCRIPTOR_HEAP_FULL`. Creation faults leave no partial resource: `create_view`,
`create_render_target`, `render_to`, `bake_impostor` and the captures release what they acquired. `render_view` and
`finish_view` can fault for the images they allocate; the frame aborts like any other fault. `resize_render_target`,
`configure_view` and the window resize in `begin_frame` allocate every new image before they release an old one, so a
fault changes nothing. They need room for the old and the new images at once: near capacity they fault where releasing
first would have fit.

To size the four fields, render representative frames until the next reading, at most `TEXTURE_STATS_INTERVAL` frames,
then read `Stats` and `ViewStats`; `ViewStats.images` is current every frame:

- `Stats.textures` and `texture_views` count live table entries and heap slots at frame start, and `texture_capacity`
  and `texture_heap_capacity` the resolved sizes. They are read every `TEXTURE_STATS_INTERVAL` (16) frames, because a
  reading walks the texture table: on an RTX 4090, 0.13 to 0.24 µs at 21 to 27 entries and 5.26 to 5.59 µs at 4,019
  (about 0.33 µs a frame over the interval).
  Images created inside a frame show at the next reading.
- `ViewStats.images` counts one view's live images at frame start, every frame.
- `gui::stats_panel` shows the four `Stats` fields, `gui::view_stats_table` the images per view.

Worked example, from the image table: a game view with `DEFERRED`, `TAA`, five bloom levels and `ambient_occlusion`
holds 23 images (4 + 6 + 1 + 5 + 5 + 2). The window view holds 5. Two editor viewports from `texture_view_desc` hold 5
each. A `render_to` thumbnail holds 5 while it renders. The game view, the viewports and 64 thumbnails write 67
targets. That is 110 entries and 110 heap slots. Add the uploaded asset textures, and the renderer's own images: the
shadow atlas, environment maps, atmosphere tables, built-in textures, probe volumes, reflection probes and the
swapchain images.
`Stats.textures` minus the views' and targets' share is that last amount, measured. With 2,000 asset textures the
table needs about 2,150 entries, so `texture_capacity = 2560` leaves headroom. A mipmapped or storage asset texture
can hold several heap slots, so size `texture_heap_capacity` from `Stats.texture_views`, not from the texture count.
The views need `max_views = 5` and the targets `max_render_targets = 67` or more.

Leave room for the largest single resize on top of that count, in the table, the heap and the attachment table: a target
plus the images of every view on it for `resize_render_target`, the images of every window view for a window resize,
or one view's full image set for `configure_view`. In the example the game target and its view take 24 more entries
and heap slots while they resize, which 2,560 covers.

Per-frame cost grows with `max_render_targets`: `begin_frame` and each view's preparation visit every target slot, and
`begin_frame` also visits every view slot to snapshot and count its images. On an RTX 4090 an empty frame took a median
of 44 µs at 8 target slots and 54 µs at 4,000 (three runs; 49 µs at both with the pool full).

## Clip plane

`ViewDesc.clip_plane` drops the geometry on one side of a world plane, for planar reflections
(water, floor and wall mirrors) and section views. A point stays when
`dot(normal, point) + d >= 0`, the rule `maths::Plane` states; the normal is unit length. The zero
plane (`{}`) clips nothing, and both constructors produce it.

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

Every mesh vertex stage writes `gl_ClipDistance[0]` from the world position that feeds
`gl_Position`, so the depth prepass, the G-buffer, `EQUAL` shading and velocity agree along the cut.
Custom vertex stages clip through `write_mesh_outputs` or `view_clip.glsl` (see
[custom shaders](custom_shaders.md#vertex-contract)). `FrameRoot.clip_plane` holds `(normal, d)`
when `FRAME_CLIP_PLANE` is set in `FrameRoot.flags`, and zero otherwise; any stage may read it. A
`PATH_TRACED` view rejects a non-zero plane with `INVALID_ARGUMENT`, like the other raster-only
settings.

Extraction also drops a mesh or batch whose world bounds lie wholly behind the plane and counts it
in `Stats.culled`. A batch that straddles the plane is drawn whole: GPU instance culling ignores
the plane, so its instances behind it are clipped, not culled.

Changing only the plane through `configure_view` allocates and retires nothing, but like every
configuration it resets the view's history. Set the plane once for a water level or a wall mirror;
the mirror camera moves every frame, the world-space plane does not.

### Planar reflections

A mirror view renders the scene from the main camera reflected across the plane, clipped to the
plane's front side, into a target that the reflective surface samples:

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

- `reflection_matrix(plane)` maps `p` to `p - 2 (n·p + d) n`; `transform_from_affine` stores the
  reflection as a negative x scale. The mirror camera's world matrix then has a negative
  determinant, and the renderer flips the view's front face for it, so single-sided surfaces keep
  their faces.
- The recipe reads `local` before `update_world`, so the reflection has no frame of lag, and
  assumes both camera nodes are roots. For a parented node, reflect the main camera's world matrix
  and express the result relative to the mirror node's parent.
- Exclude the reflective surface's layer from the mirror camera's `Camera.layers`, so the view
  never draws the surface that samples its target (see [Sampling a target](#sampling-a-target)).
- Set both cameras' `Camera.aspect` to the main view's. The mirror records the main camera's
  [shadow set](shadows.md#shadow-sets) at its own working extent; with an explicit aspect the projections match at
  any mirror size, and the main view binds that set instead of recording one.
- The surface's fragment stage samples the target at `gl_FragCoord.xy / frame.camera_params.zw`:
  the mirror view projects a point on the plane where the main view does.
- Render the mirror view first and the view that shows the surface right after it. The renderer holds one shadow
  set at a time: a view with another camera between them records over the mirror's set.
- A mirror view stays `LINEAR_HDR`, so it ignores auto exposure; the view that shows the surface meters the
  composited reflection as part of its image.
- Water from the landscape add-on places its mirror camera and clip plane for you; see [water](water.md#the-mirror).
- Under [fog or an atmosphere](sky.md#where-fog-applies) a mirror view fogs only the path behind its plane,
  from the plane to the reflected surface; the view that shows the surface fogs the path to it, so the
  reflection carries the reflected path's fog once. The mirror view owns its own sky tables.

Every mesh vertex stage declares `ClipDistance`, so the device must support `shaderClipDistance`;
`create_renderer` faults `UNSUPPORTED` without it. Adapter selection prefers a discrete adapter
without checking the feature: on a machine whose discrete adapter lacks it, `create_renderer`
faults even when another adapter has it.

Cost, measured on an RTX 4090 (driver 610.88). Writing the clip distance costs nothing measurable:
Sponza, forward, 64 lights, shadows on, means of six alternated runs before and after the clip write
(ms):

| 2560 × 1440 | Depth prepass | Opaque | Shadow atlas | GPU frame |
| --- | --- | --- | --- | --- |
| Flat lights, before | 0.0420 | 1.0812 | 0.0975 | 1.2825 |
| Flat lights, after | 0.0432 | 1.0827 | 0.0992 | 1.2857 |
| Clustered lights, before | 0.0464 | 0.2768 | 0.1000 | 0.5034 |
| Clustered lights, after | 0.0461 | 0.2751 | 0.1014 | 0.4985 |

At 1920 × 1080 the frames run under 1 ms and the differences are inside the noise (flat: opaque
0.7008 against 0.6898 ms). The `views` example's mirror view sums 0.065 to 0.074 ms of GPU passes at
render scale 0.5 and 1.0, with and without the plane, about 0.045 ms of it the shadow atlas; on that
small scene neither the plane nor the render scale moves the time beyond the run-to-run spread. The
plane culls the buried crate (`Stats.culled` 1 with it, 0 without).

With the mirror fitted to the main camera the frame records one shadow atlas, the mirror's, and the window view binds
it. In the `views` example's View stats window (single-frame readings) the mirror's visible passes sum to about
0.10 ms (depth 0.010, shadow atlas 0.073, forward 0.014); its atlas went from 0.068 to 0.073 ms because it now fits
the main camera. The window's atlas is the one that is gone.

## Preparation

`prepare_scene(scene)` uploads every asset the scene references, creates its mesh, shadow and
snapshot pipelines, and the display and effect pipelines of every live view, then waits.
`prepare_model(model)` does the same for a `ModelTemplate` before it is instantiated, preparing
depth-only variants unconditionally. Views created afterwards prepare their pipelines on first
render.

### Budgeted preparation

```c3
PrepareId prepare = renderer.begin_prepare_model(model)!;
// every frame, while the record is neither READY nor FAILED
renderer.begin_frame()!;
renderer.advance_prepares()!;           // stages at most about 1 MiB of uploads this frame
renderer.render_view(&scene, camera, renderer.default_view)!;
renderer.end_frame()!;
PrepareProgress progress = renderer.prepare_progress(prepare);
if (progress.state == PrepareState.READY) {
    model::instantiate(&assets, &scene, model)!;
    renderer.end_prepare(prepare)!;      // outside a frame: before begin_frame or after end_frame
}
```

`prepare_model` stalls the frame that calls it: for Sponza on the WSL host CPU it took 3966 ms in
the default build and 1882 ms at `-O3`, almost all of it CPU mip generation (9.7 and 4.3 ms per
staged MB; one 1024x1024 sRGB texture alone is 116 and 57 ms). The budgeted path spreads the same
work over frames. `begin_prepare_model` lists the model's units in template order (its textures,
then per mesh its geometry, material and pipelines, then one unit that creates the scene snapshot
pipelines its materials read and the view pipelines), leaving out textures and geometries already uploaded, and
records `bytes_total`. `advance_prepares(budget_bytes)`, called inside the open frame, promotes
finished records and then stages the next units of the open records in the order they began: a unit
that does not fit the rest of the budget waits for the next call, except when nothing was staged
yet in the call, so every call makes progress and stages at most the budget or one unit, whichever
is larger. One exception: an asset changed after its own unit ran (a material that gained a texture)
is staged by the next unit that resolves it, outside that bound. Pipeline units weigh nothing. A
unit whose mirror is already current (uploaded earlier,
by a view, or by another record) is done at zero cost, and a unit whose asset was removed is done
and counts a dangling reference. `PrepareProgress.bytes_done` reaches `bytes_total`;
`Stats.prepare_bytes` counts only what the frame staged.

Call `advance_prepares` every frame while any record is neither `READY` nor `FAILED`: promotion to
`READY` happens inside it, two frames after the last unit ran. `READY` means every unit whose asset
was live is uploaded and its frame completed, with the pipelines `prepare_model` would create for
the views live when each unit ran; a view created or reconfigured later creates what it lacks at its
first draw, and a model changed while its record was pending draws like any model changed after
preparation. The call does not abort the frame on a fault: the application aborts it, as for any
fault inside a frame, and only then do the call's units return to not done. Asset and shader faults
fail only the record (`failure` names the fault); the others propagate.

`end_prepare` releases a record in any state, outside a frame; ending a pending record stops it, and
what it already staged stays uploaded for later draws and records. A released or stale id reads as
`FAILED` with `INVALID_ID`, and `end_prepare` faults `INVALID_ID` on it. Four records can be open;
`begin_prepare_model` faults `INVALID_ID` for a dead model, then `CAPACITY_EXCEEDED` when all four are
open. The default budget, `PREPARE_FRAME_BUDGET_BYTES`, is 1 MiB: below `OVERSIZED_UPLOAD_BYTES`, so a
unit within it never takes an overflow allocation, and about 4.3 ms (`-O3`) or 9.7 ms (default build)
of CPU per call on the WSL host.

## Example

`examples/views` renders a rolled textured cube, three spheres, a crate and a ground plane three
times per frame: a producer camera orbiting the scene writes a 512x512 capture target, and a monitor
slab on its own layer samples that target through a Basic material while the window camera shows the
whole scene. The panel resizes the capture target (256, 512, 1024), switches the capture between
`DISPLAY_LDR` on an sRGB target and `LINEAR_HDR` on a float target (recreating the target and view
and rebinding the material), toggles FXAA and bloom on the capture view, and scales the window
view's working resolution.

The ground is a mirror floor. A third view renders a mirror camera, placed each frame with the
[planar reflection](#planar-reflections) recipe, into a half-size float target, clipped to the
ground plane; the ground's custom material (`examples/shaders/custom/mirror.frag.glsl`, compiled at
startup) shades the concrete through `shade_standard_surface` and mixes in the target. The ground
sits on its own layer, so only the window camera draws it and the capture shows no floor. A chrome
sphere sits half sunk into the ground and a crate lies wholly under it: with "Clip plane" off, the
reflection shows the sphere's buried half and the crate as if they rose out of the floor. The panel
also sets the mirror view's render scale and the floor's reflectance, and a "View stats" window
compares the window, capture and mirror views.

## Shading path

`shading = DEFERRED` renders the view's encodable opaque materials through a G-buffer and one
fullscreen lighting resolve; every other material keeps its forward pass on the same view. A
`FORWARD` view allocates no G-buffer image. With `depth_prepass` (the constructors' default) it runs
`DEPTH_PREPASS` over its opaque set, then [`AMBIENT_OCCLUSION`](ambient_occlusion.md) when enabled,
then `FORWARD_OPAQUE` with depth `EQUAL` and no depth write, so every opaque pixel is shaded once.
Without it, `FORWARD_OPAQUE` writes depth itself and shades every fragment that passes the depth
test at the time it is drawn; ambient occlusion and screen-space GI force the prepass on. The prepass pays one more
geometry pass with depth-only shaders and wins wherever opaque overdraw would be shaded more than
once. Measured on an RTX 4090 at 1080p with flat lights: Sponza with 64 lights, forward opaque
1.70 to 1.89 ms without it against 0.85 to 0.98 ms plus a 0.04 ms prepass with it; the
`many_lights` hall with 1024 lights, 4.82 to 5.07 ms against 4.07 to 4.08 ms plus 0.007 ms.
A `DEFERRED` view always runs it and ignores the flag.

```bash
python3 scripts/build.py --example deferred
```

`examples/deferred` renders one scene twice, the left half forward and the right half deferred,
switches either half at runtime and lists the G-buffer channels of the deferred view in the targets
panel.

Routing is a pure function of the material record, `render::gbuffer_encodable`, evaluated with
`render::view_draw_list` where the draw lists are split. A draw writes the G-buffer when the material
is `STANDARD`, or `PHYSICAL` with zero clearcoat, sheen, anisotropy and transmission factors,
`ior == 1.5`, white `specular_color` and no `specular_color_map`, and its alpha mode is `OPAQUE` or
`MASK`. `BASIC`, `TOON`, `CUSTOM`, every other `PHYSICAL` value, `BLEND` and transmissive draws stay
forward. The specular weight and its map are encoded. No material field selects the path and a
`FORWARD` view ignores the rule.

The deferred view owns five images at its working extent, allocated by `create_view` or
`configure_view` and retired when the view returns to `FORWARD`:

| Channel | Format | Contents |
| --- | --- | --- |
| `gbuffer_base_color_metallic` | `RGBA8_UNORM` | base color, metallic |
| `gbuffer_normal_roughness` | `RGBA16_FLOAT` | octahedral normal, roughness, occlusion |
| `gbuffer_emissive_specular` | `RGBA16_FLOAT` | emissive, specular weight |
| `gbuffer_layers` | `R32_UINT` | receiver layer mask |
| `gbuffer_flags` | `R32_UINT` | receive-shadow bit |

Pass order on a deferred view: uploads, shadow atlas, light culling, `DEPTH_PREPASS` over both opaque
lists, `GBUFFER` (depth `EQUAL`, no write), `AMBIENT_OCCLUSION` when the view has ambient
occlusion, `LIGHTING` (a fullscreen fragment pass that clears
`hdr_color`, discards where no geometry was drawn and lights every G-buffer pixel from `FrameRoot`),
`FORWARD_OPAQUE` (depth `EQUAL`, no write), sky, `SCENE_SNAPSHOT` and `SCENE_READ` when the view
draws scene readers, `SCENE_SNAPSHOT` again when a blended draw reads the scene, transparency,
velocity and the post chain. `Stats.gpu_pass_ms` carries the three new passes. A view with
[fog or an atmosphere](sky.md#where-fog-applies) records `SKY_VIEW` and `AERIAL_PERSPECTIVE` before the
depth prepass when its scene has an atmosphere, and splits before the transparent draws: the snapshot for
blended readers, the SSGI colour copy, then `FOG`, then transparency. With `volumetric_fog` the view also
records `FOG_SCATTERING` and `FOG_INTEGRATION` after the sky tables. Dielectric F0 in the resolve is
`0.04 · specular` for IOR 1.5, which is why other IORs and tinted specular colors route forward.

Light selection follows `lights` on both paths: the resolve calls the same clustered or flat
selection as the forward shaders, so `DEFERRED` with `CLUSTERED` needs no extra configuration.
`render::cluster_cell` and `render::cluster_index` are the C3 twins of that selection.

Custom materials take part through their shader: a `ShaderDesc` with a `gbuffer` stage routes
like `STANDARD` on a deferred view, one without stays forward; see
[custom shaders](custom_shaders.md#g-buffer-stage).

Per-view numbers live on the view: `Renderer.view_stats(view)` returns `ViewStats` with the view's live working images
at frame start (`images`), its selected and dropped light counts, whether it bound another view's shadow set
(`shadow_set_shared`, the table's "Shadow set" row), its cluster count and overflow count, its completed GPU pass
timings (`C3D_PROFILE_GPU`) and its applied exposure (`exposure`, delayed under auto exposure), while `Stats` keeps
the renderer-wide sums. `gui::view_stats_table(renderer, views, labels)` prints several views side by side.

```bash
python3 scripts/build.py --example shading_paths
```

`examples/shading_paths` renders one scene with 48 point lights, a custom material with a
G-buffer stage and one without, through all four `ShadingPath` and `LightSelection`
combinations in a 2x2 grid, switches each view at runtime, shows the targets panel for a selected
view and the view stats table for all four.
Motion blur, depth of field, bloom, grading and FXAA read `hdr_color`, depth and velocity only and
run unchanged.

Measured once on an RTX 4090 with `scripts/benchmark.py --shadings forward deferred --gpu-timings`:
Sponza at 2560x1440 with 256 clustered lights renders in 0.674 ms deferred against 1.346 ms
forward (prepass, G-buffer and resolve 0.483 ms against 1.161 ms of forward opaque shading);
the low-overdraw `many_lights` hall costs 6 to 8 % more deferred than forward. Deferred pays
for overdraw and light count and charges the G-buffer round trip without them.

Known difference: the resolve offsets shadow lookups along a face normal rebuilt from depth, the
forward shaders along the face-corrected vertex normal; neither reads the normal map, and on curved
surfaces the two directions differ slightly. No MSAA on deferred views; no screen-space effect
consumes the G-buffer.
