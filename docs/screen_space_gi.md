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
| `rays` | Rays per half-resolution texel and frame, `SSGI_RAYS_MIN` (1) to `SSGI_RAYS_MAX` (8); default 4 |
| `max_steps` | March steps per ray, `SSGI_STEPS_MIN` (4) to `SSGI_STEPS_MAX` (64); default 24 |
| `max_distance` | View-space units a ray marches; default 2 |
| `thickness` | View-space depth a marched point may sit behind a stored surface and count as a hit; default 0.2 |
| `intensity` | Blend strength in `[0, 1]`; 0 gives the base term exactly; default 1 |
| `history_weight` | Share of the accumulation kept per frame, `[0, 1)`; default 0.9 |

`configure_view` faults `c3d::INVALID_ARGUMENT` for values outside these ranges. A forward view with the
effect gets a depth prepass whatever `depth_prepass` says, as a view with ambient occlusion does.

## How it works

Every frame, at half resolution, each texel casts `rays` cosine-distributed rays about its normal (the
G-buffer normal on deferred views, reconstructed from depth on forward views) and marches them against the
current depth. A hit reads the previous frame's lit colour at the hit's previous screen position (through
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
after the scene passes as before. The velocity image then uses the four-channel format whose third channel
holds the expected previous depth, and the view keeps a full motion history like a view with TAA or motion
blur. The previous colour is a copy of the lit image taken after the transparent pass and before debug
lines, TAA and post-processing.

Pass order of a view with the effect:

```
forward:   depth prepass, velocity, [ambient occlusion], screen-space GI, forward pass, transmission and
           transparent, colour copy, debug lines, [TAA], [motion blur]
deferred:  depth prepass, G-buffer, velocity, [ambient occlusion], screen-space GI, [reflections], lighting,
           forward pass, transmission and transparent, colour copy, debug lines, [TAA], [motion blur]
```

`Pass.SCREEN_SPACE_GI` times the three dispatches and `Pass.SSGI_COLOR_COPY` the copy; the `Pass` enum order
is not the recording order of every view.

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

## Memory

At 1920 x 1080: raw estimate 4.1 MB, two accumulation slots 8.3 MB, two depth history slots 4.1 MB, the
previous colour 16.6 MB and the full-resolution result 16.6 MB: 49.8 MB. A view that had no velocity image
gains 16.6 MB more.

## Custom shaders

A custom forward stage takes the term with `draw_screen_space_indirect(frame, draw.flags,
ivec2(gl_FragCoord.xy))` from `screen_space_gi.glsl` (zero without it) and passes it to the
`evaluate_environment` overload that takes a `vec4 screen_indirect` after the ambient occlusion; its flat
ambient fill uses `screen_space_base_share(material occlusion, ambient occlusion, screen_indirect)`. See
[custom shaders](custom_shaders.md).
