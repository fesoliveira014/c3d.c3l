# Ray-traced reflections

A deferred or forward view can replace the environment reflection of smooth surfaces with reflections traced against the
scene, so a mirror floor shows the objects around it, including ones outside the view. The settings are
`ViewDesc.ray_tracing`, a `RayTracingDesc`, in `c3d::render`. A renderer without `RendererDesc.ray_queries` traces on the
software walk; see [software and hardware kinds](scene_trace.md#software-and-hardware-kinds).

## Quick start

```c3
Renderer renderer = render::create_renderer(mem, &assets, { .ray_queries = true })!;
ViewDesc desc = render::default_view_desc();
desc.shading = ShadingPath.DEFERRED;
desc.ray_tracing.reflections = true;
render::configure_view(&renderer, renderer.default_view, desc)!;
```

## Concepts

### What traces

Reflections read the G-buffer, so they apply to surfaces the G-buffer encodes: Standard materials and Physical materials
without clearcoat, sheen, anisotropy, transmission or specular overrides. Materials the G-buffer cannot encode keep their
forward shading and the environment reflection. A pixel traces when it has geometry, a specular weight above zero and a
roughness at or below `max_reflection_roughness`.

- On a deferred view with one sample per pixel, a ray also ignores the hits on [trace proxies](scene_trace.md#trace-proxies)
  that its pixel's G-buffer flags name.
- A hit sees what the scene trace contains; see [what traces](scene_trace.md#what-traces).
- Traced reflections ignore a view's clip plane and trace the whole scene. A planar mirror is a clipped view of its own; see
  [planar reflections](views.md#planar-reflections).

### Rays and blur

Each traced pixel casts `reflection_rays` rays, sampled from the GGX distribution of visible normals (Dupuy and Benyoub
2023) around the G-buffer normal, and averages their radiance. The sample rotates with interleaved gradient noise, per
frame on a TAA view and on a view with [history](#history), where the accumulation averages it. Otherwise a still camera
shows a fixed grain on rougher surfaces, which more rays reduce.

A spatial blur then averages each traced pixel with neighbors of similar depth, normal, roughness and specular weight. The
footprint widens with roughness, and mirror-like pixels are not blurred. The blur and the half-resolution reconstruction
skip a neighbor whose roughness differs by more than 0.1 or whose specular weight differs by more than
`RT_REFLECTION_SPECULAR_TOLERANCE` (0.1), so a reflection does not smear across a material edge. A pixel beside an edge
averages fewer neighbors and shows more grain.

### Hit shading

A ray hit is shaded from its material. Custom shader code cannot run at a hit.

| Material at the hit | Shading |
| --- | --- |
| `STANDARD` | The Standard BRDF |
| `PHYSICAL` | The forward Physical stage's lobes: specular, IOR, clearcoat, sheen, anisotropy and transmission |
| `BASIC` | Unlit |
| `TOON` | Its bands and rim, as the forward Toon stage evaluates them |
| `CUSTOM` | Constant grey albedo under Lambert lighting |

- Direct light comes from the [reflection light list](#reflection-lights); a light that casts shadows casts them at the hit
  through a shadow ray. Emission, the ambient fill and the lighting environment add to it.
- Textures sample at a level of detail from the ray's cone footprint. Normal maps are read at hits; occlusion maps are not.
- A Physical hit reads the same maps as the forward stage. The anisotropy frame comes from the vertex tangent stream when
  the geometry has one, else from the hit triangle's positions and UVs.
- A hit has no scene snapshot. The transmitted part of a Physical hit reads the lighting environment and the reflection
  probes along the refracted direction, so the scene behind a glass hit and its fog are not seen.
- Sheen at a hit reads the sheen tables the view carries. `prepare_scene` resolves them before the first frame. A sheen
  surface that only a reflection shows, in a scene nothing prepared, shades without its sheen lobe on the frame that first
  resolves it.
- A hit takes the view's height fog and, behind it, the scene's atmosphere over the path from the reflecting surface to the
  hit. A miss takes the height fog to infinity. See [fog at hits](fog.md#where-fog-applies).
- A ray passes the back of a single-sided surface, as raster culls it, and reflects what lies behind. Double-sided materials
  shade both sides ([facing](scene_trace.md#facing)).
- A ray that leaves the scene reads the lighting environment at its sharpest level (`scene.environment`, not the
  background), or the ambient color without an environment. A miss never reads a reflection probe. Rays are
  `RT_REFLECTION_FAR` (1e4) world units long. Indoors, misses happen only through openings or excluded geometry, and a ray
  through excluded geometry reads the global environment.

### Lighting

The lighting resolve uses the traced radiance in place of the prefiltered environment reflection, which includes the
specular of [reflection probes](reflection_probes.md), and weights it with the same split-sum term, so a surface's
reflection is counted once. On a forward view the Standard and Physical fragment stages do the same. Near the threshold the
two blend over the top fifth of `max_reflection_roughness` (`RT_REFLECTION_FADE`), which hides the seam between traced and environment
reflections.

- The traced term carries its own occlusion, so it skips the ambient occlusion specular term the environment reflection
  receives. Diffuse light, emission and direct light are unchanged.
- Without a lighting environment the traced reflection is the only reflection of indirect light.

## Enable reflections

`ViewDesc.ray_tracing.reflections` enables the effect. `default_view_desc` and `texture_view_desc` set
`max_reflection_roughness` to `RT_REFLECTION_ROUGHNESS_DEFAULT` (0.5).

| Field | Meaning |
| --- | --- |
| `reflections` | Ray-traced reflections on this view |
| `max_reflection_roughness` | Surfaces rougher than this keep the environment reflection; in `(0, 1]` while `reflections` is set |
| `reflection_rays` | Rays per traced pixel, 1 to `RT_REFLECTION_RAYS_MAX` (4); zero reads as 1 |
| `reflection_resolution` | `FULL` traces every pixel; `HALF` traces one of each 2 x 2 block |
| `reflection_history` | Blends each traced pixel with the previous frames' reflection; off by default |

`create_view` and `configure_view` fault `UNSUPPORTED` when `reflections` is set on a `PATH_TRACED` view, and
`INVALID_ARGUMENT` when `reflections` is set and `max_reflection_roughness` is not finite or lies outside `(0, 1]`, or
`reflection_rays` is above `RT_REFLECTION_RAYS_MAX`. The last three fields are ignored while `reflections` is clear.

### Memory

The images exist while `reflections` is set and retire when it is cleared. The
[images per setting](views_reference.md#images-per-setting) table counts them.

| Setting | Bytes per working pixel |
| --- | --- |
| `reflections` (`reflection`, `reflection_blur`, `RGBA16_FLOAT`) | 16 |
| `HALF` (`reflection_half`, at the working extent halved) | +2 |
| `reflection_history` (two `RGBA16_FLOAT` history and two `R32_FLOAT` depth images) | +24 |
| `FORWARD` view (`reflection_gbuffer`) | +8 |

## Half resolution

With `reflection_resolution = HALF` the trace writes one texel per 2 x 2 block and spends a quarter of the rays. With TAA
the traced pixel of each block steps through four positions, so four frames cover each block; without TAA or
`reflection_history` it stays on one. A reconstruction pass fills the full-resolution image from the 2 x 2 texels around each
pixel, weighted by position and by the blur's depth and normal weights. A texel counts for nothing when it differs in
roughness or specular weight beyond the tolerances above, or traced nothing. A pixel with no compatible texel is untraced:
it keeps the prefiltered specular and shows no traced reflection.

## History

With `reflection_history` set, the view blends each traced pixel with the reflection the previous frames traced there. A
still camera averages the noise of many frames without TAA, and TAA receives a steadier input. The temporal pass runs after
the trace, and after the reconstruction at `HALF`, and before the blur.

- The view records its velocity before the reflections and commits a history for itself; see
  [velocity and history](anti_aliasing.md#velocity-and-history). The pass reads no history on the frame after
  `reset_view_history`, `configure_view`, a resize or a change of scene.
- The pass keeps about ten frames, scaled by a confidence from depth match, motion, material match (roughness and specular
  weight within the tolerances) and the traced share of the history. Mirror-like pixels keep no history and never show a
  trail.
- The history is clamped to the current frame's traced 3 x 3 neighborhood in YCoCg, which bounds how far an old reflection
  can stay from what the neighborhood shows now, and follows the ratio of pre-exposure factors.
- A pixel the current frame did not trace, or whose roughness is above `max_reflection_roughness`, writes alpha 0 and no
  radiance, whatever its history.

## Forward views

A forward view has no G-buffer, so its depth prepass writes a thin one, `reflection_gbuffer`: the octahedral normal in
`rg`, the roughness in `b` and the specular weight in `a`, cleared to zero each frame. An unwritten pixel has zero specular
weight and the trace skips it. The trace and blur are the deferred ones. `reflections` forces the depth prepass on
whatever `depth_prepass` says.

- **Eligible draws** are the opaque Standard draws and the opaque Physical draws the G-buffer encodes, `OPAQUE` or `MASK`.
  They write the thin image in the prepass.
- **Other draws** (Basic, Toon, Custom, Physical outside the encodable set, impostors and billboards) write depth only. A
  pixel they cover keeps zero specular weight and is never traced. An eligible surface behind a nearer ineligible one
  leaves its normal and roughness in the thin image, so the trace spends one ray on a pixel nothing reads.
- **Shading.** Eligible Standard and Physical draws blend the blurred image into their specular with the deferred resolve's
  weight and fade. Transparent and scene-reading draws and draws of the other kinds read nothing and shade as on a view
  without reflections, so `Custom` stays probe-only. The traced term replaces the prefiltered specular even in a scene with
  no lighting environment or probes.
- **Order.** `DEPTH_PREPASS`, then `AMBIENT_OCCLUSION` and screen-space GI when enabled, then `RT_REFLECTIONS`, then
  `FORWARD_OPAQUE`. `prepare_scene` and model preparation create the thin image's pipelines for each live forward view
  with traced reflections.

## Reflection lights

The pass packs its own light list each frame, apart from the view's. It holds every light eligible for the camera's
`layers`, so a finite light outside the camera frustum still lights a reflected surface. Lights keep the view's budget order
and stop at `RendererDesc.max_lights`. The list has its own [spatial lookup](lights.md#spatial-light-lookup), which uses the
hit position.

A light skips a hit whose node `layers` do not intersect `Light.layers`, before its shadow ray, as in raster; see the
[receiver mask](lights.md#concepts). Ambient and emission do not use the mask. Every light with shadows enabled casts a
shadow ray at a hit, whether it uses a shadow atlas or ray-traced shadows in raster. The atlas is not read.

## Inspect the effect

- `Pass.RT_REFLECTIONS` runs after `AMBIENT_OCCLUSION` and before `LIGHTING` (before `FORWARD_OPAQUE` on a forward view). The
  benchmarks report it as `gpu_rt_reflections_ms`. `render_view` prepares the scene trace and the split-sum table itself.
- `gui::targets_panel` lists `reflection_blur` and `reflection`. `PreviewKind.VIEW_REFLECTION` previews `reflection_blur` at
  level 0 and `reflection` at level 1.
- The post panel's "Ray tracing" header toggles reflections on a deferred view and sets the threshold, the rays per pixel,
  half resolution and the history.

Run `python3 scripts/build.py --example rt_effects` for a mirror floor, a roughness ramp and Physical material spheres
beside their reflections. It takes `--reflection-rays N`, `--reflection-resolution full|half`, `--reflection-history`, and
`--gpu-timings --benchmark N`. The rendering benchmarks take `--reflections on|off`; see
[benchmarking](benchmarking.md).

## Limits

- Forward views trace Standard and plain Physical draws only; other draws keep the environment reflection and the
  reflection probes.
- At most `RT_REFLECTION_RAYS_MAX` rays per traced pixel, and a spatial blur. Temporal accumulation reprojects by the
  surface's motion: the reflected content of a moving object or a changing light is not tracked, so its old image fades over
  the history's length.
- `HALF` rebuilds untraced pixels from compatible neighbors only. A pixel at a depth, normal, roughness or specular-weight
  edge with none keeps the prefiltered specular.
- Every hit evaluates its spatial candidates and globals with a shadow ray per shadowing light in reach, so hit cost grows
  with the light count.

## See also

- [Scene tracing](scene_trace.md) for what the trace contains and the two trace kinds.
- [Reflection probes](reflection_probes.md) and [environments](environments.md) for the non-traced reflection terms.
- [Lighting techniques](lighting_techniques.md) for choosing between effects.
- [Shading paths](shading_paths.md) for forward and deferred views.
- [Views reference](views_reference.md) for `RayTracingDesc` and view faults.
