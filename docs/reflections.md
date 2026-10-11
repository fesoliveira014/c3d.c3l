# Ray-traced reflections

A deferred view can replace the environment reflection of smooth surfaces with reflections traced
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

`default_view_desc` and `texture_view_desc` set `max_reflection_roughness` to
`RT_REFLECTION_ROUGHNESS_DEFAULT` (0.5). `create_view` and `configure_view` fault:

- `UNSUPPORTED` when `reflections` is set on a `FORWARD` view. On a renderer created without
  `RendererDesc.ray_queries` the reflection rays run on the software walk
  ([scene tracing](scene_trace.md)). On an RTX 4090 (Sponza, 2160p) they cost about 12 times the
  ray-query rays: 5.4 ms against 0.45 ms.
- `INVALID_ARGUMENT` when `reflections` is set and `max_reflection_roughness` is not finite or
  lies outside `(0, 1]`.

The view allocates two `RGBA16_FLOAT` images at its working extent, `reflection` and
`reflection_blur`, while `reflections` is set, and retires them when it is cleared.

## What traces

Reflections read the deferred G-buffer, so they apply to the view's G-buffer surfaces: Standard
materials and Physical materials without clearcoat, sheen, anisotropy, transmission or specular
overrides. Materials the G-buffer cannot encode keep their forward shading and the environment
reflection. A pixel traces when it has geometry, a specular weight above zero and a roughness at
or below `max_reflection_roughness`.

Each such pixel casts one ray, sampled from the GGX distribution of visible normals (Dupuy and
Benyoub 2023) around the G-buffer normal. The sample rotates with interleaved gradient noise,
per frame only on a TAA view, where TAA averages it; without TAA a still camera shows a fixed
grain on rougher surfaces.

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
  not seen. The sheen layer attenuates the direct and environment base lobes of a hit, but not its
  constant ambient fill, which the forward stage also scales.
- **Sheen tables.** Sheen at a hit reads the sheen albedo table and the sheen environment the view
  carries. A reflection view carries them once the renderer has resolved a sheen material, which
  `prepare_scene` does ahead of the first frame; a sheen surface that only a reflection shows, in a
  scene nothing prepared, shades without its sheen lobe on the frame that first resolves it.
- **Back face.** A reflection ray passes the back of a single-sided surface, as raster culls it,
  and reflects what lies behind; double-sided materials shade both sides
  ([facing](scene_trace.md#facing)).
- **Miss.** A ray that leaves the scene reads the lighting environment at its sharpest level
  (`scene.environment`, not the background), or the ambient colour without an environment. A miss
  never reads a reflection probe: indoor misses happen only through openings or excluded geometry
  (`RT_REFLECTION_FAR` is 1e4), and a ray through excluded geometry reads the global environment.

A spatial blur then averages each traced pixel with neighbours of similar depth, normal and
roughness over a 5x5 footprint that widens with roughness; mirror-like pixels are not blurred.

Traced reflections ignore a view's clip plane: they trace the whole scene. A planar mirror is a
clipped view of its own (see [clip plane](views.md#clip-plane)).

## Reflection lights

The pass packs its own light list each frame, apart from the view's. It holds every light eligible for
the camera's `layers`, so a finite light outside the camera frustum still lights a reflected surface.
Lights keep the view's budget order and stop at `RendererDesc.max_lights`. The list lives in the frame's
upload ring.

A light skips a hit whose node `layers` do not intersect `Light.layers`, before its shadow ray, as in
raster. Ambient and emission do not use the mask. Every light with shadows enabled casts a shadow ray at
a hit, whether it uses a shadow atlas or ray-traced shadows in raster; the atlas is not read.

## Lighting

The lighting resolve uses the traced radiance in place of the prefiltered environment
reflection, which includes the specular of [reflection probes](reflection_probes.md), and weights it with the same split-sum term, so a surface's reflection is counted
once. Near the threshold the two blend over the top fifth of `max_reflection_roughness`
(`RT_REFLECTION_FADE`), which hides the seam between traced and environment reflections. The
traced term carries its own occlusion, so it skips the ambient occlusion specular term the
environment reflection receives. Diffuse light, emission and direct light are unchanged.

Without a lighting environment the environment reflection is zero, and the traced reflection is
the only reflection of indirect light; the renderer builds the split-sum table for it anyway.

## Passes and inspection

`Pass.RT_REFLECTIONS` runs after `AMBIENT_OCCLUSION` and before `LIGHTING`: the trace and the blur,
two compute dispatches. `render_view` prepares the scene trace and the split-sum table itself.
`gui::targets_panel` lists `reflection_blur` and `reflection`; programmatically
`PreviewKind.VIEW_REFLECTION` previews `reflection_blur` at level 0 and `reflection` at level 1.
The post panel's "Ray tracing" header toggles reflections on a deferred view and sets the
threshold.

`examples/rt_effects` shows a mirror floor reflecting an emissive panel above the view, a chalk
sphere above the view lit by a warm lamp outside the camera frustum and not by a cold lamp whose
`layers` exclude the sphere, a row of metal spheres from roughness 0 to 1, and in front of them a
clearcoated red sphere, a high-IOR tinted-specular dielectric, a transmissive glass sphere, a sheen
fabric sphere and a brushed anisotropic metal sphere, each seen beside its own reflection. `R` toggles
reflections, `[` and `]` move the threshold, `A` cycles ambient occlusion; `--gpu-timings --benchmark N` prints the mean pass times. The
rendering benchmarks take `--reflections on|off` on a deferred view ([benchmarking](benchmarking.md))
and report `gpu_rt_reflections_ms`.

```bash
python3 scripts/build.py --example rt_effects
```

## Limits

- Deferred views only; forward views always apply reflection probes.
- One ray per pixel and a spatial blur; no temporal accumulation beyond what TAA provides.
- Hits see the traced scene: skinned and morphed meshes appear at their raster pose; crowd placements appear only through `add_crowd(trace: true)`; custom vertex stages and `BLEND` meshes are absent.
- Every hit loops the whole reflection light list (no clustering) with a shadow ray per shadowing
  light in reach, so hit cost grows with the light count.
- Hit shading evaluates the Standard lobes and, for Physical, specular and IOR, clearcoat, sheen, anisotropy and the transmission fallback; normal maps apply at hits.
