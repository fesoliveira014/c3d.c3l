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
| `kind` | `NONE`, `SSAO` (screen space) or `RAY_TRACED` (reserved; faults `UNSUPPORTED`) |
| `radius` | Search distance in world units; finite and above zero for `SSAO` |
| `intensity` | 0 leaves light unchanged, 1 applies the full estimate; finite and not negative |
| `full_resolution` | Estimate at the working extent instead of half of it |

`AMBIENT_OCCLUSION_DEFAULT` is `SSAO` at half resolution with a 0.5 m radius and intensity 1.
`create_view` and `configure_view` fault `INVALID_ARGUMENT` for settings outside these ranges;
`NONE` accepts any field values.

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

A forward view with AO draws its opaque set into depth first (the depth prepass deferred views
already run) and then shades it with depth `EQUAL` and no depth write: one more geometry pass.
A deferred view adds no geometry pass.

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

## Inspecting

`gui::targets_panel` lists `ao` and `ao_raw` while the view has them. Programmatically,
`PreviewKind.VIEW_AMBIENT_OCCLUSION` previews `ao` at level 0 and `ao_raw` at level 1, white
where unoccluded. `examples/ambient_occlusion` renders Sponza on a forward and a deferred view
side by side; `O` toggles AO and `--gpu-timings` shows the pass cost.

## Limits

- Screen space only: occluders outside the view or hidden behind nearer surfaces are absent.
- Thin objects occlude as if they were solid to the depth behind them.
- `LINEAR_HDR` views apply AO as part of lighting, so captures include it.
