# Overlay list

Module `c3d::render` draws application-owned 2D items over the composed window or into a render target: rectangles
with rounded corners, borders, textures and nine-slice fields, and glyph runs of placed text ([Text](text.md)), each
under a clip. The list holds plain values; it names no `gpu` type.
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

A list drawn into a render target uses `begin_overlay_target` and needs no window output
([Render-target output](#render-target-output)):

```c3
renderer.prepare_overlay_list(&list, target)!;

OverlayContext overlay = renderer.begin_overlay_target(target)!;
overlay.draw_list(&list)!;
renderer.end_overlay(&overlay)!;
```

- `create_overlay_list` allocates every slice once, from the allocator it is given. Nothing allocates per frame.
- `clear()`, `add_rect`, `add_glyphs`, `push_clip` and `pop_clip` run any time before `prepare_overlay_list`. Items
  stay unchanged from preparation until `draw_list` records them.
- `prepare_overlay_list` runs after the frame's last `finish_view`, with output and no overlay open. It resolves
  textures and fonts, uploads the outline rows fonts gained, readies the render targets the list samples and
  uploads one instance per visible rectangle or glyph. A render target
  the list samples must not be rendered again that frame. Its optional `target` names the render target the list
  is drawn into; zero is the window.
- `draw_list` runs inside the overlay, before `GuiRenderer.record`. The ImGui backend binds its own pipeline and state.
  The overlay's output must be the one the list was prepared for.
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
- A `DISPLAY_LDR` view into an `RGBA8_UNORM` target stores linear display values at 8 bits; the list shows them
  correctly, but dark tones band.

## Render-target output

`begin_overlay_target(target)` opens the overlay pass on a render target. `prepare_overlay_list(list, target)` fits
the list to that target: the clips are clamped to its size and the runs are packed for it. The output is linear
light, stored in the target format's own encoding. An `RGBA8_SRGB` target encodes it; `RGBA8_UNORM` and the float
formats store the linear values.

- A target overlay needs an open frame and no open overlay. It does not need window output, so it also works in a
  frame without a window.
- The pass loads and stores the target, so what a view or an earlier overlay wrote stays. A target nothing has
  written holds undefined contents.
- `end_overlay` leaves the target readable by shaders. A list that samples it afterwards records no barrier for it.
- A view or list that samples the target before its overlay is drawn in the frame sees the target's previous
  contents. Draw the overlay first to show the new ones.
- A list drawn into a target is the list prepared for it. Drawing a list prepared for another output breaks the
  `draw_list` contract.
- A list that samples the target it is drawn into faults with `INVALID_ARGUMENT` at preparation: a pass cannot read
  the image it writes.

## Rounding, borders, nine-slice

- `corner_radii` are top left, top right, bottom right, bottom left. A radius larger than half the shorter side is
  clamped to it.
- `border_widths` are left, top, right, bottom, drawn inside the box in `border_color`. A width larger than the box is
  clamped to the box, so a border wider than its rect fills it. Edges are anti-aliased over about one pixel.
- `slice_uv` are the four nine-slice margins as fractions of `uv_rect`; `slice_pixels` are the same margins on screen.
  All-zero `slice_pixels` disables nine-slice. Corners keep their size, edges stretch along one axis and the centre
  along both. The margins on opposite sides must fit the box (`slice_pixels`) and the region (`slice_uv`).

## Glyph runs

`add_glyphs(OverlayGlyphRun run)` copies a run's placements into the list: one font, one pixel size, one color, the
baseline origin in output pixels. Each placement becomes one instance, drawn in submission order among the
rectangles under the run's clip. A glyph that does not reach its clip emits nothing. `OverlayListDesc.max_glyphs`
bounds the placements of all runs; zero holds no text. See [Text](text.md) for placing text and rounding the
origin.

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
| `add_glyphs` | `CAPACITY_EXCEEDED` (list full, or not enough glyph room); `INVALID_ARGUMENT` (non-finite origin, color or placement position; size not above zero) |
| `push_clip` | `CAPACITY_EXCEEDED` (stack full); `INVALID_ARGUMENT` (non-finite, `max` below `min`) |
| `pop_clip` | Contract: the stack is not empty |
| `Renderer.begin_overlay_target` | `INVALID_ID` (dead target); `gpu` faults from state transitions and recording |
| `Renderer.prepare_overlay_list` | `INVALID_ID` (dead texture, sampler, render target or font, or a dead output `target`); `INVALID_ARGUMENT` (comparison sampler; glyph past its font or without a built outline; the list samples its output `target`); `UNSUPPORTED` (texture kind above); `ASSET_DATA_UNAVAILABLE`; `gpu` faults from upload and state transitions |
| `OverlayContext.draw_list` | `gpu` and shader faults from pipeline creation and recording; contract: prepared this frame for this output |

A reference fault in `prepare_overlay_list` (`INVALID_ID`, `INVALID_ARGUMENT`, `UNSUPPORTED`) and the `INVALID_ID` of
`begin_overlay_target` record nothing and leave the frame open, so the application can skip that overlay and still
present. Any later fault aborts the frame, like other renderer faults.

## Capacities and costs

- `OVERLAY_LIST_DEFAULT_ITEMS` is 4,096 items. `OVERLAY_LIST_DEFAULT_CLIPS` is 16 nested clips.
  `OVERLAY_LIST_DEFAULT_GLYPHS` is 16,384 placements.
- One rectangle or glyph is 96 bytes of instance data in the frame upload ring.
  4,096 items cost 384 KiB of the ring per prepared list; 16,384 glyphs cost 1.5 MiB.
- One run costs one 24-byte root and one draw. Rects with alternating clips cost one run each.
- `Pass.OVERLAY` times `draw_list` when GPU timings are on; a frame's window and target overlays add up.

## Benchmark

`overlay --benchmark --rects N --frames F --size WxH` prints `fill_ms` (clear plus `add_rect` calls),
`prepare_ms` (CPU time of `prepare_overlay_list`), `overlay_gpu_ms` (`Pass.OVERLAY`) and `draws` (the overlay's own
draws), averaged over `F` frames after `F` warm-up frames. The benchmark pushes no clip, so every rect falls in one run.

The `overlay` example shows every feature; `--stress N` adds N small rects under one clip, and `--target` draws a
panel into the portrait's render target.
