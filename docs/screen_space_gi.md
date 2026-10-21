# Screen-space indirect diffuse

`ViewDesc.screen_space_gi` adds a near-field diffuse bounce to a view: light that nearby on-screen
surfaces reflected in the previous frame. It sits on top of the base indirect term (a
[probe volume](probe_volumes.md) where one covers the surface, else the environment SH, else the flat
ambient) and never replaces it: where the effect's rays find nothing, the base term stays.

```c3
ViewDesc desc = render::default_view_desc();
desc.screen_space_gi = render::SCREEN_SPACE_GI_DEFAULT;   // a zeroed value is off
render::configure_view(&renderer, view, desc)!;
```

| `ScreenSpaceGiDesc` field | Meaning |
| --- | --- |
| `enabled` | Off by default in the view constructors |
| `trace` | `SsgiTrace.LINEAR` by default; `HIERARCHICAL` enables depth-pyramid block rejection |
| `rays` | Rays per half-resolution texel and frame, `SSGI_RAYS_MIN` (1) to `SSGI_RAYS_MAX` (8); default 4 |
| `max_steps` | March steps per ray, `SSGI_STEPS_MIN` (4) to `SSGI_STEPS_MAX` (64); default 24 |
| `max_distance` | View-space units a ray marches; default 2 |
| `thickness` | View-space depth a marched point may sit behind a stored surface and count as a hit; default 0.2 |
| `intensity` | Blend strength in `[0, 1]`; 0 gives the base term exactly; default 1 |
| `history_weight` | Share of the accumulation kept per frame, `[0, 1)`; default 0.9 |

`configure_view` faults `c3d::INVALID_ARGUMENT` for values outside these ranges and for the effect on a
`PATH_TRACED` view. A forward view with the effect gets a depth prepass whatever `depth_prepass` says, as a
view with ambient occlusion does.

## Trace mode

Set `desc.screen_space_gi.trace = SsgiTrace.HIERARCHICAL` to use the depth hierarchy on perspective
views. It keeps the configured ray and step counts and checks samples in order when a block cannot be
rejected. Orthographic cameras use the original `LINEAR` pipeline and do not build the pyramid.

Hierarchical tracing uses controlled floating-point evaluation for supported rays, so its result can
differ slightly from `LINEAR`; the modes are not bit-identical. Unsupported ray or projection bounds
fall back to ordered leaf checks. `LINEAR` remains the default and allocates no depth pyramid.

## How it works

Every frame, at half resolution, each texel casts `rays` cosine-distributed rays about its normal (the
G-buffer normal on deferred views, rebuilt from depth on forward views as for the deferred
[normal offset](shadows.md#normal-offset)) and marches them against the current depth. A hit reads the
previous frame's lit colour at the hit's previous screen position (through
the view's velocity) when the previous depth stored there matches the depth the velocity expects. The
texel stores the premultiplied bounce `PI x sum of hit radiance / rays` and the hit share `hits / rays`. A
temporal pass blends this with the texel's reprojected history (rejected on a depth mismatch or fast
motion), and one depth- and normal-aware filter writes the full-resolution result, scaled by `intensity`.

The lit passes combine it with the base term per pixel:

```
diffuse irradiance = base x min(material occlusion, ambient occlusion, 1 - hit share) + bounce x material occlusion
```

The hit share and ambient occlusion estimate the same blocked part of the hemisphere, so they bound the base
term together instead of multiplying. Specular occlusion keeps using ambient occlusion alone. Reflection hits
and probe rays never read the effect. Transparent and transmissive draws do not take it: the image describes
the opaque surface of the pixel.

A view with the effect records its velocity once depth is complete (after the prepass, and after the
G-buffer on deferred views), before ambient occlusion, the effect and lighting; other views record velocity
after the scene passes as before, except a view with [temporal ambient occlusion](ambient_occlusion.md#temporal)
or [reflection history](reflections.md#history), which records it early too. Scene-read items draw after the velocity on these views and keep the camera
velocity. The velocity image then uses the four-channel format whose third channel
holds the expected previous depth, and the view keeps a full motion history like a view with TAA or motion
blur. The previous colour is a copy of the lit image taken after the transparent pass and before debug
lines, TAA and post-processing. On a view with [fog or an atmosphere](fog.md#where-fog-applies) the copy is
taken at the fog split instead, before the fog pass and the transparent draws: the bounce source is unfogged
and holds no blended draws.

Pass order of a view with the effect:

```
forward:   depth prepass, velocity, [ambient occlusion], [depth pyramid], screen-space GI, forward pass,
           scene reads and transparent, colour copy, debug lines, [TAA], [motion blur]
deferred:  depth prepass, G-buffer, velocity, [ambient occlusion], [depth pyramid], screen-space GI,
           [reflections], lighting, forward pass, scene reads and transparent, colour copy, debug lines,
           [TAA], [motion blur]
```

`Pass.SCREEN_SPACE_GI` times the trace, temporal and filter dispatches, and `Pass.SSGI_COLOR_COPY` times
the copy. `Pass.DEPTH_PYRAMID` separately times one dispatch per mip level on hierarchical perspective
views. Include it with `SCREEN_SPACE_GI` when comparing trace modes. The `Pass` enum order is not the
recording order of every view.

`gui::targets_panel` lists `ssgi` and `ssgi_raw`; programmatically `PreviewKind.VIEW_SCREEN_SPACE_GI`
previews `ssgi` at level 0 and `ssgi_raw` at level 1. The post panel's "Screen-space GI" header edits the
settings.

## Limits

- One frame of lag: the bounce is last frame's light.
- The colour holds every scene pass: a surface seen through glass bounces the colour seen through the glass,
  and a specular highlight bounces as if it were diffuse. The march tests opaque depth only.
- Moving objects: a hit on a moving object reads its colour at its previous screen position, so its bounce
  appears in the first frame at its new place. Light it bounced onto a static surface fades there with the
  accumulation, about 22 frames to 10 percent at the default `history_weight`.
- The history is rejected when its expected depth does not match (disocclusion, moving objects) and when the
  image moves faster than 2 to 4 pixels a frame (a turning camera); the view then shows the filtered
  single-frame result, which is noisier.
- The depth history is kept at half resolution: near a depth edge a hit can be accepted or rejected by the
  neighbouring texel's depth. Depths are compared with the current projection, so a projection change
  between two frames (field of view, near plane) can decide wrongly for that frame.
- On a TAA view the copied colour is the jittered image and hit positions are unjittered; the offset stays
  below one pixel and is not corrected.
- Only what is on screen bounces; off-screen and occluded emitters contribute nothing, which the probe or SH
  term covers.
- After `configure_view`, `reset_view_history`, a new scene, or on the first frame, the effect contributes
  nothing until a frame has been rendered.

## Cost

Measured on an RTX 4090 over Sponza (`gltf_viewer --benchmark --screen-space-gi on`), medians:

| Path | Extent | `SCREEN_SPACE_GI` | `SSGI_COLOR_COPY` | `VELOCITY` |
| --- | --- | --- | --- | --- |
| deferred | 1920 x 1080 | 0.62 ms | 0.01 ms | 0.01 ms |
| forward | 1920 x 1080 | 0.79 ms | 0.01 ms | 0.01 ms |
| deferred | 3840 x 2160 | 2.44 ms | 0.05 ms | 0.05 ms |
| forward | 3840 x 2160 | 3.17 ms | 0.05 ms | 0.04 ms |

Forward views pay more because the trace and the filter reconstruct normals from depth. The two-texel face rule
(up to eight depth loads per normal) costs 4.5 % at 1920 x 1080 and 3.1 % at 3840 x 2160 over the earlier
four-load rule. A view without TAA or motion blur also pays the velocity pass and the per-candidate history commit:
`cpu_record` rose from 0.15 to 0.19 ms at 1080p on Sponza.

Noise, read on the acceptance scene (a red emitter on a grey floor, 8-bit red readings of three floor pixels
beside it over 64 frames at rest, bounces of 6 to 72 levels): a standard deviation of 5.8 to 15.7 levels with
`history_weight = 0` and 0.7 to 1.9 levels at the default 0.9, 0.11 to 0.15 of the single-frame figure. While
the image moves faster than the velocity threshold the history is rejected and each frame shows the
single-frame noise. One filter pass is kept: the accumulation holds the noise at rest under 2 levels.

Hierarchical tracing adds a full-resolution pyramid build and may reduce depth reads during the march.
Its benefit depends on the scene, resolution and ray settings. Compare the sum of `DEPTH_PYRAMID` and
`SCREEN_SPACE_GI` on the target workload; the colour copy and velocity passes still apply.

## Memory

At 1920 x 1080: raw estimate 4.1 MB, two accumulation slots 8.3 MB, two depth history slots 4.1 MB, the
previous colour 16.6 MB and the full-resolution result 16.6 MB: 49.8 MB. A view that had no velocity image
gains 16.6 MB more.

`HIERARCHICAL` adds one full-resolution `R32_FLOAT` texture with up to 16 mip levels. Each mip stores
four bytes per texel before backend allocation alignment. The texture needs one view of the full
chain and one single-level view per mip. These resources remain allocated while
hierarchical GI is configured, including when the current camera is orthographic. Switching to
`LINEAR` or disabling GI retires them after their queued uses complete; resizing recreates the chain.

## Custom shaders

A custom forward stage takes the term with `draw_screen_space_indirect(frame, draw.flags,
ivec2(gl_FragCoord.xy))` from `screen_space_gi.glsl` (zero without it) and passes it to the
`evaluate_environment` overload that takes a `vec4 screen_indirect` after the ambient occlusion; its flat
ambient fill uses `screen_space_base_share(material occlusion, ambient occlusion, screen_indirect)`. See
[public includes](custom_shaders_reference.md#public-includes).
