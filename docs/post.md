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

## GUI

`gui::post_panel(&view_desc, lut)` edits every setting and returns whether something changed; the
example calls `configure_view` before its next frame when it did. `gui::stats_panel` reports post
dispatches and the completed post-chain timing.

## Limits

Only the default window view exists. `LINEAR_HDR` output, off-screen targets and per-view timing
arrive with persistent views. Bloom, depth of field, motion blur and temporal anti-aliasing are
later effects; auto-exposure is not implemented.
