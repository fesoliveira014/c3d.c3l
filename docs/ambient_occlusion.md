# Ambient occlusion

A view can darken indirect light where nearby geometry blocks it. The setting is `ViewDesc.ambient_occlusion`, an
`AmbientOcclusionDesc` in `c3d::render`. The estimate is screen space (`SSAO`) or traced against the scene
(`RAY_TRACED`), and both can accumulate over frames and store a bent normal. A zeroed value is off.

## Quick start

```c3
ViewDesc desc = render::default_view_desc();
desc.ambient_occlusion = render::AMBIENT_OCCLUSION_DEFAULT;
render::configure_view(&renderer, renderer.default_view, desc)!;
```

`AMBIENT_OCCLUSION_DEFAULT` is `SSAO` at half resolution with a 0.5 m radius, intensity 1, and 4 rays for when the kind is
switched to `RAY_TRACED`.

## Concepts

### Affected light

AO multiplies indirect light only:

- the environment's diffuse (SH) term and the flat ambient fill, combined with a material's occlusion map by
  `min(material occlusion, ambient occlusion)` so a baked map and the screen estimate do not darken the same crease twice;
- every environment reflection lobe (base, clearcoat, sheen) through specular occlusion (Lagarde 2014), which uses the
  screen estimate only. A material occlusion map keeps affecting diffuse light alone.

Direct light, emission and light transmitted through a Physical material are never darkened. Opaque and masked surfaces
receive AO on both shading paths. Transparent (`BLEND`) and transmissive surfaces do not: the estimate describes the opaque
surface behind them. `LINEAR_HDR` views apply AO as part of lighting, so captures include it.

### When it runs

AO needs the complete opaque depth before lighting. A forward view with AO runs the depth prepass even when
`ViewDesc.depth_prepass` is off, and shades opaque surfaces with depth `EQUAL` and no depth write. A deferred view already
runs the prepass. AO adds no geometry pass on either path.

`Pass.AMBIENT_OCCLUSION` runs between the depth producer and lighting:

1. The estimate: GTAO (Jimenez et al. 2016) for `SSAO`, written at half or full resolution into `ao_raw`. Deferred views
   read the G-buffer normal; forward views rebuild it from depth by the rule of the deferred
   [normal offset](shadows.md#normal-offset).
2. With `temporal`, the accumulation between the estimate and the blur.
3. A depth-aware blur that also upsamples to the working extent into `ao`. Surfaces never pick up AO across a silhouette.

The slice rotation changes per frame on a TAA view and on a view with `temporal`, where the accumulation averages it.
Otherwise a still camera shows a fixed pattern.

## Enable SSAO

| Field | Meaning |
| --- | --- |
| `kind` | `NONE`, `SSAO` (screen space) or `RAY_TRACED` (see [ray-traced AO](#ray-traced)) |
| `radius` | Search distance in world units; finite and above zero |
| `intensity` | 0 leaves light unchanged, 1 applies the full estimate; finite and not negative |
| `full_resolution` | Estimate at the working extent instead of half of it |
| `ray_count` | Rays per estimate texel for `RAY_TRACED`, `RT_AO_RAYS_MIN` (1) to `RT_AO_RAYS_MAX` (16); `SSAO` ignores it |
| `temporal` | Accumulates the estimate over frames, whether or not the view uses TAA; off by default; applies to `SSAO` and `RAY_TRACED` |
| `bent_normals` | Also estimates the average unoccluded direction and lights the diffuse ambient term along it; off by default; applies to `SSAO` and `RAY_TRACED` |

`create_view` and `configure_view` fault `INVALID_ARGUMENT` for settings outside these ranges. `NONE` accepts any field
values.

## Temporal

`temporal` blends each frame's estimate with the previous frame's accumulated estimate, so the noise of the rotating pattern
averages out over about ten frames. It does not need TAA. It adds one dispatch, between the estimate and the blur, under
`Pass.AMBIENT_OCCLUSION`.

- The history is fetched bilinearly at the position the view's velocity image gives for the previous frame. It is kept only
  where the surface seen now was there last frame (the stored depth matches within 5 %), and it fades out as the motion
  grows from 2 to 4 full-resolution pixels a frame, as [screen-space GI](screen_space_gi.md) does. Where the history is
  kept, the result is 0.9 history and 0.1 new estimate. A pixel whose velocity carries the rejection flag takes the new
  estimate alone.
- With no history to reproject the estimate is written as it is: the first rendering, the first rendering of a scene, and
  any rendering after `reset_view_history`, `configure_view` or a resize. Call `reset_view_history` on a camera cut.
- AO is visibility, not radiance, so the history is not scaled by the view's [pre-exposure](post.md#pre-exposure).
- The view records its velocity before ambient occlusion; see [velocity and history](anti_aliasing.md#velocity-and-history)
  for the format and the cost on a view without TAA or motion blur.
- The view keeps two history images (`R16_FLOAT`, or `RGBA16_FLOAT` with `bent_normals`) and two depth images (`R32_FLOAT`)
  at the estimate's extent. They are dropped when `temporal` is cleared, the kind is `NONE`, or `full_resolution` or
  `bent_normals` changes.

## Bent normals

`bent_normals` stores, beside each pixel's visibility, the average direction the surface sees unoccluded: the world-space
bent normal. The diffuse environment term reads its irradiance along that direction instead of along the surface normal, so
a crease takes its light from the open side. It applies to `SSAO` and `RAY_TRACED`, with or without `temporal`.

- `ao_raw` and `ao` become `RGBA8_UNORM`, four times the memory. Red holds the visibility, so readers of `.r` see what they
  did before. Green and blue hold the bent normal as an octahedral pair. With `temporal` the history images are
  `RGBA16_FLOAT`. Changing `bent_normals` drops the AO images, which the next rendering allocates again.
- The stored direction is the surface normal turned toward the estimate by `min(intensity, 1)`, so `intensity` 0 stores the
  normal itself. A `RAY_TRACED` texel whose rays are all occluded keeps the surface normal.
- A view with bent normals sets `FRAME_AO_BENT_NORMALS` (bit 10 of `FrameRoot.flags`).
  `frame_bent_normal(frame, pixel, normal)` and `draw_bent_normal(frame, draw_flags, pixel, normal)` return the pixel's bent
  normal when the bit is set and the draw has screen-space terms, and `normal` otherwise. Standard, Physical and Toon
  shading and the deferred lighting resolve pass it as the `irradiance_direction` of `indirect_diffuse_irradiance` and
  `evaluate_environment_lobes`; see the [public includes](custom_shaders_reference.md#public-includes).
- Only the direction of the environment's diffuse irradiance changes: the SH lookup and the probe volume's atlas direction.
  A probe volume still biases its lookup position along, and weighs its probes by facing, the surface normal. The flat
  ambient fill, the specular lobes and specular occlusion are as without bent normals.

## Ray traced

`RAY_TRACED` replaces the screen-space estimate with rays against the traced scene ([scene tracing](scene_trace.md)).
Everything after the estimate is shared.

```c3
Renderer renderer = render::create_renderer(mem, &assets, { .ray_queries = true })!;
ViewDesc desc = render::default_view_desc();
desc.ambient_occlusion = render::AMBIENT_OCCLUSION_DEFAULT;
desc.ambient_occlusion.kind = AoKind.RAY_TRACED;
render::configure_view(&renderer, renderer.default_view, desc)!;
```

- With `RendererDesc.ray_queries` the rays run on ray queries, without them on the software walk; see
  [software and hardware kinds](scene_trace.md#software-and-hardware-kinds).
- A ray sees what a viewer at its origin would: the front of a single-sided surface, both faces of a double-sided one
  ([facing](scene_trace.md#facing)). On a deferred view with one sample per pixel, the rays of a pixel ignore the hits on
  [trace proxies](scene_trace.md#trace-proxies) that its G-buffer flags name; other views start their rays at the surface.
- Every estimate texel casts `ray_count` cosine-weighted rays over the hemisphere of its normal, each up to `radius`. A
  ray's nearest hit counts with the same distance falloff as the screen-space estimate: fully within 0.4 `radius`, fading to
  nothing at `radius`. The result lands in the same `ao_raw`, so the blur and the receivers are unchanged.
- The rays find occluders the screen cannot see: off-screen geometry and surfaces hidden behind nearer ones. Only
  [the traced scene](scene_trace.md#what-traces) occludes.
- Cost grows in proportion to `ray_count`. The pass is still `Pass.AMBIENT_OCCLUSION`, and `render_view` prepares the scene
  trace automatically.

## Inspect the estimate

`gui::targets_panel` lists `ao` and `ao_raw` while the view has them. `PreviewKind.VIEW_AMBIENT_OCCLUSION` previews `ao` at
level 0 and `ao_raw`, the estimate before accumulation and blur, at level 1, white where unoccluded. The preview shows the
visibility channel only.

Run `python3 scripts/fetch_benchmark_assets.py` and `python3 scripts/build.py --example ambient_occlusion` for Sponza on a
forward and a deferred view side by side, with `--temporal`, `--bent-normals` and `--gpu-timings`. `rt_effects` cycles the
three kinds. The rendering benchmarks take `--ambient-occlusion none|half|full|ray-traced` and report
`gpu_ambient_occlusion_ms`; see [benchmarking](benchmarking.md).

## Limits

- `SSAO` is screen space only: occluders outside the view or hidden behind nearer surfaces are absent. `RAY_TRACED` sees
  them, for the traced scene.
- With `SSAO`, thin objects occlude as if they were solid to the depth behind them.
- The bent normal is estimated around the normal the effect sees: the G-buffer normal on deferred views, the one rebuilt
  from depth on forward views. On a forward view a normal map therefore does not shape the diffuse environment term while
  `bent_normals` is on.
- A forward view with AO pays for the depth prepass, and `bent_normals` quadruples the AO image memory.

## See also

- [Scene tracing](scene_trace.md) for the trace kinds and what traces.
- [Screen-space GI](screen_space_gi.md) and [probe volumes](probe_volumes.md) for the bounce and the base indirect term.
- [Anti-aliasing](anti_aliasing.md#velocity-and-history) for velocity and history.
- [Lighting techniques](lighting_techniques.md) for choosing between effects.
- [Shading paths](shading_paths.md) for the forward prepass.
