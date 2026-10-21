# Display processing

`c3d::render::post` turns the scene-linear `hdr_color` of a view into display-ready color: tone mapping and grading with
an optional LUT, bloom, depth of field, motion blur and automatic exposure, plus the anti-aliasing filter that
[anti-aliasing](anti_aliasing.md) describes. Every setting lives in `ViewDesc.post`, a `PostStack`, and applies between
frames through `render::configure_view`. [Post reference](post_reference.md) lists every field, default, range and fault.

## Quick start

Import `c3d::render` and `c3d::render::post`.

```c3
ViewDesc desc = render::default_view_desc();
desc.post.grade.tonemap = Tonemap.AGX;
desc.post.grade.saturation = 1.1f;
desc.post.bloom = true;
desc.post.bloom_params.intensity = 0.08f;
render::configure_view(&renderer, renderer.default_view, desc)!;
```

`default_view_desc()` selects `DISPLAY_LDR` with `post::default_post_stack()`: ACES tone mapping, a neutral grade, FXAA, and
every effect and auto exposure off. A zeroed `PostStack` is not neutral. The call copies the description into the view,
uploads a selected LUT, and allocates or retires the working images the enabled effects need.

## Concepts

### Scene-linear in, display out

The scene passes write scene-linear color in physical units to `hdr_color`. The display stage grades it, tone maps it and
writes the view's output rectangle. The `BGRA8_SRGB` swapchain or an sRGB target encodes the result; no shader encodes for
output. Exposure is `Camera.exposure` times, under [auto exposure](#auto-exposure), the view's adapted multiplier.
`GradeParams` carries no exposure of its own.

| `ViewDesc.color` | Result |
| --- | --- |
| `DISPLAY_LDR` | The full display stage: bloom, grade, tone mapping, LUT and the anti-aliasing filter. The default |
| `LINEAR_HDR` | Scene-linear values in physical units in an `RGBA16_FLOAT` or `RGBA32_FLOAT` target |

A `LINEAR_HDR` view skips grading, tone mapping, the LUT, bloom, FXAA and auto exposure. `ViewStats.exposure` reports
`Camera.exposure`, which the view does not apply. TAA, motion blur and depth of field still run. `texture_view_desc`
defaults to `LINEAR_HDR`; a window view cannot use it (`INVALID_ARGUMENT`). A view that shows a TAA debug image also
ignores `auto_exposure`.

### Order of the effects

1. Scene passes, then auto-exposure metering.
2. Temporal anti-aliasing, then motion blur.
3. Depth of field, in `finish_view`, after any dispatch the application placed between `render_view` and `finish_view`.
4. Bloom chain.
5. Grade: exposure, bloom added, white balance (LMS von Kries from temperature and tint), contrast about linear mid-gray
   0.18, saturation on Rec.709 luma, lift-gamma-gain (`pow(max(c * gain + lift * (1 - c), 0), 1 / gamma)`), tone mapping
   (`NONE`, fitted `ACES`, `AGX`, `REINHARD`), then the LUT.
6. FXAA, when selected.

### Pre-exposure

The scene image is stored multiplied by the view's pre-exposure, and the grade applies `exposure / pre_exposure`. Stored
values then sit near display scale at every exposure, with about 16 stops of half-float headroom above display white.

- The factor is `Camera.exposure` times the adapted multiplier, rounded to a power of two and clamped to 2^-16 to 2^16, so
  multiplying and dividing are exact. The adapted multiplier is the one last read back, `FRAMES_IN_FLIGHT` frames old. It is
  1 in manual mode, before the first readback, and after a cut or a scene change until the next readback.
- `ViewDesc.pre_exposure_override` forces the factor: zero follows the camera, otherwise a power of two inside those
  bounds. `ViewStats.pre_exposure` reports it.
- Everything that reads the stored image in absolute units divides first, so its settings keep their units: the exposure
  histogram, the bloom prefilter's threshold and the `LINEAR_HDR` copy. TAA and screen-space GI scale their histories by the
  ratio of consecutive factors.
- Light and radiance inputs are scaled where they are uploaded. A custom stage that emits its own radiance follows the
  rules in [custom shaders](custom_shaders.md#pre-exposure).

## Grade and tone mapping

`PostStack.grade` is a `GradeParams`. The defaults are ACES, contrast 1, saturation 1, temperature 0, tint 0, lift 0, gamma
1, gain 1, no LUT and the unit LUT domain.

```c3
desc.post.grade.tonemap = Tonemap.REINHARD;
desc.post.grade.temperature = 0.2f;   // blue to amber, [-1, 1]
desc.post.grade.lift = { 0.02f, 0.02f, 0.03f };
```

`NONE` clamps the graded color to `[0, 1]`. Temperature and tint are in `[-1, 1]`.

## Apply a LUT

The LUT is an artistic 3D LUT applied after tone mapping on display-referred `[0, 1]` color. It takes sRGB-encoded color
inside its domain and returns sRGB-encoded color; there is no conversion parameter.

- The texture is a single-mip RGBA8 3D texture: x fastest, then y, then z. There is no floating-point LUT.
  `post::identity_lut(allocator, size)` builds the identity cube and `post::identity_lut_desc(size)` its description; the
  identity LUT is a no-op within RGBA8 quantization.
- `GradeParams.lut` names the texture. `lut_domain_min` and `lut_domain_max` give the color range it covers per channel
  (defaults 0 and 1). Colors outside the domain read the edge texels.
- `configure_view` faults `INVALID_ARGUMENT` for a LUT that is not a single-mip RGBA8 3D texture and for a selected LUT whose
  domain is not finite with minimum below maximum in every channel. A zeroed `GradeParams` has an empty domain. A dead LUT id
  faults `INVALID_ID`.

### Load a `.cube` file

`image::parse_lut_cube(allocator, text)` and `image::load_lut_cube(allocator, path, file_source)` read an Adobe `.cube` 3D
LUT, or a Resolve one with `LUT_3D_INPUT_RANGE`, into a `Lut3d { size, domain_min, domain_max, rgba }`.

```c3
image::Lut3d table = image::load_lut_cube(mem, "look.cube")!;
defer image::destroy_lut3d(&table);

desc.post.grade.lut = assets.add_texture(post::lut_texture_desc(&table), table.rgba, "post/look")!;
desc.post.grade.lut_domain_min = table.domain_min;
desc.post.grade.lut_domain_max = table.domain_max;
```

- Read: `LUT_3D_SIZE`, `DOMAIN_MIN`, `DOMAIN_MAX`, `LUT_3D_INPUT_RANGE min max` (one range for all three channels, not
  combined with the domain keywords), `TITLE` (ignored) and `#` comments. Data rows hold three numbers each, red varying
  fastest, then green, then blue. Values clamp to `[0, 1]` and round to RGBA8 with opaque alpha.
- `UNSUPPORTED`: `LUT_1D_SIZE`, or a size outside 2 to `image::MAX_LUT_SIZE` (64).
- `ASSET_FORMAT_ERROR`: a wrong row count, a row without three numbers, a non-numeric or non-finite token, an unknown or
  duplicate keyword, `LUT_3D_INPUT_RANGE` together with a domain keyword, a keyword after the first row, a missing size, or a
  domain whose minimum is not below its maximum in every channel.
- `Lut3d.rgba` belongs to the table and `destroy_lut3d` frees it. `add_texture` copies the texels, so the table can be
  destroyed afterwards.

## Bloom

`PostStack.bloom` enables a glow of the scene's bright regions, configured by `bloom_params` (`BloomParams`). The chain
runs before grading, and the grade adds `intensity` times the blurred bright pass after exposure, so the scene image is
never rewritten.

- `threshold` is the brightness where the glow starts, softened by `knee`. `levels` sets the blur chain length, 1 to
  `BLOOM_MAX_LEVELS` (8).
- Enabling bloom allocates `levels` `RGBA16_FLOAT` images starting at half the working resolution and halving per level.
  Disabling it or changing `levels` retires the chain; a resize recreates it.
- The prefilter divides out the pre-exposure first. Under auto exposure it then multiplies by the adapted multiplier, so
  `threshold` is in auto-exposed units (1.0 is about 2.5 stops above mid-grey after adaptation) and a scene's bloom is the
  same at any absolute radiance. In manual mode `threshold` is in scene units. `Camera.exposure` never changes bloom.
- Bloom records only when its intensity is positive or a bloom preview waits for the view.

## Depth of field

`PostStack.depth_of_field` enables a blur around the focus distance, configured by `dof_params` (`DofParams`). It runs after
motion blur and before bloom.

- The circle of confusion is the thin-lens formula on a 35 mm frame. `focal_length` and `focus_distance` are in meters,
  `aperture` is an f-number, and `max_coc` is the largest radius in half-resolution pixels. A texel without geometry
  (reverse-Z depth 0) sits at infinity. Depth comes from the view's projection, perspective or orthographic.
- The pass splits the image into half-resolution near and far layers, dilates the near coverage over 16-pixel tiles, blurs
  each layer with a disc, and composites far then near over the sharp image into `hdr_color`. The near layer spreads over
  sharp background; the far layer weights taps by their own circle.
- Enabling allocates four half-resolution `RGBA16_FLOAT` layers and two `RG16_FLOAT` tile images.

### Auto focus

`focus_mode` is `MANUAL` by default: the focus is `focus_distance`. `AUTO` meters the focus from the view's own depth;
`focus_distance` then supplies the focus only while nothing has been metered. `default_post_stack()` sets `focus_point` to
the center, `focus_radius` to 16 and `focus_time` to 0.25.

- **Region.** `focus_point` is normalized to the view's image with its origin at the top left, like a mouse position. The
  region is every texel within `focus_radius` pixels of the texel under the point, clipped to the image. A radius of 0 reads
  that one texel.
- **Target.** `finish_view` reads the depth over the region. A texel without geometry or a distance of 2^14 m or more is not
  counted. The target is the median of the rest, so a thin foreground edge does not take the focus, and at least twice
  `focal_length`.
- **Adaptation.** Exponential in distance on a log axis, from the view's own clock: `FrameInfo.time` minus the time of its
  last committed rendering. `focus_time` is the time constant at any frame rate; 0 snaps to the target. A rendering at the
  same time as the previous one holds the focus. Pass a finite `FrameInfo.time`; with the default 0 every rendering snaps.
- **No target.** A region with nothing counted holds the previous focus, and with none, on the first rendering and after a
  cut, the focus is `focus_distance`. The first rendering that meters anything snaps to its target.
- **History.** Per view. `reset_view_history`, a scene change and turning `AUTO` on restart it. Parameter edits and resizes
  keep it, so `focus_point` can move every frame and the focus follows over `focus_time`.
- **Cost.** `AUTO` allocates a small GPU buffer and readback per view and records two extra dispatches. `MANUAL` records
  nothing extra.
- **Readback.** `Renderer.view_stats(view).focus_distance` is the focus in meters: under `AUTO` the adapted value,
  `FRAMES_IN_FLIGHT` frames old and zero until the first readback; under `MANUAL` the `focus_distance` of the last
  rendering.

A world-point target is application policy: compute the distance along the view axis to the point that should be sharp and
set it as a `MANUAL` `focus_distance`.

## Motion blur

`PostStack.motion_blur` enables a blur along screen motion, configured by `motion_blur_params` (`MotionBlurParams`). It
runs after TAA and before depth of field.

- The blur reads the view's [velocity image](anti_aliasing.md#velocity-and-history). The pass reduces velocity to 16-pixel
  tile maxima, then takes `samples` taps along the tile's dominant motion, scaled by `shutter` and clamped to `max_velocity`
  pixels (McGuire 2012). The later stages read its output instead of the scene image.
- `shutter` is a fraction of the rendered interval, `samples` is the taps per pixel up to `MOTION_BLUR_MAX_SAMPLES` (32), and
  `max_velocity` is in pixels.
- The first rendering after `configure_view`, a resize or `reset_view_history` carries no motion.
- Enabling allocates the velocity image, the blur output and the shared tile images.

## Auto exposure

`PostStack.auto_exposure` adapts a `DISPLAY_LDR` view's exposure to its scene, configured by `auto_exposure_params`
(`AutoExposureParams`). It is off by default; `post::AUTO_EXPOSURE_DEFAULT` holds the defaults.

- **Metering.** Each rendering builds a histogram of log2 luminance of the scene image after transparency, fog and the
  screen-space GI copy and before debug lines, TAA, motion blur, application dispatches between `render_view` and
  `finish_view`, depth of field and bloom. Overlays and the GUI are never metered. NaN, infinite and black pixels are not
  counted. The metered value is the mean log2 luminance between `low_percentile` and `high_percentile`, with the
  pre-exposure divided out.
- **Target.** `clamp(log2(0.18) - metered + compensation_ev, min_ev, max_ev)` stops; the exposure is
  `Camera.exposure * 2^ev`. Leave `Camera.exposure` at 1 under auto exposure unless one camera needs a fixed offset.
  `compensation_ev` biases one view in stops.
- **Adaptation.** Exponential in stops from the view's own clock. A brighter scene lowers exposure over `brightening_time`;
  a darker one raises it over `darkening_time` (95 % after three time constants). The result is the same at any frame rate and
  never passes the target; zero times land on it. A frame with nothing metered holds the exposure. Pass a finite
  `FrameInfo.time`; with the default 0 every rendering snaps to its own target.
- **History.** Per view; it survives parameter edits and resizes. `reset_view_history`, a scene change, turning auto
  exposure on and switching a view from `LINEAR_HDR` to `DISPLAY_LDR` restart it, and the first rendering that meters
  anything snaps to its target.
- **Cost.** A small GPU buffer and readback per view and two dispatches. Manual mode records nothing.
- **Readback.** `Renderer.view_stats(view).exposure` reports the applied multiplier, `FRAMES_IN_FLIGHT` frames old and zero
  until the first readback. The readback also sets the view's [pre-exposure](#pre-exposure) from the next rendering on.

## Edit settings in the GUI

`gui::post_panel(&view_desc, lut, &stats)` edits every setting, auto exposure and auto focus included, and, given the view's
`ViewStats`, shows its exposure in stops and its focus distance. It returns whether something changed; call
`configure_view` before the next frame when it did. `gui::anti_aliasing_combo` selects one view's filter on its own.
`gui::stats_panel` reports post dispatches and the completed velocity and post-chain timings.

Run `python3 scripts/build.py --example post` for the panel with a LUT and exposure controls, and `effects` for auto focus
(`--auto-focus`, `--focus-point x y`).

## Limits

- Auto exposure has one metering method, a whole-image percentile histogram, and no local exposure.
- Auto focus has one region and one statistic, the median depth.
- The LUT is RGBA8 and at most 64 on a side.
- Pass timings describe the last recorded view of the frame; counters accumulate across views.
- A bloom preview requested after its view finished stays pending until a frame records the chain.

## See also

- [Post reference](post_reference.md) for fields, defaults, faults, dispatch counts and timings.
- [Anti-aliasing](anti_aliasing.md) for FXAA, TAA, velocity and history.
- [Views](views.md) and [views reference](views_reference.md#viewdesc) for `ViewDesc` and `configure_view`.
- [Sky](sky.md#exposure) for exposure with atmospheres.
- [Custom shaders](custom_shaders.md#pre-exposure) for stages that emit radiance.
- [Benchmarking](benchmarking.md) for post-processing timings.
