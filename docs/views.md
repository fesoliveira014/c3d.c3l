# Views and render targets

A view is a renderer-owned record that renders the scene from one camera into one output: the
window or an application-owned render target. The default view (`renderer.default_view`) writes
the window; further views are created by the application. One frame renders any number of views
in application order and submits them together.

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
frames complete, increments the target revision, and resizes every view that writes the target.
`destroy_render_target` faults `RESOURCE_IN_USE` while a live view selects the target: destroy the
views first. Renderer teardown releases remaining views, then targets.

## Views

```c3
ViewDesc desc = render::texture_view_desc(capture, OutputMode.DISPLAY_LDR);
desc.post.fxaa = false;
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
| `color` | `DISPLAY_LDR` runs the display route; `LINEAR_HDR` keeps scene-linear color |
| `post` | The view's `PostStack` (see [display processing](post.md)) |
| `shading` | `FORWARD`; `DEFERRED` faults `UNSUPPORTED` |
| `lights` | `FLAT` or `CLUSTERED` candidate light selection |
| `clusters` | Editable `ClusterDesc`; ignored by `FLAT` |

`default_view_desc()` is a full-window `DISPLAY_LDR` view with neutral grading;
`texture_view_desc(target, color = LINEAR_HDR)` covers a target. `create_view` and `configure_view`
validate between frames: a dead target faults `INVALID_ID`; `LINEAR_HDR` on a window view or on an
RGBA8 target, a viewport outside the output, a render scale outside its range and an invalid post
stack fault `INVALID_ARGUMENT`; a full pool faults `CAPACITY_EXCEEDED` (`VIEW_CAPACITY` is 8).
`destroy_view` on the default view faults `INVALID_ARGUMENT`.

The view owns its working images (`hdr_color`, `depth`, the scene-color snapshot, post and effect
images) at the working extent `working_extent(viewport, output, render_scale)`, at least one pixel
per dimension. Reconfiguring with a different extent or output waits for outstanding frames and
reallocates them; every configuration resets the view's history. Window resize resizes every
window view; target resize resizes every view on that target. A headless renderer's window views
hold no images and record nothing.

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
compute dispatch limits faults `UNSUPPORTED`. `DEFERRED` always faults `UNSUPPORTED`.
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
the window is dormant (`has_output` false); a texture view always records. `end_frame` submits
when any view recorded or an upload is pending, presents only when a window image was acquired,
and discards an empty frame. Neither call advances animation or flushes scene removals.

`Renderer.render(scene, camera)` is the default-view convenience. `render_to(scene, camera, target,
color = LINEAR_HDR, info = {})` renders one frame into a target through a view it creates and
destroys, without touching the window; it waits for completion and is a bake path, not a per-frame
one.

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

## Preparation

`prepare_scene(scene)` uploads every asset the scene references, creates its mesh, shadow and
snapshot pipelines, and the display and effect pipelines of every live view, then waits.
`prepare_model(model)` does the same for a `ModelTemplate` before it is instantiated, preparing
depth-only variants unconditionally. Views created afterwards prepare their pipelines on first
render.

## Example

`examples/views` renders a rolled textured cube, two spheres and a ground plane twice per frame:
a producer camera orbiting the scene writes a 512x512 capture target, and a monitor slab on its
own layer samples that target through a Basic material while the window camera shows the whole
scene. The panel resizes the capture target (256, 512, 1024), switches the capture between
`DISPLAY_LDR` on an sRGB target and `LINEAR_HDR` on a float target (recreating the target and view
and rebinding the material), toggles FXAA and bloom on the capture view, and scales the window
view's working resolution.
