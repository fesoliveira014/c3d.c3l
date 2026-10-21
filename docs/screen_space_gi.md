# Screen-space indirect diffuse

`ViewDesc.screen_space_gi` adds a near-field diffuse bounce to a view: light that nearby on-screen surfaces reflected in the
previous frame. It sits on top of the base indirect term (a [probe volume](probe_volumes.md) where one covers the surface,
else the environment SH, else the flat ambient) and never replaces it. Where the effect's rays find nothing, the base term
stays. The setting is a `ScreenSpaceGiDesc` in `c3d::render`.

## Quick start

```c3
ViewDesc desc = render::default_view_desc();
desc.screen_space_gi = render::SCREEN_SPACE_GI_DEFAULT;   // a zeroed value is off
render::configure_view(&renderer, view, desc)!;
```

## Concepts

- **Source.** Every frame, at half resolution, each texel casts `rays` cosine-distributed rays about its normal and marches
  them against the current depth. The normal is the G-buffer normal on deferred views, rebuilt from depth on forward views
  as for the deferred [normal offset](shadows.md#normal-offset). A hit reads the previous frame's lit color at the hit's
  previous screen position.
- **Accumulation.** A temporal pass blends the result with the texel's reprojected history, and a depth- and normal-aware
  filter writes the full-resolution result, scaled by `intensity`.
- **Combination.** The lit passes combine the result with the base term per pixel:

  ```
  diffuse irradiance = base x min(material occlusion, ambient occlusion, 1 - hit share) + bounce x material occlusion
  ```

  The hit share and ambient occlusion estimate the same blocked part of the hemisphere, so they bound the base term
  together instead of multiplying. Specular occlusion keeps using ambient occlusion alone.
- **One frame of lag.** The bounce is last frame's light.
- **Not read by.** Reflection hits and probe rays never read the effect. Transparent and transmissive draws do not take it:
  the image describes the opaque surface of the pixel.
- **Color source.** The previous color is a copy of the lit image taken after the transparent pass and before debug lines,
  TAA and post-processing. On a view with [fog or an atmosphere](fog.md#where-fog-applies) the copy is taken at the fog
  split instead, before the fog pass and the transparent draws: the bounce source is unfogged and holds no blended draws.
- **Order.** The effect runs after depth (and the G-buffer on deferred views), velocity and ambient occlusion, and before
  lighting. A forward view with the effect gets a depth prepass whatever `depth_prepass` says, as a view with ambient
  occlusion does.
- **Velocity.** A view with the effect records velocity early and keeps a full motion history, like a view with TAA or motion
  blur; see [velocity and history](anti_aliasing.md#velocity-and-history).

## Enable the effect

| `ScreenSpaceGiDesc` field | Meaning |
| --- | --- |
| `enabled` | Off by default in the view constructors; `SCREEN_SPACE_GI_DEFAULT` sets it |
| `trace` | `SsgiTrace.LINEAR` by default; `HIERARCHICAL` enables depth-pyramid block rejection |
| `rays` | Rays per half-resolution texel and frame, `SSGI_RAYS_MIN` (1) to `SSGI_RAYS_MAX` (8); default 4 |
| `max_steps` | March steps per ray, `SSGI_STEPS_MIN` (4) to `SSGI_STEPS_MAX` (64); default 24 |
| `max_distance` | View-space units a ray marches; finite and above zero; default 2 |
| `thickness` | View-space depth a marched point may sit behind a stored surface and count as a hit; finite and above zero; default 0.2 |
| `intensity` | Blend strength in `[0, 1]`; 0 gives the base term exactly; default 1 |
| `history_weight` | Share of the accumulation kept per frame, `[0, 1)`; default 0.9 |

`create_view` and `configure_view` fault `c3d::INVALID_ARGUMENT` for values outside these ranges while `enabled` is set,
and for the effect on
a `PATH_TRACED` view.

## Choose a trace mode

Set `desc.screen_space_gi.trace = SsgiTrace.HIERARCHICAL` to use the depth hierarchy on perspective views. It keeps the
configured ray and step counts and checks samples in order when a block cannot be rejected. Orthographic cameras use the
`LINEAR` pipeline and do not build the pyramid.

- Hierarchical tracing uses controlled floating-point evaluation for supported rays, so its result can differ slightly from
  `LINEAR`. The modes are not bit-identical. Unsupported ray or projection bounds fall back to ordered leaf checks.
- `LINEAR` is the default and allocates no depth pyramid.
- `HIERARCHICAL` adds a full-resolution `R32_FLOAT` depth pyramid with up to 16 mip levels, four bytes per texel before
  backend alignment, one view of the full chain and one single-level view per mip. The pyramid stays allocated while
  hierarchical GI is configured, including when the current camera is orthographic. Switching to `LINEAR` or disabling GI
  retires it after queued uses complete, and a resize recreates it.
- The pyramid build costs a full-resolution pass and may reduce depth reads during the march. The benefit depends on the
  scene, resolution and ray settings. Compare the sum of `Pass.DEPTH_PYRAMID` and `Pass.SCREEN_SPACE_GI` on your workload.

## Cost and memory

- `Pass.SCREEN_SPACE_GI` times the trace, temporal and filter dispatches, `Pass.SSGI_COLOR_COPY` the color copy, and
  `Pass.DEPTH_PYRAMID` one dispatch per mip level on hierarchical perspective views. The `Pass` enum order is not the
  recording order of every view.
- Forward views pay more than deferred views because the trace and the filter reconstruct normals from depth. A view without
  TAA or motion blur also pays the velocity pass and the history commit.
- A view holds a half-resolution raw estimate, two accumulation slots and two depth-history slots, a full-resolution copy of
  the previous color and a full-resolution result. A view that had no velocity image gains one. See
  [images per setting](views_reference.md#images-per-setting).

## Use in custom shaders

A custom forward stage takes the term with `draw_screen_space_indirect(frame, draw.flags, ivec2(gl_FragCoord.xy))` from
`screen_space_gi.glsl` (zero without it) and passes it to the `evaluate_environment` overload that takes a
`vec4 screen_indirect` after the ambient occlusion. Its flat ambient fill uses
`screen_space_base_share(material occlusion, ambient occlusion, screen_indirect)`. See
[custom shaders](custom_shaders.md) and the [public includes](custom_shaders_reference.md#public-includes).

## Inspect the effect

`gui::targets_panel` lists `ssgi` and `ssgi_raw`. `PreviewKind.VIEW_SCREEN_SPACE_GI` previews `ssgi` at level 0 and
`ssgi_raw` at level 1. The post panel's "Screen-space GI" header edits the settings. `gltf_viewer --benchmark
--screen-space-gi on` measures it; see [benchmarking](benchmarking.md).

## Limits

- One frame of lag: the bounce is last frame's light.
- The color holds every scene pass. A surface seen through glass bounces the color seen through the glass, and a specular
  highlight bounces as if it were diffuse. The march tests opaque depth only.
- A hit on a moving object reads its color at its previous screen position, so its bounce appears in the first frame at its
  new place. Light it bounced onto a static surface fades there with the accumulation: about 22 frames to 10 percent at the
  default `history_weight`.
- The history is rejected when its expected depth does not match (disocclusion, moving objects) and when the image moves
  faster than 2 to 4 pixels a frame (a turning camera). The view then shows the filtered single-frame result, which is
  noisier.
- The depth history is kept at half resolution, so near a depth edge a hit can be accepted or rejected by the neighboring
  texel's depth. A projection change between two frames (field of view, near plane) can decide wrongly for that frame.
- On a TAA view the copied color is the jittered image while hit positions are unjittered. The offset stays below one pixel
  and is not corrected.
- Only what is on screen bounces. Off-screen and occluded emitters contribute nothing, which the probe or SH term covers.
- After `configure_view`, `reset_view_history`, a new scene, or on the first frame, the effect contributes nothing until a
  frame has been rendered.

## See also

- [Ambient occlusion](ambient_occlusion.md) and [probe volumes](probe_volumes.md) for the other indirect terms.
- [Anti-aliasing](anti_aliasing.md#velocity-and-history) for velocity and history.
- [Lighting techniques](lighting_techniques.md) for choosing between effects.
- [Views reference](views_reference.md) for `ViewDesc` and image counts.
