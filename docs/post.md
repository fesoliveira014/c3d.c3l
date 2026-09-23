# Display processing

`c3d::render::post` turns the scene-linear `hdr_color` of a `DISPLAY_LDR` view into display-ready
linear color for the view's output. The `BGRA8_SRGB` swapchain or an sRGB target encodes; no shader
encodes for output. `LINEAR_HDR` views skip this module.

```bash
python3 scripts/build.py --example post
./examples/build/post --gpu-timings
```

## Settings

`ViewDesc.post` is the CPU post configuration of a view (see `docs/views.md` for the output
fields). `render::default_view_desc()` selects `DISPLAY_LDR` with `post::default_post_stack()`: ACES,
contrast 1, saturation 1, temperature 0, tint 0, lift 0, gamma 1, gain 1, no LUT, and
`anti_aliasing = AntiAliasing.FXAA`. `AntiAliasing { NONE, FXAA, TAA }` selects one filter per view, so
FXAA and TAA never stack. A zeroed `PostStack` is not neutral.

Apply a configuration between frames with `render::configure_view(&renderer, renderer.default_view,
desc)`. The call copies the description into the view record, uploads a selected LUT, and allocates
or retires the two working images FXAA needs. `LINEAR_HDR` faults `INVALID_ARGUMENT` on a window
view; a dead view or LUT faults `INVALID_ID`; a LUT that is not a single-mip RGBA8 3D texture faults
`INVALID_ARGUMENT`.

Exposure is `Camera.exposure` (05 Cameras). `GradeParams` carries no exposure of its own; the
renderer packs the scene view's camera exposure into the display root each frame.

## Routes

Both routes run inside `finish_view` and write the view's output rectangle.

- Anti-aliasing other than FXAA: the scene image is sampled by `display.frag`, which grades, tone
  maps and applies the LUT in the final fullscreen pass. No working image exists; `Stats.post_dispatches` is zero and the
  `POST_CHAIN` timing is empty.
- FXAA: `grade.comp` writes the graded LDR image and its perceptual luma (alpha) into `post_a`.
  When the working image equals the output rectangle in pixels, `fxaa.frag` filters `post_a`
  straight into the output attachment (one dispatch counted, the fragment pass timed under
  `COMPOSITE`); otherwise `fxaa.comp` writes `post_b`, allocated on first use, and the identity
  composite copies it to the output (two dispatches counted under `POST_CHAIN`).

Grade order: exposure, white balance (LMS von Kries from temperature and tint in `[-1, 1]`),
contrast about linear mid-gray 0.18, saturation on Rec.709 luma, lift-gamma-gain
(`pow(max(c * gain + lift * (1 - c), 0), 1 / gamma)`), tone mapping (`NONE`, `ACES` fitted, `AGX`,
`REINHARD`), then the LUT.

## LUT

The LUT is a user artistic LUT applied after tone mapping on display-referred `[0, 1]` color. Lookup
coordinates are sRGB-encoded (the domain grading tools export), the sampled value is decoded back
to linear, and texel centers are addressed with `lut_scale(n) = (n - 1) / n` and
`lut_offset(n) = 0.5 / n`. The texture is a single-mip RGBA8 3D texture, x fastest, then y, then z:
`post::identity_lut(allocator, size)` builds the identity cube and `post::identity_lut_desc(size)`
its description. The identity LUT is a no-op within RGBA8 quantization. File parsing (`.cube`) is
not provided.

## FXAA

FXAA 3.11 quality, preset 12, edge threshold 0.166, minimum 0.0833, subpixel quality 0.75. Luma is
the alpha the grade pass writes (`sqrt` of Rec.709 luma of the display-linear color); the filter
writes alpha one. Enabling FXAA allocates `post_a` (RGBA16_FLOAT, sampled and storage) at the
`hdr_color` size; `post_b` follows only when the compute fallback runs. Disabling retires them
through the frame lifecycle. Resize recreates them with the view targets.

## Temporal anti-aliasing

`anti_aliasing = AntiAliasing.TAA` with `TaaParams { current_weight; clip_gamma; depth_tolerance;
velocity_threshold; mip_bias; debug; }` resolves the view over time on scene-linear color, after
the scene passes and before motion blur, depth of field, bloom and grading. Defaults: current
weight 0.1, clip gamma 1, depth tolerance 0.05 (relative to linear depth), velocity threshold 2
pixels, mip bias -1, no debug output. `configure_view` faults `INVALID_ARGUMENT` for a weight
outside `(0, 1]`, a non-positive gamma, tolerance or threshold, or a mip bias outside
`[TAA_MIP_BIAS_MIN, 0]`; the parameters are checked only while TAA is selected. `LINEAR_HDR` views
may use TAA.

- Jitter: `post::taa_jitter` walks `TAA_SAMPLE_COUNT = 8` Halton(2,3) points, each within half a
  pixel, and `camera::jitter_matrices` applies the offset to the rasterized projection only
  (`FrameRoot.proj`, `view_proj`, `inv_view_proj`; `FrameRoot.jitter_time.xy` holds it in NDC).
  Culling, picking, light selection, shadows and the cluster grid keep the unjittered matrices, and
  `Camera.lens_shift` is untouched. The sample index advances when a rendering is published.
- Velocity follows the motion-blur convention and stays unjittered; a TAA view's `velocity` image
  is RGBA16_FLOAT, with the expected previous reverse-Z depth of each surface in `z`.
- Resolve (`taa_resolve.comp`, one dispatch timed under `TEMPORAL_AA`): the current color is
  rebuilt at the pixel center from its 3x3 jittered samples; the nearest-depth neighbor supplies
  the velocity; history is read at `uv - velocity` with a 5-tap Catmull-Rom filter and clipped to
  the neighborhood's variance box in YCoCg (`mean ± clip_gamma * sigma`). History is rejected
  outside the image, where no texel of the 2x2 depth-history footprint matches the expected
  previous depth within the tolerance, and progressively where current and previous velocity
  differ by `velocity_threshold` to twice that many pixels. The blend weights current and history
  by `1 / (1 + luma)`; rejected history leaves the current sample.
- Images, allocated while TAA is selected and recreated on resize: color (RGBA16_FLOAT), depth
  (R32_FLOAT) and velocity (RG16_FLOAT) histories, two of each, ping-ponged by the view history;
  32 bytes per pixel on top of the view (about 63 MiB at 1080p), plus 4 more for the wider velocity
  image and 8 for the debug image while one is shown.
- `configure_view`, a resize and `render::reset_view_history` (a camera cut) reset one view's
  history; the next rendering resolves from the current sample alone. Two views of one camera keep
  separate histories.
- `mip_bias` biases built-in material texture sampling on TAA views through `FrameRoot.mip_bias`.
  Custom materials opt in with the `sample_custom_map` overload that takes a bias.
- `debug` shows `VELOCITY` (red and green around 0.5, 16 pixels to full scale), `REJECTION`
  (depth rejection red, velocity rejection green, missing history blue) or `HISTORY_WEIGHT` (gray)
  instead of color; the view then skips motion blur, depth of field, bloom, grading and FXAA and
  copies the image to its output.
- A dispatch that writes a TAA view's color (`render::write_view_color`) first moves the resolved
  image into `hdr_color`, so the write never reaches the next resolve.

Documented subset: transparent surfaces carry the velocity of the surface behind them and ghost
when they move; custom vertex stages contribute built-in deformation only; an instance that changes
parity or order inside its batch has wrong velocity for one rendering; `render_to` has no history.
TAA runs at the working resolution; there is no temporal upscaler.

## Bloom

`PostStack.bloom` with `BloomParams { threshold; knee; intensity; levels; }` adds a glow of the
scene's bright regions before grading. Enabling it allocates `levels` RGBA16_FLOAT images (sampled
and storage) starting at half the working resolution and halving per level (`bloom_level_extent`),
at most `BLOOM_MAX_LEVELS` (8). The chain records before the grade stage: a 13-tap downsample from
the scene input into level 0 with the soft threshold (Unity knee curve on the brightest channel)
and Karis averaging, 13-tap downsamples through the remaining levels, then 9-tap tent upsamples
that add each coarser level into the finer one in place. Both display routes sample level 0 inside
`grade_color` and add `intensity` times the sample after exposure, so the scene image itself is
never rewritten. `2 * levels - 1` dispatches are counted and timed under `POST_CHAIN`. Disabling
bloom or changing `levels` retires the chain through the frame lifecycle; resize recreates it.
`configure_view` faults `INVALID_ARGUMENT` when bloom is on with `levels` outside `[1, 8]`.

## Depth of field

`PostStack.depth_of_field` with `DofParams { focus_distance; focal_length; aperture; max_coc; }`
(meters, meters, f-number, half-resolution pixel radius) blurs the scene image around the focus
distance before bloom and grading. The circle of confusion is the thin-lens formula on a 35 mm
frame: `dof_aperture_scale` turns the lens settings into a pixel radius per unit of
`(depth - focus) / depth`, and `dof_coc` clamps the signed result to `max_coc`; negative is in
front of the focus distance, positive behind it, and a texel without geometry (reverse-Z depth 0)
sits at infinity. Depth is linearized from the view's projection terms (`ProjectionTerms`),
perspective or orthographic.

The pass records inside `finish_view`, after any dispatch the application placed between
`render_view` and `finish_view`: `dof_coc.comp` splits each 2x2
block into premultiplied half-resolution near and far layers with their coverage in alpha;
`tile_max.comp` and `tile_neighbor.comp` dilate the near coverage over 16-pixel tiles;
`dof_gather.comp` blurs each layer with a 48-tap disc (the far layer weights taps by their own
circle, the near layer uses the dilated radius so it spreads over sharp background);
`dof_composite.comp` blends far then near over the sharp image and writes `hdr_color` in place.
Six dispatches are counted and timed under `POST_CHAIN`. Enabling allocates four half-resolution
RGBA16_FLOAT layers plus the two RG16_FLOAT tile images; disabling retires them.
`configure_view` faults `INVALID_ARGUMENT` when depth of field is on with a non-positive focal
length, aperture or `max_coc`, or a focus distance not beyond the focal length.

## Motion blur

`PostStack.motion_blur` with `MotionBlurParams { shutter; samples; max_velocity; }` (fraction of the
rendered interval, taps per pixel up to `MOTION_BLUR_MAX_SAMPLES`, pixels) blurs the scene image
along screen motion before depth of field. Velocity is `current_uv - previous_uv` in framebuffer
UV (top-left origin) in an RG16_FLOAT `velocity` image: `velocity_camera.frag` first reprojects
every pixel through the view's previous view-projection from stored depth (no geometry reprojects
as a direction), then a geometry pass with the `VELOCITY` vertex variant redraws the opaque items
that moved, are skinned or morphed, or are instanced batches, with depth test EQUAL and no depth
write. Skinned and morphed surfaces use the palette and morph block the view drew last time, and
instances use their own previous matrices (`DrawRoot.previous_pose`). Both passes are timed under
`VELOCITY`. `tile_max.comp` and `tile_neighbor.comp` reduce the velocity to
16-pixel tile maxima, and `motion_blur.comp` (McGuire 2012) samples `samples` taps along the
tile's dominant motion scaled by `shutter` and clamped to `max_velocity`, weighted by cone,
cylinder and depth order, into `motion_blur_out`, which the later stages read instead of
`hdr_color`. Three dispatches are counted under `POST_CHAIN`.

The previous pose is renderer-owned per view (`ViewHistory`): the camera's view-projection, the
world matrix of every mesh the view drew and the palette, morph block and instance matrices of
the deformed and instanced ones, tagged by entity so a reused slot never matches,
stamped with the rendering so a mesh absent from the last rendering has no previous model when it
returns, and keyed by the scene's identity so a view that switches scenes starts without motion and
a replaced scene needs no reset. It is committed at the end of `render_view` when motion blur or
TAA is on and published when the frame submits; an unsubmitted abort drops it and the next rendering
carries no motion. `configure_view`, a resize and `render::reset_view_history(&renderer, view)`
(a camera cut) reset it; the first rendering after a reset carries no motion. Under an
orthographic projection a depth-zero pixel has zero camera velocity, since a direction has no finite
reprojection there. Enabling allocates the velocity image, the blur
output and the shared tile images; disabling retires them. `configure_view` faults
`INVALID_ARGUMENT` when motion blur is on with `samples` outside `[1, 32]`, a non-positive
`max_velocity` or a negative `shutter`.

## GUI

`gui::post_panel(&view_desc, lut)` edits every setting and returns whether something changed; the
example calls `configure_view` before its next frame when it did. `gui::anti_aliasing_combo`
selects one view's filter on its own. `gui::stats_panel` reports post
dispatches and the completed velocity and post-chain timings.

## Limits

Pass timings describe the last recorded view of the frame; counters accumulate across views.
Auto-exposure is not implemented.

Bloom records only when its intensity is positive or a bloom preview waits for the view; a bloom preview
requested after its view finished stays pending until a frame records the chain. Opaque, sky and
ordinary transparent draws share one attachment pass; transmission ends it for the scene-color
snapshot and continues in loaded passes.
