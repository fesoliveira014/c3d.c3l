# Overlay list

Module `c3d::render`. An `OverlayList` holds application-owned 2D items that the renderer draws over the composed window or
into a render target: rectangles with rounded corners, borders, textures, nine-slice fields, gradients and a blurred backdrop;
glyph runs of placed [text](text.md); triangles, lines and paths. Each item sits under a clip and a transform. The list holds
plain values and names no `gpu` type. Items placed in the world around a point use the same list and are described in
[World-space overlay items](overlay_world.md).

Dear ImGui stays the tool for debug panels and inspectors ([GUI overlay](gui.md)). The overlay list serves interfaces the
application draws itself.

## Quick start

```c3
OverlayList list = render::create_overlay_list(mem, render::default_overlay_list_desc());
defer render::destroy_overlay_list(&list);

OverlayRect panel = render::OVERLAY_RECT_DEFAULT;
panel.min = { 40, 40 };
panel.max = { 360, 200 };
panel.fill = { 0.1f, 0.1f, 0.12f, 0.9f };
panel.corner_radii = { 8, 8, 8, 8 };

// each frame
list.clear();
list.add_rect(panel)!;

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

Without ImGui, omit the `gui_renderer.record` line.

## Concepts

### Lifecycle

- `create_overlay_list` allocates every slice once, from the allocator it is given. Nothing allocates per frame. Destroy the
  list after the renderer's last use of it.
- `clear()`, the `add_*` calls, `push_clip`, `pop_clip`, `push_transform` and `pop_transform` run any time before
  `prepare_overlay_list`. Items stay unchanged from preparation until `draw_list` records them.
- `prepare_overlay_list` resolves textures and fonts, uploads the outline rows fonts gained, readies the render targets the
  list samples and uploads one instance per visible rectangle, glyph, triangle or segment. Its optional `target` names the
  render target the list is drawn into; zero is the window. A list with backdrop items also readies the images its blur
  works in.
  - A window list is prepared after the frame's last `finish_view`, with window output.
  - A target list is prepared after the views that render its target and the targets it samples. It needs no window output.
  - Both are prepared with no overlay open. A render target the list samples must not be rendered again that frame.
- `draw_list` runs inside the overlay, before `GuiRenderer.record`. The ImGui backend binds its own pipeline and state. The
  overlay's output must be the one the list was prepared for. A backdrop item ends and reopens the overlay pass; the record
  after the list is unaffected.
- A list is prepared and drawn at most once per frame. Preparing a later frame without `clear()` draws the same items.

### Coordinates, colors, textures

- Positions and sizes are output pixels, origin top left, y down. Pixel density is the caller's: the list does not scale.
- Colors are sRGB with straight alpha: `fill` and `border_color`. A textured item multiplies its texture by `fill`.
- `texture` is a `TextureRef`. An `ASSET` reference with a zero id fills with color only. An asset texture or a
  `RENDER_TARGET` reference must be live. A `VIEW` reference is rejected with `INVALID_ARGUMENT`.
- A zero `sampler` selects the linear clamp sampler. A comparison sampler is rejected.
- Cube, volume, layered and `R16_UINT` textures are unsupported.
- `uv_rect` is the sampled region, `u0, v0, u1, v1`.

### Output modes

The list samples a texture as stored and converts nothing. For a render target shown as an image:

- A `DISPLAY_LDR` view into an `RGBA8_SRGB` or float target shows the finished picture.
- A `LINEAR_HDR` view shows radiance clipped at 1.
- A `DISPLAY_LDR` view into an `RGBA8_UNORM` target stores linear display values at 8 bits; the list shows them correctly,
  but dark tones band.

## Draw into a render target

```c3
renderer.prepare_overlay_list(&list, target)!;

OverlayContext overlay = renderer.begin_overlay_target(target)!;
overlay.draw_list(&list)!;
renderer.end_overlay(&overlay)!;
```

`begin_overlay_target(target)` opens the overlay pass on a render target. `prepare_overlay_list(list, target)` fits the list to
that target: the clips are clamped to its size and the runs are packed for it. The output is linear light, stored in the
target format's own encoding. An `RGBA8_SRGB` target encodes it; `RGBA8_UNORM` and the float formats store the linear values.

- A target overlay needs an open frame and no open overlay. It does not need window output, so it also works in a frame
  without a window.
- The pass loads and stores the target, so what a view or an earlier overlay wrote stays. A target nothing has written holds
  undefined contents.
- `end_overlay` leaves the target readable by shaders. A list that samples it afterwards records no barrier for it.
- A view or list that samples the target before its overlay is drawn in the frame sees the target's previous contents. Draw
  the overlay first to show the new ones.
- A list drawn into a target is the list prepared for it. Drawing a list prepared for another output breaks the `draw_list`
  contract.
- A list cannot sample the target it is drawn into: a pass cannot read the image it writes.

## Round corners, borders and nine-slice

- `corner_radii` are top left, top right, bottom right, bottom left. A radius larger than half the shorter side is clamped to
  it.
- `border_widths` are left, top, right, bottom, drawn inside the box in `border_color`. A width larger than the box is
  clamped to the box, so a border wider than its rect fills it. Edges are anti-aliased over about one pixel.
- `slice_uv` are the four nine-slice margins as fractions of `uv_rect`; `slice_pixels` are the same margins on screen.
  All-zero `slice_pixels` disables nine-slice. Corners keep their size, edges stretch along one axis and the centre along
  both. The margins on opposite sides must fit the box (`slice_pixels`) and the region (`slice_uv`).

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

- `OverlayRect.gradient` ramps the rect's color from `fill`, the start color, to `gradient.color`, the end color. Both are
  sRGB with straight alpha. `NONE`, the zero value, keeps `fill` alone and ignores the other gradient fields.
- `LINEAR` ramps along the line from `from` to `to`: the start color at `from` and the end color at `to`. Points on a line
  across it share a color.
- `RADIAL` takes `from` as the centre and `to` as a point on the radius: the start color at the centre, the end color at that
  distance and beyond.
- Past either end the ramp stays at that end's color.
- The points use the rect's coordinates: output pixels, or local pixels under a transform, so the gradient follows the
  transform. They may lie outside the rect, such as a vignette whose radius point is past a corner.
- The ramp is interpolated in linear light, on colors premultiplied by alpha. The midpoint of black to white is linear 0.5,
  which is about 188 as sRGB, and a fade to a transparent color keeps the hue of the start color.
- A textured rect multiplies its texture by the ramp. Corner radii, borders and the clip apply as without a gradient;
  `border_color` stays flat over the ramp.
- Each point is stored as a half-precision offset from `min`. A point is off by at most half a pixel while it is under 2,048
  pixels from `min`, and by at most one pixel under 4,096; the error doubles with each further doubling of the distance.
  Keep `from` and `to` several times that error apart. `from` must differ from `to`, and a point may lie at most 65,504
  pixels from `min`.

## Backdrop blur

```c3
OverlayRect panel = render::OVERLAY_RECT_DEFAULT;
panel.min = { 460, 300 };
panel.max = { 760, 440 };
panel.fill = { 1, 1, 1, 0.16f };
panel.backdrop_radius = 16;
list.add_rect(panel)!;
```

- `OverlayRect.backdrop_radius` is a blur radius in output pixels, also under a transform: scaling an item does not scale its
  blur. Zero, the default, is off. A rect with a radius is a backdrop item. It blurs what is already drawn on the output
  under its shape, then draws its own fill, gradient, texture and border over the blurred pixels. A fill with alpha zero
  shows the blur alone.
- "Already drawn" is everything on the output before the item: the views the output shows, earlier items of the list and
  earlier lists drawn on it. Items after the backdrop item draw over it and are not blurred. A second backdrop item blurs the
  first one's result.
- The shape, the clip and the transform apply as for any rect: a rotated item blurs the pixels under its rotated shape, and a
  clipped item blurs only inside its clip, though the blur reads pixels outside it.
- The blur is a Gaussian in linear light, applied along x and then along y. Its deviation is a third of the radius, at least
  half a pixel, and it ends at the radius. Past the output's edge the image repeats its edge pixels. Alpha is blurred like a
  color channel, so the result is exact over opaque pixels.
- A radius above `MAX_BACKDROP_RADIUS` (32 pixels) clamps to it, and a fractional radius rounds up to a whole pixel.
- A backdrop item draws alone, in its own run, in submission order with the items around it.
- A list holds at most `MAX_BACKDROP_ITEMS` backdrop items (8); rects without a radius are not counted, and `clear()` resets
  the count.
- The window must be copyable: a window list with a backdrop item needs a surface with copy-source usage
  (`SwapchainInfo.usage.transfer_src` in gpu.c3l). A render target output always works.

Costs to plan for:

- Each backdrop item ends and reopens the overlay pass, runs two blur dispatches and, on the window, copies the pixels under
  its box. A blurred pixel reads `2 * radius + 1` texels in each of two passes, so the cost grows with box area and radius.
- The renderer allocates the blur images when it first prepares a list with a backdrop item, and grows them only when it
  prepares a list for a larger output. It frees them with the renderer. Two RGBA16F images of the largest output size take
  `width * height * 16` bytes. A window also keeps a copy image in the swapchain format, `width * height * texel_bytes` more,
  4 bytes per pixel for the common formats.

## Glyph runs

`add_glyphs(OverlayGlyphRun run)` copies a run's placements into the list: one font, one pixel size, one color, the baseline
origin in output pixels. Each placement becomes one instance, drawn in submission order among the rectangles under the run's
clip. A glyph that does not reach its clip emits nothing. `OverlayListDesc.max_glyphs` bounds the placements of all runs; zero
holds no text. See [Text](text.md) for placing text and rounding the origin.

## Shapes

```c3
list.add_triangle(
    first:  first,
    second: second,
    third:  third,
    color:  color,
)!;
list.add_line(
    from:  from,
    to:    to,
    width: width,
    color: color,
)!;
list.add_path(
    points: points,
    width:  width,
    color:  color,
    closed: true,
)!;
```

- `color` is sRGB with straight alpha, like `fill`. Coordinates and `width` are output pixels, or local pixels under a
  transform.
- `add_triangle` fills a triangle of either winding. A triangle with no area draws nothing.
- `add_line` draws a line `width` pixels across with round caps. A line of zero length draws a dot.
- `add_path` draws one line per edge of `points`, in order, with round joins and caps. `closed` adds the edge from the last
  point back to the first; a path of two points has no closing edge.
- Edges are anti-aliased over about one output pixel. Under a transform they stay about that wide, whatever the stroke width.
- Neighbouring edges overlap at a join. A path with alpha below one draws the overlap twice, so the join looks denser. An
  opaque path is unaffected.
- A triangle and a line take one item each; a path takes one item per edge, and `closed` adds the closing edge. A path that
  does not fit adds no edge.
- Each shape takes the active clip and transform when it is added, as rectangles do.

## Clipping

`push_clip(min, max)` intersects the current clip with a box in output pixels, or in local pixels under a transform
([Transforms](#transforms)); `pop_clip` restores the previous one. Each item keeps the clip active when it was added.
Preparation clamps the clip to the output and rounds it outward to whole pixels. An item that does not reach its clip, and an
empty item, is skipped. Consecutive emitted items with the same scissor form one run, drawn with one instanced draw;
`Stats.draws` grows by one per run. Items draw in submission order. A backdrop item always forms a run of its own.

## Transforms

`push_transform(transform)` applies an `OverlayTransform` to every item and clip added until the matching `pop_transform`. It
maps local pixels to output pixels: `x_axis` and `y_axis` are the images of the local unit vectors and `offset` is the image
of the local origin, so `(x, y)` lands at `x_axis * x + y_axis * y + offset`. `OVERLAY_TRANSFORM_IDENTITY` leaves positions
unchanged.

```c3
list.push_transform({ .x_axis = { cosine, sine }, .y_axis = { -sine, cosine }, .offset = center })!;
list.push_transform({ .x_axis = { 2, 0 }, .y_axis = { 0, 2 } })!;
list.add_rect(rect)!;
list.pop_transform();
list.pop_transform();
```

- **Composition.** A push composes with the active transform: the new transform applies first, then the enclosing one. The
  example above scales by two and then rotates and moves the result.
- **Coordinates.** Under a transform, bounds, glyph origins, corner radii, borders and nine-slice margins are local pixels.
  The one exception is the backdrop radius, which stays in output pixels. Edges stay about one output pixel wide at any scale,
  rotation or shear, and glyphs stay sharp. A textured item samples with the gradients of the local mapping, so a scaled-down
  item still picks smaller mips.
- **Clips.** `push_clip` takes its box in the active transform's local space. A clip pushed with no transform keeps the
  scissor-only path. A clip pushed under a transform is tested per fragment in its local space, with an edge about one output
  pixel wide. Its scissor is the bounding box of the box in output pixels, so a rotated clip costs fragment work inside that
  box. Clips nest: an item draws only inside every clip active when it was added.
- **Capacity.** Each push, and each clip pushed under a transform, takes one entry of the list's transform table. The entry
  stays in use after the pop until `clear()`. `OverlayListDesc.max_transforms` sets the table size, up to 65,535.
  `default_overlay_list_desc()` sets it to `OVERLAY_LIST_DEFAULT_TRANSFORMS`. A desc that leaves it zero holds no
  transforms, as `max_glyphs` does for text: its pushes fault.
- **Shaders.** A list draws with the plain overlay shaders unless an emitted item has a transform or a transformed clip; then
  the whole list draws with the transformed variants of both stages. Pushing transforms around items that are all skipped
  leaves the list plain.

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
| `Renderer.begin_overlay_target` | `INVALID_ID` (dead target); `gpu` faults from state transitions and recording |
| `Renderer.prepare_overlay_list` | `INVALID_ID` (dead texture, sampler, render target or font, or a dead output `target`); `INVALID_ARGUMENT` (comparison sampler; glyph past its font or without a built outline; the list samples its output `target`; the list holds anchors); `UNSUPPORTED` (cube, volume, layered or `R16_UINT` texture; a window list with a backdrop item on a surface that cannot be copied from); `ASSET_DATA_UNAVAILABLE`; `gpu` faults from upload and state transitions |
| `OverlayContext.draw_list` | `gpu` and shader faults from pipeline creation and recording; contract: prepared this frame for this output |

A reference fault in `prepare_overlay_list` (`INVALID_ID`, `INVALID_ARGUMENT`, `UNSUPPORTED`) and the `INVALID_ID` of
`begin_overlay_target` record nothing and leave the frame open, so the application can skip that overlay and still present.
Any later fault aborts the frame, like other renderer faults. The faults of anchors and world lists are in
[World-space overlay items](overlay_world.md#faults).

## Capacities and costs

| Constant | Value |
| --- | --- |
| `OVERLAY_LIST_DEFAULT_ITEMS` | 4,096 items |
| `OVERLAY_LIST_DEFAULT_CLIPS` | 16 nested clips |
| `OVERLAY_LIST_DEFAULT_GLYPHS` | 16,384 placements |
| `OVERLAY_LIST_DEFAULT_TRANSFORMS` | 256 table entries |
| `MAX_BACKDROP_ITEMS` | 8 backdrop items per list |
| `MAX_BACKDROP_RADIUS` | 32 pixels |

- One rectangle, glyph, triangle or segment is 96 bytes of instance data in the frame upload ring. The default 4,096 items
  cost 384 KiB of the ring per prepared list; 16,384 glyphs cost 1.5 MiB.
- A transform table entry is 80 bytes of the frame upload ring. A prepared list uploads its entries only when it pushed a
  transform, an anchor or a transformed clip. An anchor takes one entry, so `max_transforms` also bounds the anchors. The list
  allocates 44 bytes of CPU anchor data and a 4-byte root index for every table entry at creation.
- One run costs one draw. Rects with alternating clips cost one run each. Items under different transforms and the same
  scissor share a run.
- `Pass.OVERLAY` times `draw_list` when GPU timings are on; a frame's window, target and world overlays add up.

The `overlay` example shows every feature; its options are in the [examples](../examples/README.md#window-input-and-overlays).

## Limits

- Cube, volume, layered and `R16_UINT` textures are unsupported, and so are comparison samplers and `VIEW` references.
- Capacities are fixed at creation; a full list faults `CAPACITY_EXCEEDED` instead of growing.
- A list with anchors is a world list and never draws through `prepare_overlay_list`.
- Backdrop items need a copyable window surface and cost a pass break each.
- Text is placed by the application; the list does not shape or wrap.

## See also

- [World-space overlay items](overlay_world.md) for labels and signs placed in the scene.
- [Text](text.md) for fonts, placement and glyph runs.
- [GUI overlay](gui.md) for the ImGui adapter that draws after the list.
- [Views](views.md) for view output modes and render targets.
