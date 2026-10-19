# Ray-traced reflections

A deferred or forward view can replace the environment reflection of smooth surfaces with reflections traced
against the scene, so a mirror floor shows the objects around it, including ones outside the view.

```c3
Renderer renderer = render::create_renderer(mem, &assets, { .ray_queries = true })!;
ViewDesc desc = render::default_view_desc();
desc.shading = ShadingPath.DEFERRED;
desc.ray_tracing.reflections = true;
render::configure_view(&renderer, renderer.default_view, desc)!;
```

## Settings

`ViewDesc.ray_tracing` is a `RayTracingDesc`:

| Field | Meaning |
| --- | --- |
| `shadows` | Ray-traced shadows (see [shadows](shadows.md)) |
| `reflections` | Ray-traced reflections on this view |
| `max_reflection_roughness` | Surfaces rougher than this keep the environment reflection; in `(0, 1]` while `reflections` is set |
| `reflection_rays` | Rays per traced pixel, 1 to `RT_REFLECTION_RAYS_MAX` (4); zero reads as 1 |
| `reflection_resolution` | `FULL` traces every pixel; `HALF` traces one of each 2 x 2 block ([half resolution](#half-resolution)) |
| `reflection_history` | Blends each traced pixel with the previous frames' reflection ([history](#history)); off by default |

`default_view_desc` and `texture_view_desc` set `max_reflection_roughness` to
`RT_REFLECTION_ROUGHNESS_DEFAULT` (0.5). `create_view` and `configure_view` fault:

- `UNSUPPORTED` when `reflections` is set on a `PATH_TRACED` view. On a renderer created without
  `RendererDesc.ray_queries` the reflection rays run on the software walk
  ([scene tracing](scene_trace.md)). On an RTX 4090 (Sponza, 2160p) they cost about 12 times the
  ray-query rays: 5.4 ms against 0.45 ms.
- `INVALID_ARGUMENT` when `reflections` is set and `max_reflection_roughness` is not finite or
  lies outside `(0, 1]`, or `reflection_rays` is above `RT_REFLECTION_RAYS_MAX`.

`reflection_rays`, `reflection_resolution` and `reflection_history` are ignored while `reflections` is clear. The
defaults, one ray at full resolution with no history, give the images of a view that sets none of them.

The view allocates two `RGBA16_FLOAT` images at its working extent, `reflection` and
`reflection_blur`, while `reflections` is set, and retires them when it is cleared. `HALF` adds a third,
`reflection_half`, at the working extent halved and rounded up. `reflection_history` adds two `RGBA16_FLOAT`
history images and two `R32_FLOAT` depth images at the working extent. A `FORWARD` view also
allocates `reflection_gbuffer` ([forward views](#forward-views)).

## What traces

Reflections read the deferred G-buffer, so they apply to the view's G-buffer surfaces: Standard
materials and Physical materials without clearcoat, sheen, anisotropy, transmission or specular
overrides. Materials the G-buffer cannot encode keep their forward shading and the environment
reflection. A pixel traces when it has geometry, a specular weight above zero and a roughness at
or below `max_reflection_roughness`. On a deferred view with one sample per pixel a ray also ignores the hits on
[trace proxies](scene_trace.md#trace-proxies) that its pixel's G-buffer flags name.

Each such pixel casts `reflection_rays` rays (one by default), each sampled from the GGX distribution of visible
normals (Dupuy and Benyoub 2023) around the G-buffer normal, and averages their radiance. Ray `n` of a frame uses
noise sequence `noise_frame * rays + n`, so a single ray uses `noise_frame` as before. The sample rotates with
interleaved gradient noise, per frame on a TAA view, where TAA averages it, and on a view with
[`reflection_history`](#history), where the history does; otherwise a still camera shows a fixed grain on rougher
surfaces, which more rays reduce.

- **Hit.** The hit surface is shaded from its material: `STANDARD` with the Standard BRDF,
  `PHYSICAL` with the forward Physical stage's lobes (see below), `BASIC` unlit, `TOON` with its
  bands and rim as the forward Toon stage evaluates them, `CUSTOM` as a constant grey albedo under
  Lambert lighting, since custom shader code cannot run at a hit. Direct light comes from the
  [reflection light list](#reflection-lights); a light that casts shadows casts them at the hit
  through a shadow ray. Emission, the ambient fill and the lighting environment add to it. Textures
  sample at a level of detail from the ray's cone footprint (ray cones, Akenine-Möller et al. 2019);
  normal maps are read at hits and occlusion maps are not.
- **Physical hit.** A `PHYSICAL` hit reads the specular weight, specular colour and IOR, the
  clearcoat factor, roughness and normal, the sheen colour and roughness, the anisotropy strength
  and direction, and the transmission and thickness, through the same maps as the forward stage, and
  calls the forward stage's direct and environment evaluation. The anisotropy frame comes from the
  vertex tangent stream when the geometry has one, and from the hit triangle's positions and UVs
  (the anisotropy map's set, UV0 when unmapped) otherwise; it never uses screen derivatives. A hit
  has no scene snapshot, so the transmitted part reads the lighting environment and the reflection
  probes along the refracted direction, the forward stage's off-screen fallback, with the same
  `1 - F`, base colour and volume attenuation weights; the scene behind a glass hit and its fog are
  not seen. A hit composes the transmitted light and the ambient fill under the sheen and clear coat
  layers with the forward stage's own `transmitted_light` and `physical_fill`.
- **Sheen tables.** Sheen at a hit reads the sheen albedo table and the sheen environment the view
  carries. A reflection view carries them once the renderer has resolved a sheen material, which
  `prepare_scene` does ahead of the first frame; a sheen surface that only a reflection shows, in a
  scene nothing prepared, shades without its sheen lobe on the frame that first resolves it.
- **Fog.** A hit takes the view's height fog and, behind it, the scene's atmosphere over the path from the
  reflecting surface to the hit, and a miss takes the height fog to infinity; the camera's own fog pass fogs the
  rest ([fog at hits](sky.md#where-fog-applies)).
- **Back face.** A reflection ray passes the back of a single-sided surface, as raster culls it,
  and reflects what lies behind; double-sided materials shade both sides
  ([facing](scene_trace.md#facing)).
- **Miss.** A ray that leaves the scene reads the lighting environment at its sharpest level
  (`scene.environment`, not the background), or the ambient colour without an environment. A miss
  never reads a reflection probe: indoor misses happen only through openings or excluded geometry
  (`RT_REFLECTION_FAR` is 1e4), and a ray through excluded geometry reads the global environment.

A spatial blur then averages each traced pixel with neighbours of similar depth, normal,
roughness and specular weight over a 5x5 footprint that widens with roughness; mirror-like pixels are not blurred.

Traced reflections ignore a view's clip plane: they trace the whole scene. A planar mirror is a
clipped view of its own (see [clip plane](views.md#clip-plane)).

## Material edges

The blur and the half-resolution reconstruction skip a neighbour whose roughness differs from the pixel's by more than
0.1 or whose specular weight differs by more than `RT_REFLECTION_SPECULAR_TOLERANCE` (0.1). Pixels on either side of a
specular-weight edge, such as two Physical materials with different `specular`, then never average into each other, so
a reflection does not smear across the boundary. A pixel beside an edge averages fewer neighbours and shows more
grain, within the blur's footprint. The weight comes from the G-buffer `emissive_specular` alpha on a deferred view
and from the alpha of `reflection_gbuffer` on a forward view. Surfaces of equal specular weight, such as every
Standard material, behave as before.

## Half resolution

With `reflection_resolution` set to `HALF` the trace writes `reflection_half`, one texel per 2 x 2 block, and spends a
quarter of the rays. Texel `t` traces the pixel `2t + o` of the working extent, clamped to the image. With TAA the
offset `o` steps through (0, 0), (1, 1), (1, 0) and (0, 1) with the noise frame, so four frames cover each block;
without TAA or `reflection_history` it stays (0, 0).

A reconstruction pass then fills `reflection`: each pixel takes the 2 x 2 texels around it, weighted bilinearly by the
pixel's position among the traced pixels and by the blur's depth and normal weights. A texel counts for nothing when
its pixel has a roughness more than 0.1 away or a specular weight more than `RT_REFLECTION_SPECULAR_TOLERANCE` away,
or when it traced nothing. A pixel with no compatible texel is untraced: it keeps the prefiltered specular and the
surface shows no traced reflection there. The blur follows as at full resolution.

## History

With `reflection_history` set the view blends each traced pixel with the reflection the previous frames traced there,
so a still camera averages the noise of many frames without TAA, and TAA receives a steadier input. A temporal pass
runs after the trace, and after the reconstruction at `HALF`, and before the blur, which reads its output.

- **Images.** `reflection_history[2]` (`RGBA16_FLOAT`) holds the blended radiance with alpha 1 where the pixel traced and
  0 where it did not. `reflection_depth[2]` (`R32_FLOAT`) holds the depth the pass saw. Both are at the working
  extent, 16.6 MB and 8.3 MB each at 1080p. `ViewHistory.slot` selects the one read and the one written. The images are
  allocated with the view while the field is set, retired when it is cleared or the view is resized, and the pass
  reads no history on the frame after `reset_view_history`, `configure_view`, a resize or a change of scene.
- **Reprojection.** The pass fetches the history at the pixel centre minus the view's velocity, filtered bilinearly,
  without the frame's jitter. The view records its velocity before the reflections, with the previous frame's depth in
  `z`, as it does for temporal ambient occlusion and screen-space GI, and commits a `ViewHistory` for itself.
- **Confidence.** The product of: a depth match (any of the four history depths within 5% of the expected previous
  depth); TAA's velocity ramp, full below 2 pixels of motion and zero from 4; one minus the velocity's rejection flag;
  a material match (the current G-buffer at the history position has a roughness within 0.1 and a specular weight
  within `RT_REFLECTION_SPECULAR_TOLERANCE` of the pixel's); and the traced share of the filtered history texels. An
  untraced history texel counts nothing.
- **Weight.** The kept share is `RT_REFLECTION_HISTORY_WEIGHT` (0.9, about ten frames) times the confidence times the
  pixel's roughness over `RT_REFLECTION_HISTORY_ROUGHNESS` (0.25), at most 1. The factor ends where the blur starts,
  so mirror-like pixels keep no history and never show a trail.
- **Clamp.** Before blending, the history radiance is clamped in YCoCg to the mean of the current frame's traced 3 x 3
  neighbourhood plus or minus `RT_REFLECTION_CLAMP_SIGMA` (1) standard deviations. Untraced neighbours are left out.
  The clamp bounds how far an old reflection can stay from what the neighbourhood shows now.
- **Pre-exposure.** The history radiance is scaled by the ratio of the current pre-exposure factor to the factor
  recorded with the history slot it came from.
- **Untraced pixels.** A pixel the current frame did not trace, or whose roughness is above `max_reflection_roughness`
  (which the half-resolution reconstruction can fill), writes alpha 0 and no radiance, whatever its history.

## Forward views

A forward view has no G-buffer, so its depth prepass writes a thin one, `reflection_gbuffer`: one
`RGBA16_FLOAT` image at the working extent, 8 bytes per pixel (16.6 MB at 1080p), allocated with the view
while `reflections` is set on a `FORWARD` view and resized and retired with the reflection images. It
holds the octahedral normal in `rg` (the deferred packing), the roughness in `b` and the specular weight in
`a`, and is cleared to zero each frame, so an unwritten pixel has zero specular weight and the trace skips
it. The trace and blur are the deferred ones, with the thin image bound as both the normal-and-roughness
and the specular-weight input. `reflections` forces the depth prepass on whatever `depth_prepass` says.

- **Eligible draws** are the opaque Standard draws and the opaque Physical draws that the deferred
  G-buffer encodes (no clearcoat, sheen, anisotropy, transmission or specular overrides), `OPAQUE` or
  `MASK`. They draw in the prepass with the full vertex stage and a fragment form that samples what the
  forward stage does for the normal (normal map and decals), the roughness and the specular weight, and
  discards `MASK` coverage as it does. The Physical form takes the specular weight the Physical G-buffer
  stage writes.
- **Other draws** are `Basic`, `Toon`, `Custom`, Physical outside the encodable set, impostors and
  billboards. Every prepass pipeline carries the thin image's format, and these draws bind it with
  the colour write mask zero, so they write depth and nothing else. A pixel they cover keeps zero
  specular weight, is never traced, and its fragment does not read the reflection image.
- **Hidden surfaces.** An eligible surface behind a nearer ineligible one leaves its normal and
  roughness in the thin image, so the trace spends one ray on a pixel nothing reads.
- **Shading.** Eligible Standard and Physical draws fetch the blurred image at their pixel under
  `FRAME_REFLECTIONS_PRESENT` and the draw's `DRAW_TRACED_REFLECTION` bit, and blend it into their
  specular with the deferred resolve's weight and fade, from one shared function. Transparent
  and scene-reading draws, and draws of the other kinds, read nothing and shade as on a view without
  reflections, so `Custom` stays probe-only. The traced term replaces the prefiltered specular
  even in a scene with no lighting environment or probes, as in the deferred resolve.
- **Order.** `DEPTH_PREPASS`, then `AMBIENT_OCCLUSION` and screen-space GI when enabled, then
  `RT_REFLECTIONS`, then `FORWARD_OPAQUE`. `prepare_scene` and model preparation create the thin
  image's pipelines for each live forward view with traced reflections.

## Reflection lights

The pass packs its own light list each frame, apart from the view's. It holds every light eligible for
the camera's `layers`, so a finite light outside the camera frustum still lights a reflected surface.
Lights keep the view's budget order and stop at `RendererDesc.max_lights`. The list lives in the frame's
upload ring, together with its own [spatial lookup](many_lights.md#spatial-light-lookup).
The lookup uses the hit position and preserves the list's original indices and complete
finite/global membership.

A light skips a hit whose node `layers` do not intersect `Light.layers`, before its shadow ray, as in
raster. Ambient and emission do not use the mask. Every light with shadows enabled casts a shadow ray at
a hit, whether it uses a shadow atlas or ray-traced shadows in raster; the atlas is not read.

## Lighting

The lighting resolve (and, on a forward view, the Standard and Physical fragment stages) uses the traced radiance in place of the prefiltered environment
reflection, which includes the specular of [reflection probes](reflection_probes.md), and weights it with the same split-sum term, so a surface's reflection is counted
once. Near the threshold the two blend over the top fifth of `max_reflection_roughness`
(`RT_REFLECTION_FADE`), which hides the seam between traced and environment reflections. The
traced term carries its own occlusion, so it skips the ambient occlusion specular term the
environment reflection receives. Diffuse light, emission and direct light are unchanged.

Without a lighting environment the environment reflection is zero, and the traced reflection is
the only reflection of indirect light; the renderer builds the split-sum table for it anyway.

## Passes and inspection

`Pass.RT_REFLECTIONS` runs after `AMBIENT_OCCLUSION` and before `LIGHTING` (before `FORWARD_OPAQUE` on a
forward view): the trace and the blur, two compute dispatches, the reconstruction between them at `HALF` and the
temporal pass before the blur with `reflection_history`.
`render_view` prepares the scene trace and the split-sum table itself.
`gui::targets_panel` lists `reflection_blur` and `reflection`; programmatically
`PreviewKind.VIEW_REFLECTION` previews `reflection_blur` at level 0 and `reflection` at level 1.
The post panel's "Ray tracing" header toggles reflections on a deferred view and sets the
threshold, the rays per pixel, half resolution and the history.

`examples/rt_effects` shows a mirror floor reflecting an emissive panel above the view, a chalk
sphere above the view lit by a warm lamp outside the camera frustum and not by a cold lamp whose
`layers` exclude the sphere, a row of metal spheres from roughness 0 to 1, and in front of them a
clearcoated red sphere, a high-IOR tinted-specular dielectric, a transmissive glass sphere, a sheen
fabric sphere and a brushed anisotropic metal sphere, each seen beside its own reflection. `R` toggles
reflections, `S` switches the view between deferred and forward shading, `F` toggles a height fog over the reflected
paths, `[` and `]` move the threshold, `1` to `4` set the rays per pixel, `H` toggles half resolution, `T` toggles the
history, `A` cycles ambient occlusion; `--reflection-rays N`, `--reflection-resolution full|half` and
`--reflection-history` set the rays, the resolution and the history at start; `--gpu-timings --benchmark N` prints the mean pass times. The
rendering benchmarks take `--reflections on|off` on a deferred view ([benchmarking](benchmarking.md))
and report `gpu_rt_reflections_ms`.

```bash
python3 scripts/build.py --example rt_effects
```

## Limits

- Forward views trace Standard and plain Physical draws only; other draws keep the environment reflection and
  the reflection probes.
- Up to `RT_REFLECTION_RAYS_MAX` rays per traced pixel and a spatial blur. Temporal accumulation is opt-in
  through `reflection_history`, which reprojects by the surface's motion: the reflected content of a moving object or
  a changing light is not tracked, so its old image fades over the history's length, held to the current
  neighbourhood by the clamp, and mirror-like pixels keep no history.
- `HALF` rebuilds untraced pixels from compatible neighbours only; a pixel at a depth, normal, roughness or
  specular-weight edge with none keeps the prefiltered specular.
- Hits see the traced scene: skinned and morphed meshes appear at their raster pose; crowd placements appear only through `add_crowd(trace: true)`; custom vertex stages and `BLEND` meshes are absent.
- Every hit evaluates its spatial candidates and globals with a shadow ray per shadowing
  light in reach, so hit cost grows with the light count.
- Hit shading evaluates the Standard lobes and, for Physical, specular and IOR, clearcoat, sheen, anisotropy and the transmission fallback; normal maps apply at hits.
