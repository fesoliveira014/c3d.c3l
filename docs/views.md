# Views and render targets

A view is a renderer-owned record that renders the scene from one camera into one output: the
window or an application-owned render target. The default view (`renderer.default_view`) writes
the window; further views are created by the application. One frame renders any number of views
in application order and submits them together.

```bash
python3 scripts/build.py --example views
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

## Frames

```c3
renderer.begin_frame(info)!;
renderer.render_view(&scene, producer_camera, capture_view)!;
if (renderer.has_output) {
    renderer.render_view(&scene, main_camera, renderer.default_view)!;
    OverlayContext overlay = renderer.begin_overlay()!;
    gui.record(&overlay)!;
    renderer.end_overlay(&overlay)!;
}
renderer.end_frame()!;
```

`render_view` extracts, uploads, records the scene passes and effects, then writes the view's
output: `DISPLAY_LDR` grades, tone maps and optionally anti-aliases into the output rectangle;
`LINEAR_HDR` copies the scene-linear image into the target. A window view records nothing while
the window is dormant (`has_output` false); a texture view always records. `end_frame` submits
when any view recorded or an upload is pending, presents only when a window image was acquired,
and discards an empty frame. Neither call advances animation or flushes scene removals.

`Renderer.render(scene, camera)` is the default-view convenience. `render_to(scene, camera, target,
color = LINEAR_HDR, info = {})` renders one frame into a target through a view it creates and
destroys, without touching the window; it waits for completion and is a bake path, not a per-frame
one.

Pass timings (`Stats.gpu_pass_ms`, shadow timings) describe the last recorded view of the frame;
draw, dispatch and light counters accumulate across views.

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
