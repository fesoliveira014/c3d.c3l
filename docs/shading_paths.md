# Shading paths

`ViewDesc.shading` chooses how a view shades its opaque surfaces: `FORWARD` shades each fragment in the material's own
stage, `DEFERRED` writes a G-buffer and lights it in one fullscreen resolve, and `PATH_TRACED` replaces rasterised
shading with a path tracer ([path tracing](path_tracing.md)). The setting belongs to the view (`c3d::render`); see
[views](views.md). Light selection (`lights`) is independent of the path: see [lights](lights.md).

## Quick start

```c3
ViewDesc desc = render::default_view_desc();
desc.shading = ShadingPath.DEFERRED;
render::configure_view(&renderer, renderer.default_view, desc)!;
```

Both view constructors choose `FORWARD`. Run `python3 scripts/build.py --example deferred` to see one scene forward on
the left and deferred on the right, or `--example shading_paths` for all four `ShadingPath` and `LightSelection`
combinations in a 2x2 grid.

## Concepts

- **Forward.** Every material shades in its own fragment stage. A `FORWARD` view allocates no G-buffer image.
- **Deferred.** The view's encodable opaque materials write a G-buffer, and one lighting resolve lights every
  G-buffer pixel from the frame data. Every other material keeps its forward pass on the same view, drawn after the
  resolve with depth `EQUAL` and no depth write. A Toon material draws its [outline](materials.md#toon-outline) in
  that pass.
- **Routing.** No material field selects the path. A material draws into the G-buffer when
  `render::gbuffer_encodable` accepts it, and only on a `DEFERRED` view; a `FORWARD` view ignores the rule.

## Forward views

A `FORWARD` view with `depth_prepass` (on in both constructors) runs, in order:

1. `DEPTH_PREPASS` over its opaque set. With ray-traced reflections it also writes the thin reflection surface, and
   with ray-traced ambient occlusion the [proxy skip word](scene_trace.md#trace-proxies).
2. `AMBIENT_OCCLUSION`, screen-space GI and [`RT_REFLECTIONS`](reflections.md#forward-views), when enabled.
3. `FORWARD_OPAQUE` with depth `EQUAL` and no depth write, so every opaque pixel shades once. Standard and Physical
   fragments read the blurred reflection image. Transparent and scene-reading draws do not.

Without a prepass, `FORWARD_OPAQUE` writes depth itself and shades every fragment that passes the depth test when it
is drawn. Ambient occlusion, screen-space GI and ray-traced reflections force the prepass on. The prepass costs one
more geometry pass with depth-only shaders and pays off wherever opaque overdraw would shade a pixel more than once.

## Deferred views

A `DEFERRED` view always runs the depth prepass and ignores `depth_prepass`. Its order is `DEPTH_PREPASS`, `GBUFFER`
(depth `EQUAL`, no write), `AMBIENT_OCCLUSION`, screen-space GI and `RT_REFLECTIONS` when enabled, `LIGHTING`, then
`FORWARD_OPAQUE` for the forward remainder and the sky.

### Routing rule

`render::gbuffer_encodable` decides, and `render::view_draw_list` applies it where the draw lists are split. A draw
writes the G-buffer when its alpha mode is `OPAQUE` or `MASK` and its material is:

- `STANDARD`;
- `PHYSICAL` with zero clearcoat, sheen, anisotropy and transmission, `ior == 1.5`, a white `specular_color` and no
  `specular_color_map` (the specular weight and its map are encoded);
- `CUSTOM` whose `ShaderDesc` has a `gbuffer` stage ([custom shaders](custom_shaders.md#g-buffer-stage)).

`BASIC`, `TOON`, a `CUSTOM` shader without a `gbuffer` stage, every other `PHYSICAL` value, `BLEND` and transmissive
draws stay forward. A Physical dielectric F0 in the resolve is `0.04 * specular` for IOR 1.5, which is why other IORs
and tinted specular colors route forward.

### G-buffer images

The view owns five images at its working extent, allocated by `create_view` or `configure_view` and retired when the
view returns to `FORWARD`. Together they take 28 bytes per working pixel.

| Channel | Format | Contents |
| --- | --- | --- |
| `BASE_COLOR_METALLIC` | `RGBA8_UNORM` | base color, metallic |
| `NORMAL_ROUGHNESS` | `RGBA16_FLOAT` | octahedral normal, roughness, occlusion |
| `EMISSIVE_SPECULAR` | `RGBA16_FLOAT` | emissive, specular weight |
| `LAYERS` | `R32_UINT` | receiver layer mask |
| `FLAGS` | `R32_UINT` | receive-shadow bit; the [proxy skip height](scene_trace.md#trace-proxies) in centimetres in bits 16 to 31 |

### Resolve

- **Light selection.** The resolve calls the same flat or clustered selection as the forward shaders, so `DEFERRED`
  with `CLUSTERED` needs no further configuration. See [lights](lights.md).
- **Shadows.** The resolve reads shadows through the view's [shadow set](shadows.md#shadow-sets), including
  [colored shadows](shadows.md#colored-shadows) and traced shadows. It offsets shadow lookups along a face normal
  rebuilt from depth; see [normal offset](shadows.md#normal-offset).
- **Decals.** Standard and Physical receivers apply decals to their material sample before `write_gbuffer`, and the
  resolve does not apply them again ([decals](decals.md)).
- **Effects.** Ambient occlusion, screen-space GI and traced reflections on a deferred view read the G-buffer's normal
  channel, and traced reflections its specular weight. Ray-traced ambient occlusion and traced reflections also read
  the flags channel for the proxy skip height. Under [MSAA](msaa.md) they read the sample-0 copies.
- **Post.** Motion blur, depth of field, bloom, grading and FXAA read `hdr_color`, depth and velocity only and run the
  same on both paths.

### Custom materials

A `ShaderDesc` with a `gbuffer` stage routes like `STANDARD` on a deferred view; one without stays forward. A shader
that declares scene reads has no `gbuffer` stage. See [custom shaders](custom_shaders.md#g-buffer-stage).

## Choose a path

- Deferred pays off on scenes with heavy opaque overdraw or many lights.
- Deferred charges a G-buffer round trip on every pixel. On a low-overdraw scene it can cost more than forward with a
  prepass.
- Materials that cannot encode (Basic, Toon, blended, most Physical) still shade forward on a deferred view.
- Deferred needs sample-rate shading to combine with `msaa` above `ONE`.

Compare the two paths on your scene with the completed `FORWARD_OPAQUE`, `GBUFFER` and `LIGHTING` pass times; see
[profiling](profiling.md#capture-gpu-work) and [benchmarking](benchmarking.md#headless-many-light-rendering).

## Limits

- `PATH_TRACED` rejects raster-only view settings (see [views reference](views_reference.md#faults)).
- Ray-traced reflections on a `PATH_TRACED` view fault `c3d::UNSUPPORTED`.
- The G-buffer does not encode clearcoat, sheen, anisotropy, transmission or a non-default IOR.

## See also

- [Views](views.md) and [views reference](views_reference.md).
- [Multisample anti-aliasing](msaa.md) for deferred sample-rate lighting.
- [Lights](lights.md), [shadows](shadows.md), [ambient occlusion](ambient_occlusion.md) and
  [reflections](reflections.md).
- [Custom shaders](custom_shaders.md#g-buffer-stage) for the `gbuffer` stage.
