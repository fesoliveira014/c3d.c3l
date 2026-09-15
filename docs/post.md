# Display processing

`c3d::render::post` turns the scene-linear `hdr_color` of the default view into display-ready
linear color for the window. The `BGRA8_SRGB` swapchain encodes; no shader encodes for output.

```bash
python3 scripts/build.py --example post
./examples/build/post --gpu-timings
```

## Settings

`ViewDesc { OutputMode color; PostStack post; }` is the CPU configuration of a view.
`render::default_view_desc()` selects `DISPLAY_LDR` with `post::default_post_stack()`: ACES,
contrast 1, saturation 1, temperature 0, tint 0, lift 0, gamma 1, gain 1, no LUT, FXAA on. A
zeroed `PostStack` is not neutral.

Apply a configuration between frames with `render::configure_view(&renderer, renderer.default_view,
desc)`. The call copies the description into the view record, uploads a selected LUT, and allocates
or retires the two working images FXAA needs. `LINEAR_HDR` faults `INVALID_ARGUMENT` on the window
view; a dead view or LUT faults `INVALID_ID`; a LUT that is not a single-mip RGBA8 3D texture faults
`INVALID_ARGUMENT`.

Exposure is `Camera.exposure` (05 Cameras). `GradeParams` carries no exposure of its own; the
renderer packs the scene view's camera exposure into the display root each frame.

## Routes

- FXAA off: `hdr_color` is sampled by `display.frag`, which grades, tone maps and applies the LUT
  in the final fullscreen pass. No working image exists; `Stats.post_dispatches` is zero and the
  `POST_CHAIN` timing is empty.
- FXAA on: `grade.comp` writes the graded LDR image and its perceptual luma (alpha) into `post_a`;
  `fxaa.comp` reads `post_a` and writes `post_b`; the identity composite copies `post_b` to the
  window. Two dispatches are counted and timed under `POST_CHAIN`.

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
writes alpha one. Enabling FXAA allocates `post_a` and `post_b` (RGBA16_FLOAT, sampled and storage)
at the `hdr_color` size; disabling retires them through the frame lifecycle. Resize recreates them
with the view targets.

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

The pass records inside `render_view` after the forward passes: `dof_coc.comp` splits each 2x2
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
as a direction), then a geometry pass with the `VELOCITY` vertex variant redraws only the opaque
items whose model matrix changed, with depth test EQUAL and no depth write. Skinned and morphed
surfaces contribute their node's rigid motion only; a previous deformed pose is not kept. Both
passes are timed under `VELOCITY`. `tile_max.comp` and `tile_neighbor.comp` reduce the velocity to
16-pixel tile maxima, and `motion_blur.comp` (McGuire 2012) samples `samples` taps along the
tile's dominant motion scaled by `shutter` and clamped to `max_velocity`, weighted by cone,
cylinder and depth order, into `motion_blur_out`, which the later stages read instead of
`hdr_color`. Three dispatches are counted under `POST_CHAIN`.

The previous pose is renderer-owned per view (`ViewHistory`): the camera's view-projection and
the world matrix of every mesh the view drew, tagged by entity so a reused slot never matches.
It is committed at the end of `render_view` when motion blur is on and reset by `configure_view`,
by a resize and by `render::reset_view_history(&renderer, view)` (a camera cut); the first
rendering after a reset carries no motion. An aborted frame keeps its commit, so at most one frame
of invented motion follows a failed submission. Enabling allocates the velocity image, the blur
output and the shared tile images; disabling retires them. `configure_view` faults
`INVALID_ARGUMENT` when motion blur is on with `samples` outside `[1, 32]`, a non-positive
`max_velocity` or a negative `shutter`.

## GUI

`gui::post_panel(&view_desc, lut)` edits every setting and returns whether something changed; the
example calls `configure_view` before its next frame when it did. `gui::stats_panel` reports post
dispatches and the completed velocity and post-chain timings.

## Limits

Only the default window view exists. `LINEAR_HDR` output, off-screen targets and per-view timing
arrive with persistent views. Temporal anti-aliasing is a later effect; auto-exposure is not
implemented.
