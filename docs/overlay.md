# Overlay list

Module `c3d::render` draws application-owned 2D rectangles over the composed window: rounded corners,
borders, textures and nine-slice fields, each under a clip. The list holds plain values; it names no `gpu` type.
Dear ImGui stays the tool for debug panels and inspectors ([GUI overlay](gui.md)). The list serves interfaces the
application draws itself.

## Lifecycle

```c3
OverlayList list = render::create_overlay_list(mem, render::default_overlay_list_desc());
defer render::destroy_overlay_list(&list);

list.clear();
list.add_rect(rect)!;

renderer.begin_frame(info)!;
renderer.render_view(scene, camera_node, renderer.default_view)!;
renderer.finish_view(renderer.default_view)!;
renderer.prepare_overlay_list(&list)!;

OverlayContext overlay = renderer.begin_overlay()!;
overlay.draw_list(&list)!;
gui_renderer.record(&overlay)!;
renderer.end_overlay(&overlay)!;
renderer.end_frame()!;
```

- `create_overlay_list` allocates every slice once, from the allocator it is given. Nothing allocates per frame.
- `clear()`, `add_rect`, `push_clip` and `pop_clip` run any time before `prepare_overlay_list`. Items stay unchanged
  from preparation until `draw_list` records them.
- `prepare_overlay_list` runs after the frame's last `finish_view`, with output and no overlay open. It resolves
  textures, readies the render targets the list samples and uploads one instance per visible item. A render target
  the list samples must not be rendered again that frame.
- `draw_list` runs inside the overlay, before `GuiRenderer.record`. The ImGui backend binds its own pipeline and state.
- A list is prepared and drawn at most once per frame. Preparing a later frame without `clear()` draws the same items.
- Destroy the list after the renderer's last use of it.

## Coordinates, colors, textures

- Positions and sizes are output pixels, origin top left, y down. Pixel density is the caller's: the list does not
  scale.
- Colors are sRGB with straight alpha: `fill` and `border_color`. A textured item multiplies its texture by `fill`.
- `texture` is a `TextureRef`. An `ASSET` reference with a zero id fills with color only. An asset texture or a
  `RENDER_TARGET` reference must be live.
- A zero `sampler` selects the linear clamp sampler. A comparison sampler is rejected.
- Cube, volume, layered and `R16_UINT` textures are unsupported.
- `uv_rect` is the sampled region, `u0, v0, u1, v1`.

## Output modes

The list samples a texture as stored and converts nothing. For a render target shown as an image:

- A `DISPLAY_LDR` view into an `RGBA8_SRGB` or float target shows the finished picture.
- A `LINEAR_HDR` view shows radiance clipped at 1.
- An `RGBA8_UNORM` display target stores encoded values that the list then reads as linear; dark tones band.

## Rounding, borders, nine-slice

- `corner_radii` are top left, top right, bottom right, bottom left. A radius larger than half the shorter side is
  clamped to it.
- `border_widths` are left, top, right, bottom, drawn inside the box in `border_color`. A width larger than the box is
  clamped to the box, so a border wider than its rect fills it. Edges are anti-aliased over about one pixel.
- `slice_uv` are the four nine-slice margins as fractions of `uv_rect`; `slice_pixels` are the same margins on screen.
  All-zero `slice_pixels` disables nine-slice. Corners keep their size, edges stretch along one axis and the centre
  along both. The margins on opposite sides must fit the box (`slice_pixels`) and the region (`slice_uv`).

## Clipping

`push_clip(min, max)` intersects the current clip with a box in output pixels; `pop_clip` restores the previous one.
Each item keeps the clip active when it was added. Preparation clamps the clip to the output and rounds it outward to
whole pixels. An item that does not reach its clip, and an empty item, is skipped. Consecutive emitted items with
the same clip form one run, drawn with one instanced draw; `stats.draws` grows by one per run. Items draw in
submission order.

## Faults

| Call | Faults |
| --- | --- |
| `add_rect` | `CAPACITY_EXCEEDED` (list full); `INVALID_ARGUMENT` (non-finite or negative values, `max` below `min`, nine-slice margins larger than the box or region) |
| `push_clip` | `CAPACITY_EXCEEDED` (stack full); `INVALID_ARGUMENT` (non-finite, `max` below `min`) |
| `pop_clip` | Contract: the stack is not empty |
| `Renderer.prepare_overlay_list` | `INVALID_ID` (dead texture, sampler or render target); `INVALID_ARGUMENT` (comparison sampler); `UNSUPPORTED` (texture kind above); `ASSET_DATA_UNAVAILABLE`; `gpu` faults from upload and state transitions |
| `OverlayContext.draw_list` | `gpu` and shader faults from pipeline creation and recording; contract: prepared this frame |

A fault in `prepare_overlay_list` aborts the frame like any other renderer fault.

## Capacities and costs

- `OVERLAY_LIST_DEFAULT_ITEMS` is 4,096 items. `OVERLAY_LIST_DEFAULT_CLIPS` is 16 nested clips.
- One item is 80 bytes of instance data in the frame upload ring.
  4,096 items cost 320 KiB of the ring per prepared list.
- One run costs one 24-byte root and one draw. Rects with alternating clips cost one run each.
- `Pass.OVERLAY` times `draw_list` when GPU timings are on.

## Measured costs

`overlay --benchmark --rects N --frames F --size WxH` prints `fill_ms` (clear plus `add_rect` calls),
`prepare_ms` (CPU time of `prepare_overlay_list`) and `overlay_gpu_ms` (`Pass.OVERLAY`), averaged over `F` frames after
`F` warm-up frames.

| Rects | Output | fill_ms | prepare_ms | overlay_gpu_ms | draws |
| --- | --- | --- | --- | --- | --- |
| 1,000 | 1920 x 1080 | pending | pending | pending | pending |
| 10,000 | 1920 x 1080 | pending | pending | pending | pending |
| 1,000 | 3840 x 2160 | pending | pending | pending | pending |
| 10,000 | 3840 x 2160 | pending | pending | pending | pending |

The `overlay` example shows every feature; `--stress N` adds N small rects under one clip.
