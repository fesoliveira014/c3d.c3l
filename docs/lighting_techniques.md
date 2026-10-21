# Lighting techniques

c3d offers several ways to light a surface beyond direct lights. Each adds a different term, needs different renderer
features and costs a different amount. This page compares them and shows how they combine. Each technique has its own page.

## Choose a technique

| Technique | Adds | Requires | Cost class | Main limit |
| --- | --- | --- | --- | --- |
| [Environment](environments.md) | Diffuse (SH) and filtered specular from a sky or an image | A scene environment | Preparation only; no per-frame work beyond sampling | One global term; no occlusion |
| [Probe volume](probe_volumes.md) | Local diffuse indirect from a grid of probes | A `ProbeVolume` node. `SCENE` fill uses the scene trace | `ENVIRONMENT` fill: a fill on change. `SCENE` fill: rays every update, `window x rays_per_probe` | 8 volumes; no blending between volumes; 48 MiB per 32 x 32 x 32 volume |
| [Reflection probe](reflection_probes.md) | Local box-projected specular from a captured or authored cube | A `ReflectionProbe` node and a cube environment | A capture is six frames, once per capture; sampling is a few texture reads | Static; 16 nearest per view; no diffuse |
| [Ambient occlusion](ambient_occlusion.md) | Darkens indirect diffuse and specular where geometry blocks it | A depth prepass (forced). `RAY_TRACED` uses the scene trace | Screen-space dispatches, or rays per estimate texel | `SSAO` sees only the screen |
| [Screen-space GI](screen_space_gi.md) | A near-field diffuse bounce from the previous frame's screen | A depth prepass (forced) and a velocity image | Half-resolution rays and a temporal filter | One frame of lag; only what is on screen |
| [Ray-traced reflections](reflections.md) | Mirror-like and glossy reflections of the whole scene | The scene trace, on a deferred or forward view | Rays per traced pixel, plus a blur | Roughness threshold; G-buffer-encodable materials |
| [Ray-traced shadows](ray_traced_shadows.md) | Shadows resolved with rays, soft for lights with a size | The scene trace; no atlas layers | One or more rays per shaded pixel and traced light | Cost grows with traced lights |
| [Path tracing](path_tracing.md) | A complete, unbiased reference image | `RendererDesc.ray_tracing_pipelines` | Rays per sample, accumulating over frames | No raster effects; converges slowly |

Traced effects run on ray queries when the renderer is created with `RendererDesc.ray_queries` and on a software walk
otherwise. See [software and hardware kinds](scene_trace.md#software-and-hardware-kinds) and
[what traces](scene_trace.md#what-traces). Only path tracing needs ray-tracing pipelines.

## Combine techniques

- **Base indirect diffuse.** A surface takes its indirect diffuse from the first [probe volume](probe_volumes.md) that
  contains it, else the environment's SH, else the flat ambient. Screen-space GI adds a bounce on top of that term and never
  replaces it.
- **Occlusion.** Ambient occlusion multiplies the indirect terms and bounds them together with the screen-space GI hit
  share and the material's occlusion map. It does not darken direct light.
- **Specular.** The environment's prefiltered specular is replaced by [reflection probes](reflection_probes.md) inside their
  boxes. [Ray-traced reflections](reflections.md#lighting) replace the probe and environment term on smooth pixels and blend
  over the top fifth of `max_reflection_roughness`.
- **Path tracing.** A `PATH_TRACED` view computes all of the above as part of the path. It rejects ambient occlusion,
  screen-space GI, ray-traced shadows, TAA, motion blur and depth of field, and never reads probe volumes or reflection
  probes.

## Choose by goal

- A convincing outdoor or studio scene: an [environment](environments.md) or a [sky](sky.md), plus shadows.
- Indoor rooms with bounce: a `SCENE` probe volume, or an environment-filled volume for a cheap local term.
- Glossy interiors: a reflection probe per room; add traced reflections for mirrors.
- Contact darkening: ambient occlusion, with `temporal` to remove the grain.
- A quick near-field bounce: screen-space GI.
- A ground-truth image to compare against: the path tracer.

## See also

- [Views reference](views_reference.md#images-per-setting) for the images each setting allocates.
- [Shading paths](shading_paths.md) for forward and deferred views.
- [Scene tracing](scene_trace.md) for the trace the traced effects share.
