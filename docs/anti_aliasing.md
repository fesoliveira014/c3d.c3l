# Anti-aliasing

A view smooths edges with one post filter, `PostStack.anti_aliasing`, and optionally with multisampling,
`ViewDesc.msaa`. The filter is `AntiAliasing.NONE`, `FXAA` or `TAA`. Temporal anti-aliasing, motion blur and the
temporal lighting effects share one velocity image and one per-view history; this page owns the rules for both. The types
live in `c3d::render::post`; the view fields in `c3d::render`. [Display processing](post.md) covers the rest of the post
stack.

## Quick start

```c3
ViewDesc desc = render::default_view_desc();
desc.post.anti_aliasing = AntiAliasing.TAA;
render::configure_view(&renderer, renderer.default_view, desc)!;
```

`default_view_desc()` selects `FXAA`. Call `configure_view` between frames.

## Concepts

| Choice | Filters | Memory | Notes |
| --- | --- | --- | --- |
| `NONE` | nothing | none | |
| `FXAA` | the graded image, once | one working image, two on the fallback route | Default. No history |
| `TAA` | color over time, before the post effects | histories, 32 bytes per working pixel | Needs velocity. `LINEAR_HDR` views may use it |
| `msaa` above `ONE` | geometry edges at the sample level | per-sample targets | Excludes `TAA`. See [MSAA](msaa.md) |

- A view selects one filter, so FXAA and TAA never stack.
- Multisampling is `ViewDesc.msaa`, not a post setting. It combines with `FXAA`, which filters the resolved image. Bloom,
  depth of field, motion blur and grading read single-sample images and are unchanged.
- A zeroed `PostStack` is not neutral. Start from `post::default_post_stack()`.

## FXAA

FXAA 3.11 quality, preset 12, with edge threshold 0.166, minimum 0.0833 and subpixel quality 0.75. The grade pass writes
the filter's luma into alpha as the square root of the Rec.709 luma of the display-linear color. The filter writes alpha
one.

- Enabling FXAA allocates one working image (`RGBA16_FLOAT`, sampled and storage) at the `hdr_color` size. A second image
  appears only when the working extent differs from the output rectangle in pixels, because that case runs a compute
  filter and a copy.
- Disabling FXAA retires the images through the frame lifecycle. A resize recreates them with the view targets.
- Other anti-aliasing choices skip the working image: the final fullscreen pass grades, tone maps and applies the LUT
  straight from the scene image.
- FXAA records one dispatch on the direct route and two on the fallback; `Stats.post_dispatches` counts them.

## Temporal anti-aliasing

`anti_aliasing = AntiAliasing.TAA` resolves the view over time on scene-linear color. It runs after the scene passes and
before motion blur, depth of field, bloom and grading. The parameters are `TaaParams`; see the
[reference](post_reference.md#taaparams) for fields, defaults and ranges.

- **Jitter.** `post::taa_jitter` walks `TAA_SAMPLE_COUNT` (8) Halton(2,3) points, each within half a pixel.
  `camera::jitter_matrices` applies the offset to the rasterized projection only (`FrameRoot.proj`, `view_proj`,
  `inv_view_proj`; `FrameRoot.jitter_time.xy` holds it in NDC). Culling, picking, light selection, shadows and the cluster
  grid keep the unjittered matrices, and `Camera.lens_shift` is untouched. The sample index advances when a rendering is
  published, so an aborted frame repeats its jitter.
- **Resolve.** One dispatch, timed under `Pass.TEMPORAL_AA`. It rebuilds the current color from its 3x3 jittered samples,
  reads the history at `uv - velocity` with a Catmull-Rom filter, and clips it to the neighborhood's variance box in YCoCg
  (`mean +/- clip_gamma * sigma`). The blend follows `current_weight` and `1 / (1 + luma)` in stored, pre-exposed units; TAA
  scales its history by the ratio of consecutive [pre-exposure](post.md#pre-exposure) factors.
- **Rejection.** History is rejected outside the image, where no texel of the 2x2 depth-history footprint matches the
  expected previous depth within `depth_tolerance`, and progressively where current and previous velocity differ by
  `velocity_threshold` to twice that many pixels. Rejected history leaves the current sample.
- **Images.** The view keeps two ping-ponged histories each of color (`RGBA16_FLOAT`), depth (`R32_FLOAT`) and velocity
  (`RG16_FLOAT`), 32 bytes per working pixel on top of the view. The wider velocity image adds 4 bytes per pixel and a debug
  image 8 while one is shown. A resize recreates them.
- **Material mips.** `mip_bias` biases built-in material texture sampling on TAA views through `FrameRoot.mip_bias`. A
  custom material opts in by passing `frame.mip_bias` to the `sample_custom_map` overload that takes a bias.
- **Debug images.** `TaaParams.debug` shows `VELOCITY` (red and green around 0.5, 16 pixels to full scale), `REJECTION`
  (depth rejection red, velocity rejection green, missing history blue) or `HISTORY_WEIGHT` (gray) instead of color. The
  view then skips motion blur, depth of field, bloom, grading and FXAA and copies the image to its output.
- **Dispatches that write color.** A dispatch that writes a TAA view's color (`render::write_view_color`) first moves the
  resolved image into `hdr_color`, so the write never reaches the next resolve.

`configure_view` faults `INVALID_ARGUMENT` for TAA parameters out of range, checked only while TAA is selected.

## Velocity and history

Motion blur, TAA, screen-space GI, temporal ambient occlusion and reflection history read the same per-view velocity image
and the same per-view history.

### Velocity

- **Convention.** Velocity is `current_uv - previous_uv` in framebuffer UV, top-left origin, and stays unjittered.
- **Format.** Motion blur alone uses `RG16_FLOAT`. TAA, [screen-space GI](screen_space_gi.md), temporal
  [ambient occlusion](ambient_occlusion.md#temporal) and [reflection history](reflections.md#history) use
  `RGBA16_FLOAT` with the expected previous reverse-Z depth of each surface in `z`.
- **Camera velocity.** A fullscreen pass reprojects every pixel through the view's previous view-projection from stored
  depth. A pixel with no geometry reprojects as a direction; under an orthographic projection it has zero camera velocity.
- **Moving geometry.** A geometry pass with the `VELOCITY` vertex variant redraws the opaque items that moved, are skinned
  or morphed, have [vertex motion](geometry_edits.md#edited-vertices), or are instanced batches, with depth `EQUAL` and no
  depth write. Skinned and morphed surfaces use the palette and morph block the view drew last time, and instances use their
  own previous matrices. Both passes are timed under `Pass.VELOCITY`.
- **Custom stages.** An item whose custom shader supplies a [velocity form](custom_shaders.md#velocity-form) redraws
  through that form on every rendering with history. A custom vertex stage contributes displacement to velocity only
  through that form.
- **Timing.** A view with TAA or motion blur alone records velocity after the scene passes. A view with screen-space GI,
  temporal ambient occlusion or reflection history records it as soon as depth is complete: after the prepass, and after
  the G-buffer on deferred views, before the effects and lighting. Scene-read items draw after the velocity on those views
  and keep the camera velocity.
- **Cost.** A view that uses an early-velocity effect without TAA or motion blur also pays the velocity pass and the
  per-candidate history commit.
- **Rejection flag.** A pixel whose velocity carries the rejection flag takes the new sample alone in every consumer.
  The flag marks a fresh or incompatible [LOD](lod.md) level, an invalid crowd history and an invalid vertex history.
- **Blended and scene-read surfaces.** Blended surfaces carry the velocity of the surface behind them and ghost when they
  move. Depth-writing scene-read surfaces carry their own velocity on views that record velocity after the scene.

### History

The previous pose is renderer-owned per view: the camera's view-projection, the rendering's `FrameInfo.time` (read back as
`FrameRoot.previous_time`), the world matrix of every mesh the view drew, and the palette, morph block and instance
matrices of deformed and instanced ones. Entries are tagged by entity so a reused slot never matches, stamped with the
rendering so a mesh absent from the last rendering has no previous model when it returns, and keyed by the scene's
identity, so a view that switches scenes starts without motion and a replaced scene needs no reset.

- The history commits at the end of `render_view` when motion blur, TAA or an early-velocity effect is on, and publishes
  when the frame submits. An unsubmitted abort drops it, and the next rendering carries no motion.
- `configure_view`, a resize and `render::reset_view_history(&renderer, view)` reset one view's history. The first
  rendering after a reset carries no motion and resolves from the current sample alone. Call `reset_view_history` on a
  camera cut or a jump in `FrameInfo.time`.
- Two views of one camera keep separate histories.
- A temporal view that draws a different scene than its last rendering resolves from the current sample.
- `render_to` has no history.

## Limits

- A one-pixel rim outside moving silhouettes takes the current sample, because the dilated velocity reprojects it onto
  background the object uncovered or covered, which the depth and velocity tests reject.
- An instance that changes parity or order inside its batch has wrong velocity for one rendering.
- TAA runs at the working resolution. There is no temporal upscaler.
- FXAA has fixed quality constants and no history.

## See also

- [Display processing](post.md) and [post reference](post_reference.md#taaparams).
- [MSAA](msaa.md) for multisampling and its combinations.
- [Views](views.md) for `configure_view`, `reset_view_history` and `render_to`.
- [Geometry edits](geometry_edits.md) for vertex motion.
- Example: `taa` shows TAA with its debug images; run `python3 scripts/build.py --example taa`.
