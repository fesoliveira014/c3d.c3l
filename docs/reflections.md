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

- `UNSUPPORTED` when `reflections` is set on a `FORWARD` view or on a renderer created without
  `RendererDesc.ray_queries`. There is no software fallback.
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

- **Hit.** The hit surface is shaded from its material: `STANDARD` and `PHYSICAL` with the
  Standard BRDF (a Physical hit loses clearcoat, sheen and transmission), `BASIC` unlit, `TOON`
  with its bands and rim, `CUSTOM` as a grey Lambert surface, since custom shader code cannot run
  at a hit. Direct light comes from the view's lights; a light that casts shadows in raster casts
  them at the hit through a shadow ray. Emission, the ambient fill and the lighting environment
  add to it. Textures sample at a level of detail from the ray's cone footprint (ray cones,
  Akenine-Möller et al. 2019); normal and occlusion maps are not read at hits.
- **Back face.** A hit on the back of a single-sided surface is black; double-sided materials
  shade both sides.
- **Miss.** A ray that leaves the scene reads the lighting environment at its sharpest level
  (`scene.environment`, not the background), or the ambient colour without an environment.

A spatial blur then averages each traced pixel with neighbours of similar depth, normal and
roughness over a 5x5 footprint that widens with roughness; mirror-like pixels are not blurred.

## Lighting

The lighting resolve uses the traced radiance in place of the prefiltered environment
reflection and weights it with the same split-sum term, so a surface's reflection is counted
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

`examples/rt_effects` shows a mirror floor reflecting an emissive panel above the view and a row
of metal spheres from roughness 0 to 1. `R` toggles reflections, `[` and `]` move the threshold,
`A` cycles ambient occlusion; `--gpu-timings --benchmark N` prints the mean pass times. The
rendering benchmarks take `--reflections on|off` on a deferred view ([benchmarking](benchmarking.md))
and report `gpu_rt_reflections_ms`.

```bash
python3 scripts/build.py --example rt_effects
```

## Limits

- Deferred views only.
- One ray per pixel and a spatial blur; no temporal accumulation beyond what TAA provides.
- Hits see the static traced scene: skinned, morphed and `BLEND` meshes are absent.
- Hits use the view's light list, which drops finite lights outside the camera frustum, and
  apply no light layers. Every hit loops the whole list (no clustering) with a shadow ray per
  shadowing light in reach, so hit cost grows with the light count.
- Hit shading evaluates the Standard lobes only, without normal maps.
- The back of a single-sided surface reflects black.
