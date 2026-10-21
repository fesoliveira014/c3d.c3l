# World-space overlay items

Module `c3d::render`. An overlay list can lay out its items in a plane around a world point: a label that follows an object,
or a sign fixed to a wall. The renderer draws such a list inside a view, after the view's post, tested against the view's
depth. Items are the ones of [Overlay list](overlay.md); this page covers anchors, depth, layers and the faults that are
specific to world lists.

## Quick start

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

A plane fixed in the world, such as a sign on a wall, names its axes:

```c3
list.push_anchor({
    .position        = sign_top_left,
    .facing          = PLANE,
    .right           = along_the_wall,
    .up              = { 0, 1, 0 },
    .pixels_per_unit = 200,
})!;
```

## Concepts

- **The call.** `set_view_overlay(view, list)` gives one view a list for the frame; `null` clears it. `finish_view` prepares
  the list for the view's output and draws it there, after the view's post: into the window or into the view's render target.
  The application does not call `prepare_overlay_list` or open an overlay for it.
- **Lifetime.** The list must be valid and unchanged from the call until `end_frame`: the renderer reads it when `finish_view`
  records the view, so a change in between is drawn. The setting lasts one frame; the next `begin_frame` clears it. One list
  may be given to several views; each prepares it when it records.
- **World list.** Every item of a world list is under an anchor, and a backdrop item is not allowed. A list that holds anchors
  draws only through `set_view_overlay`; `prepare_overlay_list` rejects it. Build a second list to show the same content on
  screen.

## Anchors

`push_anchor(anchor)` starts a plane at a world position and `pop_anchor` ends it. Items added in between are laid out in that
plane with the ordinary calls: x to the right, y down, the origin at the anchor. Enclosing transforms and clips do not apply
inside it; `push_transform` and `push_clip` inside it apply in the plane. An anchor inside another starts its own plane.

| `OverlayAnchor` field | Meaning |
| --- | --- |
| `position` | World position, rebased with the frame origin as scene nodes are. |
| `facing` | `BILLBOARD` (default) or `PLANE`. |
| `right`, `up` | `PLANE` only: the world step of a layout unit along x and against y. |
| `pixels_per_unit` | Size of a layout unit; zero or above, finite. |

### Billboard anchors

A `BILLBOARD` plane faces the camera and keeps its orientation on the screen as the camera turns. Only `position` and
`pixels_per_unit` apply to it.

- With `pixels_per_unit` above zero, a layout unit is that many screen pixels at any distance: `1` lays out in pixels and the
  size stays constant as the anchor moves away.
- With zero, a layout unit is a world unit: a label `1.5` wide is 1.5 metres wide and shrinks with distance as the scene does.
- Both measure the pixels of the view's output rectangle.
- A billboard anchor has one depth, that of its position. One behind the camera, or outside the near and far planes, draws
  none of its items.

### Plane anchors

A `PLANE` is fixed in the world. Layout x runs along `right` and layout y against `up`, from `position`, so a sign laid out
from its top left corner reads upright when `up` points up.

- The vectors need not be unit length or perpendicular, but they must be finite and not parallel: `push_anchor` faults
  `INVALID_ARGUMENT` otherwise.
- A layout unit spans `right` along x and `up` along y when `pixels_per_unit` is zero, and one `pixels_per_unit`th of each
  when it is above zero. With unit vectors and 200, a sign 600 units wide is 3 metres wide.
- Its size is a size in the world, so it shrinks with distance and foreshortens at an angle. Items are projected with
  perspective and filtered per pixel.
- The front of a plane is the side `right` cross `up` points to, and from there layout x runs to the right. A plane seen from
  behind, or edge-on, draws nothing. Two anchors with opposite normals make a sign that shows on both sides. The test follows
  the plane's side of the camera, not the winding on screen, so it holds in a mirror view.
- A plane is clipped by the near and far planes per fragment, like geometry.

## Depth test

A fragment is drawn where its depth is at least as near as the view's depth at the pixel, so geometry nearer than the item
hides it, and the sky never does. Reverse-Z, larger is nearer. Nothing is written to the depth image.

A plane lying on a surface of the view draws over it. Under `render_scale` below one or temporal anti-aliasing, the sampled
depth can differ from the plane's by more, so keep a plane a few millimetres off a surface it hangs on.

The test reads the view's own depth, which temporal anti-aliasing renders with a sub-pixel jitter, and the items are placed
without it. Where an item meets a silhouette in front of it, the cut moves with the jitter: up to about a pixel between two
frames. The renderer keeps no unjittered copy of the depth.

A view may render below its output's size (`render_scale`) or cover only a rectangle of it (`viewport`). Each fragment maps its
output pixel into the view's rectangle and reads the depth texel there. The items are clipped to that rectangle.

## Layers

`set_layers(mask)` takes a mask of the type of `Camera.layers`. `finish_view` draws the list in a view only when the mask
shares a layer with the camera that rendered the view. A new list has every layer, and `clear()` keeps the mask. The mask
filters world lists only.

## Colors

The items draw after post, in the view's display output: exposure, tone mapping, temporal anti-aliasing, bloom and blur do not
apply. Colors, blending and encoding are those of a window or target overlay
([Draw into a render target](overlay.md#draw-into-a-render-target)), so a label is as bright as its sRGB color says, whatever
the exposure.

A `LINEAR_HDR` view has no display image: its output holds physical radiance, so the pass writes each color divided by the
view's `Camera.exposure`. A consumer that applies the same exposure, as the grade of a view does, shows the label at its own
color; one that applies none shows it that much darker. The view's pre-exposure does not enter, since the output is in physical
units and the pass writes after post. A `LINEAR_HDR` view ignores auto exposure, so a consumer that adapts shows the label
brighter or darker with the scene.

## Mirrors and clip planes

A mirror view, the view of a camera reflected across a plane with `ViewDesc.clip_plane` set to it
([Planar reflections](views.md#planar-reflections)), draws a world list when the layers match. The view's handedness is
flipped, and the plane test accounts for it.

- A plane in a mirror is drawn as a mirror shows it: its text is reversed where its front faces the reflected camera, and
  nothing is drawn where its back does.
- A billboard is laid out in the mirror view's image like in any view, so it faces the mirror camera and reads normally in the
  reflection.
- A billboard whose anchor lies on the negative side of the view's `clip_plane` draws none of its items, and one on the
  positive side draws all of them. A plane is clipped per fragment where it crosses the clip plane, like geometry.
- The cube capture of a reflection probe draws no world overlay, as it draws no cloud layer and no height fog.

## Faults

| Call | Faults |
| --- | --- |
| `push_anchor` | `CAPACITY_EXCEEDED` (table or clip stack full); `INVALID_ARGUMENT` (non-finite position, `pixels_per_unit` negative or non-finite, or a `PLANE` whose `right` and `up` are non-finite or parallel) |
| `pop_anchor` | Contract: the stacks are not empty |
| `Renderer.set_view_overlay` | `INVALID_ID` (dead view, texture, sampler, font or render target); `INVALID_ARGUMENT` (an item outside an anchor, a backdrop item, comparison sampler, glyph past its font or without a built outline, the list samples the view's output target); `UNSUPPORTED` (path-traced view; cube, volume, layered or `R16_UINT` texture); contract: frame open, list not destroyed |

Every fault of `set_view_overlay` records nothing and leaves the frame open, so the application can skip that overlay and still
present. Faults while `finish_view` records the list (asset data unavailable, device and recording faults) abort the frame
like any other fault in `finish_view`. The item calls (`add_rect`, `push_clip` and the rest) fault as listed in
[Overlay list](overlay.md#faults).

## Costs

A view with a world list that has visible items records one extra pass after its output, with one draw per run. It uploads one
transform table of the list's size (80 bytes per entry) and, with plane anchors, one plane table (64 bytes per entry). An
anchor takes one table entry, so `OverlayListDesc.max_transforms` bounds the anchors of a list.

## Limits

- A world list holds no backdrop item and no item outside an anchor.
- A path-traced view has no depth image and refuses a world list.
- Reflection probe captures draw no world overlay.
- The list draws in the view's output, in the view's output rectangle.

## See also

- [Overlay list](overlay.md) for items, clips, transforms and capacities.
- [Views](views.md) for view output, render scale, viewports and planar reflections.
- [Large worlds](large_world.md) for the frame origin that anchor positions rebase with.
