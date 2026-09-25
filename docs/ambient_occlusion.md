# Ambient occlusion

A view can darken indirect light where nearby geometry blocks it. The setting is
`ViewDesc.ambient_occlusion`, an `AmbientOcclusionDesc`; a zeroed value is off.

```c3
ViewDesc desc = render::default_view_desc();
desc.ambient_occlusion = render::AMBIENT_OCCLUSION_DEFAULT;
render::configure_view(&renderer, renderer.default_view, desc)!;
```

| Field | Meaning |
| --- | --- |
| `kind` | `NONE`, `SSAO` (screen space) or `RAY_TRACED` (see [Ray traced](#ray-traced)) |
| `radius` | Search distance in world units; finite and above zero |
| `intensity` | 0 leaves light unchanged, 1 applies the full estimate; finite and not negative |
| `full_resolution` | Estimate at the working extent instead of half of it |
| `ray_count` | Rays per estimate texel for `RAY_TRACED`, `RT_AO_RAYS_MIN` (1) to `RT_AO_RAYS_MAX` (16); `SSAO` ignores it |

`AMBIENT_OCCLUSION_DEFAULT` is `SSAO` at half resolution with a 0.5 m radius, intensity 1 and
4 rays for when the kind is switched to `RAY_TRACED`. `create_view` and `configure_view` fault
`INVALID_ARGUMENT` for settings outside these ranges; `NONE` accepts any field values.

## What it darkens

AO multiplies indirect light only:

- the environment's diffuse (SH) term and the flat ambient fill, combined with a material's
  occlusion map by `min(material occlusion, ambient occlusion)` so a baked map and the screen
  estimate do not darken the same crease twice;
- every environment reflection lobe (base, clearcoat, sheen) through specular occlusion
  (Lagarde 2014), which uses the screen estimate only; a material occlusion map keeps affecting
  diffuse light alone.

Direct light, emission and light transmitted through a Physical material are never darkened.

Opaque and masked surfaces receive AO on both shading paths. Transparent (`BLEND`) and
transmissive surfaces do not: the estimate describes the opaque surface behind them.

## Cost and passes

AO needs the complete opaque depth before lighting, so a forward view with AO runs the depth
prepass even when `ViewDesc.depth_prepass` is off, and shades opaque with depth `EQUAL` and no
depth write. A deferred view already runs the prepass; AO adds no geometry pass on either path.

The pass (`Pass.AMBIENT_OCCLUSION`) runs two compute dispatches between the depth producer and
lighting:

1. The estimate: GTAO (Jimenez et al. 2016), two slice directions per texel with four steps on
   each side, writing `ao_raw` at half or full resolution. Deferred views read the G-buffer
   normal; forward views reconstruct the normal from depth.
2. A depth-aware blur that also upsamples: every pixel of the working extent weights a 4x4
   neighbourhood of `ao_raw` by a tent and by depth similarity, writing `ao`. Surfaces never pick
   up AO across a silhouette, and consumers read one `ao` texel per pixel.

The rotation of the slice directions follows interleaved gradient noise. It changes per frame
only on a TAA view, where TAA integrates it; without TAA a still camera shows a fixed pattern.

## Ray traced

`RAY_TRACED` replaces the screen-space estimate with rays against the traced static scene
([scene tracing](scene_trace.md)); everything after the estimate is shared.

```c3
Renderer renderer = render::create_renderer(mem, &assets, { .ray_queries = true })!;
ViewDesc desc = render::default_view_desc();
desc.ambient_occlusion = render::AMBIENT_OCCLUSION_DEFAULT;
desc.ambient_occlusion.kind = AoKind.RAY_TRACED;
render::configure_view(&renderer, renderer.default_view, desc)!;
```

- It needs `RendererDesc.ray_queries`; without it `create_view` and `configure_view` fault
  `UNSUPPORTED`. There is no software fallback.
- Every estimate texel casts `ray_count` cosine-weighted rays over the hemisphere of its normal
  (G-buffer on deferred views, reconstructed from depth on forward views), each up to `radius`.
  A ray's nearest hit counts with the same distance falloff as the screen-space estimate: fully
  within 0.4 `radius`, fading to nothing at `radius`. The result lands in the same `ao_raw`
  image, so the blur, the receivers and everything under [What it darkens](#what-it-darkens)
  are unchanged.
- The rays find occluders the screen cannot see: off-screen geometry and surfaces hidden behind
  nearer ones. Only the traced scene occludes: skinned, morphed and `BLEND` meshes do not.
- The ray directions rotate per pixel with interleaved gradient noise, per frame only on a TAA
  view. More rays cost proportionally more: 16 rays at half resolution trace 8.3 M rays a
  frame at 1080p.
- The pass is still `Pass.AMBIENT_OCCLUSION`. The scene trace is prepared by `render_view`
  automatically.

`examples/rt_effects` cycles `NONE`, `SSAO` and `RAY_TRACED` with `A`.

## Inspecting

`gui::targets_panel` lists `ao` and `ao_raw` while the view has them. Programmatically,
`PreviewKind.VIEW_AMBIENT_OCCLUSION` previews `ao` at level 0 and `ao_raw` at level 1, white
where unoccluded. `examples/ambient_occlusion` renders Sponza on a forward and a deferred view
side by side; `O` toggles AO and `--gpu-timings` shows the pass cost.
It needs the benchmark assets (`python3 scripts/fetch_benchmark_assets.py`):

```bash
python3 scripts/build.py --example ambient_occlusion
```

The rendering benchmarks take `--ambient-occlusion none|half|full|ray-traced`
([benchmarking](benchmarking.md)) and report the pass as `gpu_ambient_occlusion_ms`.

## Limits

- `SSAO` is screen space only: occluders outside the view or hidden behind nearer surfaces are
  absent. `RAY_TRACED` sees them, for the static traced scene.
- With `SSAO`, thin objects occlude as if they were solid to the depth behind them.
- `LINEAR_HDR` views apply AO as part of lighting, so captures include it.
