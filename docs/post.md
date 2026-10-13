# Display processing

`c3d::render::post` turns the scene-linear `hdr_color` of a `DISPLAY_LDR` view into display-ready
linear color for the view's output. The `BGRA8_SRGB` swapchain or an sRGB target encodes; no shader
encodes for output. `LINEAR_HDR` views skip this module. They also ignore `auto_exposure`, as does a view
while it shows a TAA debug image: a linear output keeps scene-linear values in physical units, and
`ViewStats.exposure` reports `Camera.exposure`, which it does not apply.

```bash
python3 scripts/build.py --example post
./examples/build/post --gpu-timings
```

## Settings

`ViewDesc.post` is the CPU post configuration of a view (see `docs/views.md` for the output
fields). `render::default_view_desc()` selects `DISPLAY_LDR` with `post::default_post_stack()`: ACES,
contrast 1, saturation 1, temperature 0, tint 0, lift 0, gamma 1, gain 1, no LUT with the unit LUT domain, and
`anti_aliasing = AntiAliasing.FXAA`. `AntiAliasing { NONE, FXAA, TAA }` selects one filter per view, so
FXAA and TAA never stack. A zeroed `PostStack` is not neutral. Multisampling is `ViewDesc.msaa`, not a post
setting: it excludes `TAA`, combines with `FXAA`, which filters the resolved image, and leaves bloom, depth of field,
motion blur and grading unchanged, because every one reads single-sample images (see
[multisample anti-aliasing](views.md#multisample-anti-aliasing)).

Apply a configuration between frames with `render::configure_view(&renderer, renderer.default_view,
desc)`. The call copies the description into the view record, uploads a selected LUT, and allocates
or retires the two working images FXAA needs. `LINEAR_HDR` faults `INVALID_ARGUMENT` on a window
view; a dead view or LUT faults `INVALID_ID`; a LUT that is not a single-mip RGBA8 3D texture, or a selected LUT
whose [domain](#lut) is not finite with `lut_domain_min` below `lut_domain_max` in every channel, faults
`INVALID_ARGUMENT`.

Exposure is `Camera.exposure` (05 Cameras) times, under [auto exposure](#auto-exposure), the view's adapted
multiplier. `GradeParams` carries no exposure of its own.

### Pre-exposure

The scene image is stored multiplied by the view's pre-exposure, and the grade applies
`exposure / pre_exposure`. The factor is `Camera.exposure` times the adapted multiplier, rounded to a power of two
and clamped to 2^-16 to 2^16, so multiplying and dividing are exact. The adapted multiplier is the one last read
back (`FRAMES_IN_FLIGHT` frames old); the adapted multiplier is 1 in manual mode, before the first readback and
after a cut or a scene change until the next readback, so the factor then follows `Camera.exposure` alone. Stored
values sit near display scale at every exposure, with about 16 stops of half-float headroom above display white, so
a dim scene is not stored in the subnormal range.
`ViewDesc.pre_exposure_override` forces the factor, which must be a power of two inside those bounds, and
`ViewStats.pre_exposure` reports it.

Everything that reads the stored image in absolute units divides first, so its settings keep their units: the
exposure histogram, the bloom prefilter's threshold and the `LINEAR_HDR` copy. TAA and screen-space GI
multiply their histories by the ratio of consecutive factors. TAA's `1 / (1 + luma)` weights and its variance clip
work in stored units, so they follow the exposed image rather than absolute radiance. Light and radiance inputs
are scaled where they are uploaded; see [custom shaders](custom_shaders.md#pre-exposure) for stages that emit
their own radiance.

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

The LUT is a user artistic LUT applied after tone mapping on display-referred `[0, 1]` color. The input is
sRGB-encoded display-referred color inside the LUT domain and the output is sRGB-encoded; there is no conversion
parameter. Lookup coordinates are sRGB-encoded (the domain grading tools export), the sampled value is decoded back
to linear, and texel centers are addressed with `lut_scale(n) = (n - 1) / n` and `lut_offset(n) = 0.5 / n`.
The texture is a single-mip RGBA8 3D texture, x fastest, then y, then z; there is no floating-point LUT.
`post::identity_lut(allocator, size)` builds the identity cube and `post::identity_lut_desc(size)` its description.
The identity LUT is a no-op within RGBA8 quantization.

### Domain

`GradeParams.lut_domain_min` and `lut_domain_max` give the color range the LUT covers, per channel; the defaults
are 0 and 1. The lookup maps `(c - min) / (max - min)` before the texel-center mapping, with the domain folded into
`GradeGpu.lut_scale` and `lut_offset` on the CPU, so the shader keeps one multiply-add. A unit domain produces the
same values as no domain. Colors outside the domain read the edge texels. A zeroed `GradeParams` has an empty domain
and is not neutral; `configure_view` faults `INVALID_ARGUMENT` for a selected LUT whose domain is not finite with
`min < max` in every channel.

### `.cube` files

`image::parse_lut_cube(allocator, text)` and `image::load_lut_cube(allocator, path, file_source)` read an Adobe
`.cube` 3D LUT, or a Resolve one with `LUT_3D_INPUT_RANGE`, into a `Lut3d { size, domain_min, domain_max, rgba }`.

- Read: `LUT_3D_SIZE`, `DOMAIN_MIN`, `DOMAIN_MAX`, `LUT_3D_INPUT_RANGE min max` (the Resolve spelling: one range for
  all three channels, not combined with `DOMAIN_MIN` or `DOMAIN_MAX`), `TITLE` (accepted and ignored) and `#`
  comment lines. Data rows hold three numbers each, red varying fastest, then green, then blue. Values clamp to
  `[0, 1]` and round to RGBA8 with opaque alpha.
- `UNSUPPORTED`: `LUT_1D_SIZE`, or a size outside 2 to `image::MAX_LUT_SIZE` (64, 1 MiB of RGBA8).
- `ASSET_FORMAT_ERROR`: a wrong row count, a row without three numbers, a non-numeric or non-finite token, an
  unknown keyword, a duplicate keyword, `LUT_3D_INPUT_RANGE` together with `DOMAIN_MIN` or `DOMAIN_MAX`, a keyword
  after the first row, a missing size, or a domain whose minimum is not below its maximum in every channel.
- Ownership: `Lut3d.rgba` is allocated with the allocator passed to the parser and belongs to the table;
  `image::destroy_lut3d(&lut)` frees it. `post::lut_texture_desc(&lut)` describes the texture and holds no pixels.
  `AssetStore.add_texture(post::lut_texture_desc(&lut), lut.rgba, key)` copies the texels, so the table can be
  destroyed afterwards. The application sets `GradeParams.lut` to the texture and copies `domain_min` and
  `domain_max` into the grade.

The post example's key `G` (and the "Cube LUT" box) switches between no LUT and a teal and orange `.cube` look
embedded from `examples/assets/lut`; `--cube-lut` starts with it on and `--cube-lut-file <path>` loads another file.

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

Documented subset: a one-pixel rim outside moving silhouettes takes the current sample, because the
dilated velocity reprojects it onto background the object uncovered or covered, which the depth
and velocity tests reject; a view that renders a different scene than its last rendering resolves
from the current sample; blended surfaces carry the velocity of the surface behind them and ghost
when they move; depth-writing scene-read surfaces carry their own velocity on views that record
velocity after the scene; custom vertex stages contribute their displacement only through a velocity
form; an instance that changes parity or order inside its batch has wrong velocity for one rendering;
`render_to` has no history. TAA runs at the working resolution; there is no temporal upscaler.

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
The prefilter divides out the pre-exposure first. Under auto exposure it then multiplies its input by the adapted multiplier, so `threshold` is in
auto-exposed units (1.0 is about 2.5 stops above mid-grey after adaptation) and a scene's bloom is the same
at any absolute radiance. In manual mode `threshold` is in scene units. `Camera.exposure` never changes bloom.

## Depth of field

`PostStack.depth_of_field` with `DofParams { focus_distance; focal_length; aperture; max_coc; focus_mode;
focus_point; focus_radius; focus_time; }` (meters, meters, f-number, half-resolution pixel radius; the focus
fields are under [Auto focus](#auto-focus)) blurs the scene image around the focus
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
length, aperture or `max_coc`, or a focus distance not beyond the focal length, or, in either focus mode, a
`focus_point` outside `[0, 1]` on an axis or a `focus_radius` or `focus_time` that is negative or not finite.

### Auto focus

`focus_mode` is `MANUAL` by default: the focus is `focus_distance` and nothing below applies. `AUTO` meters the
focus from the view's own depth; `focus_distance` then only supplies the focus while nothing has been metered.
`default_post_stack()` sets `focus_point` to the center, `focus_radius` to 16 and `focus_time` to 0.25.

- Region: `focus_point` is normalized to the view's image with its origin at the top left, like a mouse position.
  The region is every texel whose center lies within `focus_radius` pixels of the center of the texel under the point,
  clipped to the image. A `focus_radius` of 0 reads that one texel.
- Metering: `finish_view` reads the view's depth over the region, linearized as above. A texel without geometry (depth
  0) and a distance of 2^14 m or more are not counted. The rest go into a 256-bin histogram of log2 distance from
  2^-6 m to 2^14 m, about 5.6 % per bin, with nearer distances in the first bin. The target is the median, the sample
  of rank n / 2, placed at the mean position of the samples in its bin: a flat target meters its own distance and a
  thin foreground edge does not take the focus. The target is at least twice `focal_length`, unit magnification.
- Adaptation: exponential in distance, on a log axis, from the view's own clock, `FrameInfo.time` minus the time of its
  last committed rendering. `focus_time` is the time constant: the remaining log distance to the target falls to
  1/e every `focus_time` seconds, whatever the frame rate, and never passes the target. A `focus_time` of 0 snaps to
  the target with no adaptation. A rendering at the same time as the previous one holds the focus. Pass a finite
  `FrameInfo.time`: with the default 0 every rendering snaps to its own target.
- No target: a region with nothing counted, because it is all sky, background or farther than the histogram reaches,
  holds the previous focus. When there is none, on the first rendering and after a cut, the focus is `focus_distance`.
  The first rendering that meters anything snaps to its target.
- History: per view, so two views of one camera adapt independently. `reset_view_history`, a scene change and
  turning `AUTO` on (through `configure_view`, enabling depth of field, or hiding a TAA debug image) restart it.
  Parameter edits and resizes keep it, so `focus_point` can move every frame and the focus follows over `focus_time`.
  An aborted frame changes nothing; a skipped view folds the elapsed time into its next step.
- Cost: `AUTO` allocates a 2,080-byte GPU allocation and a 32-byte readback per view at its first automatic rendering
  and records two dispatches, counted in `Stats.post_dispatches` and timed under `POST_CHAIN`. `MANUAL` records and
  binds nothing extra.
- `Renderer.view_stats(view).focus_distance` is the focus in meters: under `AUTO` the adapted value, `FRAMES_IN_FLIGHT`
  frames old and zero until the first readback, and under `MANUAL` the `focus_distance` of the last rendering.
- World-point targets are application policy, not a mode. The application computes the distance along the view axis
  to the point it wants sharp and sets a `MANUAL` `focus_distance`.

## Motion blur

`PostStack.motion_blur` with `MotionBlurParams { shutter; samples; max_velocity; }` (fraction of the
rendered interval, taps per pixel up to `MOTION_BLUR_MAX_SAMPLES`, pixels) blurs the scene image
along screen motion before depth of field. Velocity is `current_uv - previous_uv` in framebuffer
UV (top-left origin) in an RG16_FLOAT `velocity` image: `velocity_camera.frag` first reprojects
every pixel through the view's previous view-projection from stored depth (no geometry reprojects
as a direction), then a geometry pass with the `VELOCITY` vertex variant redraws the opaque items
that moved, are skinned or morphed, have [edited vertices](#edited-vertices), or are instanced batches, with depth test EQUAL and no depth
write. Items whose custom shader supplies a [velocity form](custom_shaders.md#velocity-form) for the
draw are redrawn through that form on every rendering with history, and on views that record velocity
after the scene the pass also redraws the moved depth-writing items of the scene-read list. Skinned
and morphed surfaces use the palette and morph block the view drew last time, and instances use
their own previous matrices (`DrawRoot.previous_pose`). Both passes are timed under
`VELOCITY`. `tile_max.comp` and `tile_neighbor.comp` reduce the velocity to
16-pixel tile maxima, and `motion_blur.comp` (McGuire 2012) samples `samples` taps along the
tile's dominant motion scaled by `shutter` and clamped to `max_velocity`, weighted by cone,
cylinder and depth order, into `motion_blur_out`, which the later stages read instead of
`hdr_color`. Three dispatches are counted under `POST_CHAIN`.

The previous pose is renderer-owned per view (`ViewHistory`): the camera's view-projection, the
rendering's `FrameInfo.time` (read back as `FrameRoot.previous_time`), the world matrix of every
mesh the view drew and the palette, morph block and instance matrices of the deformed and instanced
ones, tagged by entity so a reused slot never matches,
stamped with the rendering so a mesh absent from the last rendering has no previous model when it
returns, and keyed by the scene's identity so a view that switches scenes starts without motion and
a replaced scene needs no reset. It is committed at the end of `render_view` when motion blur or
TAA is on and published when the frame submits; an unsubmitted abort drops it and the next rendering
carries no motion. `configure_view`, a resize and `render::reset_view_history(&renderer, view)`
(a camera cut or a jump in `FrameInfo.time`) reset it; the first rendering after a reset carries no
motion. Under an orthographic projection a depth-zero pixel has zero camera velocity, since a
direction has no finite reprojection there. Enabling allocates the velocity image, the blur
output and the shared tile images; disabling retires them. `configure_view` faults
`INVALID_ARGUMENT` when motion blur is on with `samples` outside `[1, 32]`, a non-positive
`max_velocity` or a negative `shutter`.

### Edited vertices

`Mesh.vertex_motion = true` gives an ordinary mesh (not a batch, crowd or LOD group) velocity
for CPU-edited positions. Edit `assets.geometry(id).data.positions` in place, recompute normals
when needed and publish the edit before recording the frame, as described under
[Publishing geometry edits](#publishing-geometry-edits). Vertex indices
must keep naming the same vertices: a new correspondence needs a new `GeometryId`, and a changed
vertex count starts over.

Each temporal view copies the base positions of the flagged meshes it drew into its pose history
(12 bytes per vertex, allocated on first use or a count change, reused afterwards and freed with
the history). When the geometry revision differs from the copy, the velocity pass uploads the copy
through the frame ring into `PreviousPoseGpu.positions` and composes it with the previous morph,
skin and model, so a stationary node shows its deformation. An unchanged revision keeps the
ordinary rule. A first observation, another geometry or count, re-enabling after an untracked
rendering, a reset, a missing previous rendering or an aborted capture writes zero motion and sets
the rejection channel (`DRAW_VERTEX_HISTORY_INVALID`), so TAA, screen-space GI, temporal
ambient occlusion and the reflection history drop history for those pixels only; an RG16 velocity image keeps the zero motion. A temporal view faults
`c3d::ASSET_DATA_UNAVAILABLE` from `render_view` before recording when a flagged mesh's CPU
positions were released; its published history stays as it was.

Every pose slot grows by 32 bytes (176 to 208), 512 KiB per temporal view at the default
16,384-node scene. Geometry uploads what its edit published, counted in `Stats.upload_bytes`;
previous positions travel through the frame ring, counted per frame in
`Stats.vertex_history_bytes`. Blended surfaces keep the velocity of the surface behind them.

### Publishing geometry edits

An in-place edit of `assets.geometry(id).data` reaches the renderer through one of three calls, each of
which advances the geometry revision:

| Call | The renderer copies |
| --- | --- |
| `mark_geometry_streams_dirty(id, streams)` | Every vertex of each named stream |
| `mark_geometry_range_dirty(id, streams, first_vertex, vertex_count)` | The named vertices of each named stream |
| `mark_geometry_dirty(id)` | The whole block |

`streams` is a `GeometryStreams`: `positions`, `normals`, `tangents`, `uv0`, `uv1`, `colors`, `joints`,
`weights` and `custom`. The marked streams must exist in the geometry, `vertex_count` is positive and
the range lies inside the vertex count; each is a contract. A stream mark names only data the edit
changed: an unmarked edit is not uploaded.

The record keeps one vertex range per stream since the renderer last held the geometry. A second mark
before the next resolve extends that union, so two distant ranges of one stream cover the vertices
between them. When the layout is unchanged and only stream ranges are marked, the renderer stages each
stream's range, packed as the whole block packs it, and queues one copy region per stream into the
existing block behind the barrier a whole overwrite uses. `Stats.upload_bytes` counts those staged
bytes. The renderer uploads the whole block instead after `mark_geometry_dirty`, after a replacement,
when a stream appears or disappears, when the vertex or index count, the morph target count or the
joint packing width changes, and for a geometry it has never uploaded or whose upload an aborted frame
dropped. Index and morph-target edits have no stream, so they publish with `mark_geometry_dirty`.

The store recomputes derived data only from the marked streams: the 16-bit joint packing width when
`joints` is marked, and the skin and morph bounds when `positions`, `joints` or `weights` is marked.
`mark_geometry_dirty` recomputes all of it. `Geometry.bounds` is never recomputed by a mark; call
`Geometry.finalize` after editing positions. Traced and temporal consumers read only the revision, so
they behave the same for every call. The ranges are relative to the revision the last resolving renderer
held, so a renderer whose copy is at another revision, such as a second renderer on the same store,
uploads whole.

## Auto exposure

`PostStack.auto_exposure` with `AutoExposureParams { compensation_ev; min_ev; max_ev; brightening_time;
darkening_time; low_percentile; high_percentile; }` adapts a `DISPLAY_LDR` view's exposure to its scene. It is off by
default; `post::AUTO_EXPOSURE_DEFAULT` holds compensation 0, bounds -10 to +10 stops, 0.5 s brightening, 2 s
darkening and the 10th to 90th percentile window. `configure_view` faults `INVALID_ARGUMENT` while it is on for a
non-finite field, `min_ev > max_ev`, a negative time, percentiles outside `0 <= low < high <= 1`, or a compensation
and bounds whose targets leave the histogram's luminance range (log2 -18 to 14).

- Metering: each rendering builds a 256-bin histogram of log2 luminance (Rec.709 weights, 1/8 stop per bin) of the
  scene image after transparency, fog and the SSGI copy and before debug lines, TAA, motion blur,
  application dispatches between `render_view` and `finish_view`, depth of field and bloom. Overlays and the GUI are
  never metered. Jitter and the blurs barely move the mean, and bloom is not in the metered image. NaN, infinite and
  black pixels (below the smallest half float) are not counted; brighter or darker values clamp into the edge bins.
  The metered value is the mean log2 luminance between the two percentiles. The meter reads the image before
  exposure and divides out the pre-exposure, so the result depends on the scene alone.
- Target: `clamp(log2(0.18) - metered + compensation_ev, min_ev, max_ev)` stops; the final exposure is
  `Camera.exposure * 2^ev`. Leave `Camera.exposure` at 1 under auto exposure unless one camera needs a fixed
  offset; `compensation_ev` biases one view in stops.
- Adaptation: exponential in stops from the view's own clock, `FrameInfo.time` minus the time of its last committed
  value: a brighter scene lowers exposure over `brightening_time`, a darker one raises it over `darkening_time`
  (95 % after three time constants). The result is the same at any frame rate and never passes the target; zero
  times always land on the target. Every step clamps into the current bounds, so narrowing them takes effect at the
  next rendering. A frame with nothing metered holds the exposure. After a cut or a fresh history, the first
  rendering that meters anything snaps. Pass a finite `FrameInfo.time`: with the default 0 every rendering snaps to
  its own target, without smoothing.
- History: per view, so two views of one camera adapt independently. Kept across parameter edits and resizes;
  `reset_view_history`, a scene change, turning auto exposure on and switching a view with auto exposure from
  `LINEAR_HDR` to `DISPLAY_LDR` or hiding a TAA debug image restart it, and the first rendering that meters anything
  snaps to its target. An aborted frame changes nothing; a skipped or dormant view folds the elapsed time into its
  next step.
- Cost: one 1,056-byte GPU allocation and a 32-byte readback per view, allocated with the view; two dispatches timed
  under `EXPOSURE` and counted in `Stats.post_dispatches`. Manual mode records nothing and binds nothing.
- `Renderer.view_stats(view).exposure` reports the applied multiplier, `FRAMES_IN_FLIGHT` frames old under auto
  exposure. On a view created with auto exposure on it is zero until the first readback.
- Its readback also sets the view's [pre-exposure](#pre-exposure) from the next rendering on.

### Measured cost

On an RTX 4090 with Sponza through the benchmark at 2560 x 1440, the `EXPOSURE` pass costs 0.034 ms at meter
stride 1 and 0.020 ms at stride 2; the stride stays 1. Auto exposure adds 0.035 ms of GPU time per frame (the median
per-case delta). In the post example's light scene the pass reads 0.029 ms at 1920 x 1080 and 0.049 ms at
2560 x 1440, with the GPU at low clocks.

## GUI

`gui::post_panel(&view_desc, lut, &stats)` edits every setting, auto exposure and auto focus included, and, given the
view's `ViewStats`, shows its exposure in stops, `FRAMES_IN_FLIGHT` frames old under auto exposure, and its focus
distance. It returns whether something changed; the
example calls `configure_view` before its next frame when it did. The post example's key `L` (and the "Lights at
1/16" box) scales the sun, the ambient term, the lamp's emission and the textured material by 1/16, a four-stop
step that auto exposure undoes. The ray-traced controls are enabled on
every renderer, since traced effects run without ray queries too; reflections stay disabled on a
`PATH_TRACED` view. `gui::anti_aliasing_combo`
selects one view's filter on its own. The effects example's key `F` toggles auto focus, and while it is on, "Focus
follows cursor" moves `focus_point` under the mouse; `--auto-focus` starts with it on and `--focus-point x y`
fixes the point in `[0, 1]`. `gui::stats_panel` reports post
dispatches and the completed velocity and post-chain timings.

## Limits

Pass timings describe the last recorded view of the frame; counters accumulate across views.
Auto exposure has one metering method (a whole-image percentile histogram), no local exposure, and meters the
image before TAA, motion blur, depth of field and application dispatches.
Auto focus has one region and one statistic, the median depth; targets in the world are set through `MANUAL`.

Bloom records only when its intensity is positive or a bloom preview waits for the view; a bloom preview
requested after its view finished stays pending until a frame records the chain. Opaque, sky and
ordinary transparent draws share one attachment pass; a scene reader (Physical transmission or a
custom material with scene reads) ends it for the scene snapshots, and drawing continues in loaded
passes.
