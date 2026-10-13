# Overlay list

Module `c3d::render` draws application-owned 2D items over the composed window or into a render target: rectangles
with rounded corners, borders, textures, nine-slice fields, gradients and a blurred backdrop
([Backdrop](#backdrop)), glyph runs of placed text ([Text](text.md)), and triangles, lines and paths
([Shapes](#shapes)), each under a clip and a transform, and items placed in the world around a point
([World-space items](#world-space-items)). The list holds plain values; it names no `gpu` type.
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
- `clear()`, the `add_*` calls, `push_clip`, `pop_clip`, `push_transform` and `pop_transform` run any time
  before `prepare_overlay_list`. Items stay unchanged from preparation until `draw_list` records them.
- `prepare_overlay_list` resolves textures and fonts, uploads the outline rows fonts gained, readies the render
  targets the list samples and uploads one instance per visible rectangle, glyph, triangle or segment. Its optional
  `target` names the render target the list is drawn into; zero is the window. A list with backdrop items also readies
  the images its blur works in.
  - A window list is prepared after the frame's last `finish_view`, with output.
  - A target list is prepared after the views that render its target and the targets it samples. It needs no output.
  - Both are prepared with no overlay open. A render target the list samples must not be rendered again that frame.
- `draw_list` runs inside the overlay, before `GuiRenderer.record`. The ImGui backend binds its own pipeline and state.
  The overlay's output must be the one the list was prepared for. A backdrop item ends and reopens the overlay pass;
  the record after the list is unaffected.
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

## Gradients

```c3
rect.fill = { 1, 0.78f, 0.25f, 1 };
rect.gradient = {
    .kind  = LINEAR,
    .from  = rect.min,
    .to    = { rect.min.x, rect.max.y },
    .color = { 0.85f, 0.25f, 0.15f, 1 },
};
```

- `OverlayRect.gradient` ramps the rect's color from `fill`, the start color, to `gradient.color`, the end color. Both
  are sRGB with straight alpha. `NONE`, the zero value, keeps `fill` alone, so a rect that sets no gradient draws as it
  did without the field.
- `LINEAR` ramps along the line from `from` to `to`: the start color at `from` and the end color at `to`. Points on
  a line across it share a color.
- `RADIAL` takes `from` as the centre and `to` as a point on the radius: the start color at the centre, the end color
  at that distance and beyond.
- Past either end the ramp stays at that end's color.
- The points use the rect's coordinates: output pixels, or local pixels under a transform, so the gradient follows the
  transform. They may lie outside the rect, such as a vignette whose radius point is past a corner.
- The ramp is interpolated in linear light, on colors premultiplied by alpha. The midpoint of black to white is
  linear 0.5, which is about 188 as sRGB, and a fade to a transparent color keeps the hue of the start color.
- A textured rect multiplies its texture by the ramp. Corner radii, borders and the clip apply as without a gradient;
  `border_color` stays flat over the ramp.
- **Precision.** An item stores each point as a half-precision offset from `min`, so the item stays 96 bytes. A point
  is off by at most half a pixel while it is under 2,048 pixels from `min`, and by at most one pixel under 4,096; the
  error doubles with each further doubling of the distance. Keep `from` and `to` several times that error apart.
- **Faults.** `add_rect` faults with `INVALID_ARGUMENT` for a non-finite point or color, for `from` equal to `to` (a
  radial gradient then has no radius), and for a point more than 65,504 pixels from `min` on either axis. A rect with
  kind `NONE` ignores the other gradient fields.

## Backdrop

```c3
OverlayRect panel = render::OVERLAY_RECT_DEFAULT;
panel.min = { 460, 300 };
panel.max = { 760, 440 };
panel.fill = { 1, 1, 1, 0.16f };
panel.backdrop_radius = 16;
list.add_rect(panel)!;
```

- `OverlayRect.backdrop_radius` is a blur radius in pixels; zero, the default, is off. A rect with a radius is a
  backdrop item. It blurs what is already drawn on the output under its shape, then draws its own fill, gradient,
  texture and border over the blurred pixels. A fill with alpha zero shows the blur alone.
- "Already drawn" is everything on the output before the item: the views the output shows, earlier items of the list
  and earlier lists drawn on it. Items after the backdrop item draw over it and are not blurred. A second backdrop
  item blurs the first one's result.
- The shape, the clip and the transform apply as for any rect: a rotated item blurs the pixels under its rotated
  shape, and a clipped item blurs only inside its clip, though the blur reads pixels outside it.
- The blur is a Gaussian in linear light, applied along x and then along y. Its deviation is a third of the radius,
  at least half a pixel, and it ends at the radius. Past the output's edge the image repeats its edge pixels. Alpha
  is blurred like a color channel, so the result is exact over opaque pixels.
- A radius above `MAX_BACKDROP_RADIUS` (32 pixels) clamps to it, and a fractional radius rounds up to a whole pixel.
  A negative or non-finite radius faults with `INVALID_ARGUMENT`.
- A backdrop item draws alone, in its own run, in submission order with the items around it.

**Recording.** At a backdrop item `draw_list`:

1. ends the overlay pass;
2. on the window, copies the pixels under the item, grown by the radius, into a copy image; a render target needs
   no copy, since it is read in place;
3. blurs them with two compute dispatches over that box;
4. reopens the pass, keeping the output's contents, and draws the item over the blurred image.

**Limits.**

- A list holds at most `MAX_BACKDROP_ITEMS` backdrop items (8). The ninth `add_rect` with a radius faults with
  `CAPACITY_EXCEEDED` and leaves the list unchanged. Rects without a radius are not counted. `clear()` resets the count.
- The window must be copyable. `prepare_overlay_list` faults with `UNSUPPORTED` for a window list that holds a backdrop
  item when the surface does not grant copy-source usage (`SwapchainInfo.usage.transfer_src` is false in gpu.c3l).
  The fault leaves the frame open, as the other reference faults do. A render target output always works.
- A box clamps to the output, so an item at the edge blurs its edge pixels.

**Memory.** The renderer allocates the blur images when it first prepares a list with a backdrop item, and grows
them only when it prepares a list for a larger output. It frees them with the renderer; nothing allocates per frame.
Two RGBA16F images of the largest output size take `width * height * 16` bytes. A window also keeps a copy image in
the swapchain's format, `width * height * texel_bytes` more, 4 bytes per pixel for the common formats.

**Cost.** Each backdrop item ends and begins the overlay pass, runs two compute dispatches and, on the window, copies
its box. A blurred pixel reads `2 * radius + 1` texels in each of the two passes, so the cost of an item grows with
its box area and its radius. Lists without backdrop items record the same passes and pipelines as before.

## Glyph runs

`add_glyphs(OverlayGlyphRun run)` copies a run's placements into the list: one font, one pixel size, one color, the
baseline origin in output pixels. Each placement becomes one instance, drawn in submission order among the
rectangles under the run's clip. A glyph that does not reach its clip emits nothing. `OverlayListDesc.max_glyphs`
bounds the placements of all runs; zero holds no text. See [Text](text.md) for placing text and rounding the
origin.

## Shapes

```c3
list.add_triangle(first, second, third, color)!;
list.add_line(from, to, width, color)!;
list.add_path(points, width, color, closed: true)!;
```

- `color` is sRGB with straight alpha, like `fill`. Coordinates and `width` are output pixels, or local pixels under a
  transform.
- `add_triangle` fills a triangle of either winding. A triangle with no area draws nothing.
- `add_line` draws a line `width` pixels across with round caps. A line of zero length draws a dot.
- `add_path` draws one line per edge of `points`, in order, with round joins and caps. `closed` adds the edge from the
  last point back to the first; a path of two points has no closing edge.
- Edges are anti-aliased over about one output pixel. Under a transform they stay about that wide, whatever the
  stroke width.
- **Joins.** Neighbouring edges overlap at a join. A path with alpha below one draws the overlap twice, so the join
  looks denser. An opaque path is unaffected.
- **Capacity.** A triangle and a line take one item each; a path takes one item per edge, and `closed` adds the closing
  edge. A path that does not fit faults before it adds any edge.
- Each shape takes the active clip and transform when it is added, as rectangles do.

## Clipping

`push_clip(min, max)` intersects the current clip with a box in output pixels, or in local pixels under a transform
([Transforms](#transforms)); `pop_clip` restores the previous one. Each item keeps the clip active when it was added.
Preparation clamps the clip to the output and rounds it outward to whole pixels. An item that does not reach its clip,
and an empty item, is skipped. Consecutive emitted items with the same scissor form one run, drawn with one instanced
draw; `stats.draws` grows by one per run. Items draw in submission order. A backdrop item always forms a run of its own.

## Transforms

`push_transform(transform)` applies an `OverlayTransform` to every item and clip added until the matching
`pop_transform`. It maps local pixels to output pixels: `x_axis` and `y_axis` are the images of the local unit
vectors and `offset` is the image of the local origin, so `(x, y)` lands at `x_axis * x + y_axis * y + offset`.
`OVERLAY_TRANSFORM_IDENTITY` leaves positions unchanged.

```c3
list.push_transform({ .x_axis = { cosine, sine }, .y_axis = { -sine, cosine }, .offset = center })!;
list.push_transform({ .x_axis = { 2, 0 }, .y_axis = { 0, 2 } })!;
list.add_rect(rect)!;
list.pop_transform();
list.pop_transform();
```

- **Composition.** A push composes with the active transform: the new transform applies first, then the enclosing
  one. The example above scales by two and then rotates and moves the result.
- **Coordinates.** Under a transform, bounds, glyph origins, radii, borders and nine-slice margins are local pixels.
  Edges stay about one output pixel wide at any scale, rotation or shear, and glyphs stay sharp. A textured item
  samples with the gradients of the local mapping, so a scaled-down item still picks smaller mips.
- **Clips.** `push_clip` takes its box in the active transform's local space. A clip pushed with no transform keeps
  the scissor-only path. A clip pushed under a transform is tested per fragment in its local space, with an edge
  about one output pixel wide. Its scissor is the bounding box of the box in output pixels, so a rotated clip costs
  fragment work inside that box. Clips nest: an item draws only inside every clip active when it was added.
- **Capacity.** Each push, and each clip pushed under a transform, takes one entry of the list's transform table. The
  entry stays in use after the pop until `clear()`. `OverlayListDesc.max_transforms` sets the table size, up to
  65,535. `default_overlay_list_desc()` sets it to `OVERLAY_LIST_DEFAULT_TRANSFORMS`. A desc that leaves it zero holds
  no transforms, as `max_glyphs` does for text: its pushes fault and its lists draw as before.
- **Outputs.** Window and render-target outputs treat transforms alike. Items under the identity pack and draw as they
  do without transforms.
- **Shaders.** A list draws with the plain overlay shaders unless an emitted item has a transform or a transformed
  clip; then the whole list draws with the transformed variants of both stages. Pushing transforms around items that
  are all skipped leaves the list plain.

## World-space items

```c3
list.clear();
list.push_anchor({ .position = world_position, .pixels_per_unit = 1 })!;
list.add_rect(label)!;
list.add_glyphs(text)!;
list.pop_anchor();

renderer.render_view(scene, camera_node, view)!;
renderer.set_view_overlay(view, &list)!;
renderer.finish_view(view)!;
```

- **The call.** `set_view_overlay(view, list)` gives one view a list for the frame; `null` clears it. `finish_view`
  prepares the list for the view's output and draws it there, after the view's post: into the window or into the view's
  render target. The application does not call `prepare_overlay_list` or open an overlay for it.
- **Lifetime.** The list must be valid and unchanged from the call until `end_frame`: the renderer reads it when
  `finish_view` records the view, so a change in between is drawn. The setting lasts one frame; the next `begin_frame`
  clears it. One list may be given to several views; each prepares it when it records.
- **Anchors.** `push_anchor(anchor)` starts a plane at a world position and `pop_anchor` ends it. Items added in
  between are laid out in that plane with the ordinary calls: x to the right, y down, the origin at the anchor, the
  plane facing the camera. Enclosing transforms and clips do not apply inside it; `push_transform` and `push_clip` inside
  it apply in the plane. An anchor inside another starts its own plane.
- **Position.** `position` is a world position, rebased with the frame origin as scene nodes are. An anchor behind the
  camera, or outside the near and far planes, draws none of its items.
- **Size.** With `pixels_per_unit` above zero a layout unit is that many screen pixels at any distance: `1` lays out in
  pixels and the size stays constant as the anchor moves away. With zero a layout unit is a world unit, so a label
  `1.5` wide is 1.5 metres wide and shrinks with distance as the scene does. Both measure the pixels of the view's
  output rectangle.
- **Depth test.** An anchor has one depth, that of its position. A fragment of its items is drawn where that depth is
  at least as near as the view's depth at the pixel, so geometry nearer than the anchor hides the items behind it, and
  the sky never does. Reverse-Z, larger is nearer. Nothing is written to the depth image.
- **Colors.** The items draw after post, in the view's display output: exposure, tone mapping, temporal
  anti-aliasing, bloom and blur do not apply. Colors, blending and encoding are those of a window or target overlay
  ([Render-target output](#render-target-output)), so a label is as bright as its sRGB color says, whatever the exposure.
- **Temporal jitter.** The test reads the view's own depth, which temporal anti-aliasing renders with a sub-pixel
  jitter, and the items are placed without it. Where an item meets a silhouette in front of it, the edge can shimmer by
  up to about half a pixel from frame to frame. The renderer keeps no unjittered copy of the depth.
- **Resolution and viewport.** A view may render below its output's size (`render_scale`) or cover only a rectangle of
  it (`viewport`). Each fragment maps its output pixel into the view's rectangle and reads the depth texel there. The
  items are clipped to that rectangle.
- **Limits.** Every item of a world list is under an anchor, and a backdrop item is not allowed. A list that holds
  anchors is a world list, drawn only through `set_view_overlay`; `prepare_overlay_list` rejects it, so it is never
  drawn as a screen list. Build a second list to show the same content on screen. A view with `LINEAR_HDR` output has
  no display image, and a path-traced view has no depth image: both refuse a world list.
- **Faults.** `set_view_overlay` checks the list when called and faults with `INVALID_ID` (dead view, texture, sampler,
  font or render target), `INVALID_ARGUMENT` (an item outside an anchor, a backdrop item, a comparison sampler, a glyph
  past its font, a list sampling the view's own target) or `UNSUPPORTED` (the cases above, or a texture kind the
  overlay cannot sample). These leave the frame open. Faults while `finish_view` records the list (asset data
  unavailable, device and recording faults) abort the frame like any other fault in `finish_view`.
- **Cost.** A view with a world list that has visible items records one extra pass after its output, with one root of
  64 bytes and one draw per run, and uploads one transform table of the list's size. Views without a world list, and
  lists without anchors, record the passes and use the pipelines they used before.

## Faults

| Call | Faults |
| --- | --- |
| `add_rect` | `CAPACITY_EXCEEDED` (list full, or a ninth backdrop item); `INVALID_ARGUMENT` (non-finite or negative values, `max` below `min`, nine-slice margins larger than the box or region, a gradient point non-finite, equal to the other or more than 65,504 pixels from `min`, a negative or non-finite backdrop radius) |
| `add_glyphs` | `CAPACITY_EXCEEDED` (list full, or not enough glyph room); `INVALID_ARGUMENT` (non-finite origin, color or placement position; size not above zero) |
| `add_triangle` | `CAPACITY_EXCEEDED` (list full); `INVALID_ARGUMENT` (non-finite point or color) |
| `add_line` | `CAPACITY_EXCEEDED` (list full); `INVALID_ARGUMENT` (non-finite point or color; width not above zero) |
| `add_path` | `CAPACITY_EXCEEDED` (not enough item room for every edge); `INVALID_ARGUMENT` (fewer than two points; non-finite point or color; width not above zero) |
| `push_clip` | `CAPACITY_EXCEEDED` (stack full, or under a transform the table full); `INVALID_ARGUMENT` (non-finite, `max` below `min`) |
| `pop_clip` | Contract: the stack is not empty |
| `push_transform` | `CAPACITY_EXCEEDED` (table full); `INVALID_ARGUMENT` (non-finite values, or a composed transform with no inverse) |
| `pop_transform` | Contract: the stack is not empty |
| `push_anchor` | `CAPACITY_EXCEEDED` (table or clip stack full); `INVALID_ARGUMENT` (non-finite position, or `pixels_per_unit` negative or non-finite) |
| `pop_anchor` | Contract: the stacks are not empty |
| `Renderer.set_view_overlay` | `INVALID_ID` (dead view, texture, sampler, font or render target); `INVALID_ARGUMENT` (an item outside an anchor, a backdrop item, comparison sampler, glyph past its font or without a built outline, the list samples the view's output target); `UNSUPPORTED` (`LINEAR_HDR` or path-traced view; texture kind above); contract: frame open, list not destroyed |
| `Renderer.begin_overlay_target` | `INVALID_ID` (dead target); `gpu` faults from state transitions and recording |
| `Renderer.prepare_overlay_list` | `INVALID_ID` (dead texture, sampler, render target or font, or a dead output `target`); `INVALID_ARGUMENT` (comparison sampler; glyph past its font or without a built outline; the list samples its output `target`; the list holds anchors); `UNSUPPORTED` (texture kind above; a window list with a backdrop item on a surface that cannot be copied from); `ASSET_DATA_UNAVAILABLE`; `gpu` faults from upload and state transitions |
| `OverlayContext.draw_list` | `gpu` and shader faults from pipeline creation and recording; contract: prepared this frame for this output |

A reference fault in `prepare_overlay_list` (`INVALID_ID`, `INVALID_ARGUMENT`, `UNSUPPORTED`), the `INVALID_ID` of
`begin_overlay_target` and every fault of `set_view_overlay` record nothing and leave the frame open, so the application
can skip that overlay and still present. Any later fault aborts the frame, like other renderer faults.

## Capacities and costs

- `OVERLAY_LIST_DEFAULT_ITEMS` is 4,096 items. `OVERLAY_LIST_DEFAULT_CLIPS` is 16 nested clips.
  `OVERLAY_LIST_DEFAULT_GLYPHS` is 16,384 placements. `OVERLAY_LIST_DEFAULT_TRANSFORMS` is 256 table entries.
- One rectangle, glyph, triangle or segment is 96 bytes of instance data in the frame upload ring.
  4,096 items cost 384 KiB of the ring per prepared list; 16,384 glyphs cost 1.5 MiB.
- A transform table entry is 80 bytes of the frame upload ring. A prepared list uploads its entries only when it
  pushed a transform, an anchor or a transformed clip. An anchor takes one entry, so `max_transforms` also bounds the
  anchors, and the list keeps 20 bytes of anchor data on the CPU for each entry.
- One run costs one 32-byte root and one draw. Rects with alternating clips cost one run each. Items under different
  transforms and the same scissor share a run. A backdrop item's run takes a 64-byte root and two 48-byte blur roots.
- `MAX_BACKDROP_ITEMS` is 8 backdrop items per list and `MAX_BACKDROP_RADIUS` is 32 pixels ([Backdrop](#backdrop)).
- `Pass.OVERLAY` times `draw_list` when GPU timings are on; a frame's window, target and world overlays add up.

## Benchmark

`overlay --benchmark --rects N --frames F --size WxH` prints `fill_ms` (clear plus `add_rect` calls),
`prepare_ms` (CPU time of `prepare_overlay_list`), `overlay_gpu_ms` (`Pass.OVERLAY`) and `draws` (the overlay's own
draws), averaged over `F` frames after `F` warm-up frames. The benchmark pushes no clip, so every rect falls in one run.

The `overlay` example shows every feature; `--stress N` adds N small rects under one clip, `--target` draws a
panel into the portrait's render target, `--transform` draws a rotated and scaled panel of text, a nine-slice
frame and rects under a transformed clip, and `--shapes` draws a line chart with a triangle marker, a star and a
translucent ribbon, and the chart again under a transform, and `--gradients` draws a linear gradient button, a
textured nine-slice rect with a gradient, a rect with a gradient under a transform, and a radial vignette over the
portrait whose radius point lies outside its rect. `--backdrop` draws a frosted panel over the sphere and the sample
row, a rotated one over the scroll list's rows and, with `--target`, one over the portrait's cube. `--world` anchors
two labels in the scene, one sized in pixels and one in metres, which sweep toward the camera and pass behind and in
front of the sphere.
