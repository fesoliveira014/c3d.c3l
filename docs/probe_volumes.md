# Probe volumes

A probe volume stores diffuse indirect light on a grid of probes and lights every surface inside its box from that grid
instead of the environment's spherical harmonics (SH). The component is `light::ProbeVolume` in `c3d::light`; the renderer
owns its atlases. Specular light stays with the environment; local specular reflections come from
[reflection probes](reflection_probes.md). A volume fills its atlases from the environment, from the traced scene, or not
at all.

## Quick start

An environment-filled volume over a room:

```c3
Node* volume_node = scene.add_node(name: "probe_volume")!;
volume_node.local.position = (bounds.min + bounds.max) * 0.5f;
scene.add(volume_node, light::probe_volume((bounds.max - bounds.min) * 0.5f, { 16, 8, 8 }));
```

## Concepts

- **Fill.** `ENVIRONMENT` copies the scene environment's diffuse SH and a flat visibility into the atlases. `SCENE` traces
  the scene from every probe and blends the result in. `NONE` never fills.
- **Which volume lights a surface.** Each view packs every volume it sees, smallest box first. A surface takes its diffuse
  irradiance from the first volume whose box contains its position. Outside every box it keeps the SH term. Volumes do not
  blend with each other or with the SH, so a box face can show a seam. Two overlapping boxes of equal size resolve by
  renderer slot order, which the application does not control.
- **Eligibility.** A volume lights a view when its node is visible (`visible_effective`) and shares a layer bit with the
  camera. Hiding the node switches the volume off without losing its atlases.
- **Sampling.** Every probe keeps an octahedral irradiance cell and a visibility cell holding the mean and squared mean
  distance to the nearest surface. A shaded point offsets itself by the two biases, finds the eight surrounding probes, and
  weights each by the trilinear factor, a backface term and a Chebyshev visibility term that drops probes whose view of the
  point is blocked. Under an `ENVIRONMENT` fill every visibility texel reads `max_distance`, so the result equals the SH up
  to the atlas resolution.
- **Consumers.** Forward and deferred views, Standard, Physical and Toon materials, and ray-traced reflection hits read the
  same term. A path-traced view never reads probe volumes.

## Add a volume

`probe_volume(half_extents, counts, fill = ENVIRONMENT)` derives the rest from the probe spacing: `normal_bias` 0.05 and
`view_bias` 0.1 of the smallest spacing, `max_distance` 1.5 times the largest, `energy` 1. The node's rotation and scale are
ignored. A zeroed `ProbeVolume` is not valid (its counts are 0); the renderer requires `light::probe_volume_valid`.

| Field | Meaning |
| --- | --- |
| `half_extents` | Half size of the axis-aligned box around the node's world position, world units; finite and positive |
| `counts` | Probes per axis, `PROBE_COUNT_MIN` (2) to `PROBE_COUNT_MAX` (32); the first and last probe of an axis sit on the box faces |
| `normal_bias` | Offset along the surface normal before sampling, world units; not negative |
| `view_bias` | Offset toward the viewer before sampling, world units; not negative |
| `energy` | Scale of the sampled irradiance; not negative. The bounce between probes always uses unit energy, so a high value cannot make the feedback diverge |
| `max_distance` | Visibility clamp, world units; not negative |
| `fill` | Source of the atlas texels: `NONE`, `ENVIRONMENT` or `SCENE` |
| `update` | Ray budget and blend of `SCENE` updates (`ProbeUpdateDesc`) |

## Choose a fill

- **`ENVIRONMENT`** fills both atlases from the scene environment: irradiance from its SH (with the environment intensity
  and rotation baked in), visibility at `max_distance`. The fill runs when the renderer first sees the volume, when `counts`
  changes, and when the environment, its lighting (a regenerated source included), its intensity or its rotation changes. A
  changed `max_distance` refills the visibility atlas only. Without a live scene environment the volume lights nothing.
  Under an [atmosphere](sky.md) the fill reads the atmosphere's SH with the sun's intensity and refills on every
  regeneration of its lighting.
- **`SCENE`** traces the scene from every probe each update; see [update from the scene](#update-from-the-scene).
- **`NONE`** never fills. A volume that was filled keeps its texels, so switching `ENVIRONMENT` to `NONE` freezes the atlas.
  A volume that was never filled lights nothing. Changing `counts` under `NONE` replaces the atlases and loses the frozen
  texels.

Switching: `ENVIRONMENT` to `SCENE` blends from the environment texels without a sweep. `SCENE` to `ENVIRONMENT` refills at
once. `SCENE` to `NONE` freezes the texels.

## Update from the scene

A `SCENE` volume casts `update.rays_per_probe` rays from each probe of a window through the
[scene trace](scene_trace.md), shades each hit, and blends the per-texel estimate into the atlases:
`texel = mix(estimate, previous, update.hysteresis)`.

| `ProbeUpdateDesc` field | Meaning |
| --- | --- |
| `rays_per_probe` | `PROBE_RAYS_MIN` (32) to `PROBE_RAYS_MAX` (256); default 128 |
| `probes_per_frame` | Round-robin window; 0 (default) or at least the probe count updates every probe |
| `hysteresis` | Share of the previous texel kept per update, `[0, 1)`; default 0.97, 95 percent of a change after 99 updates of a probe |

### What a ray sees

- **Trace.** A renderer created with `RendererDesc.ray_queries` traces probe rays through ray queries and any other renderer
  uses the software walk; see [software and hardware kinds](scene_trace.md#software-and-hardware-kinds). The trace holds
  what [the scene trace contains](scene_trace.md#what-traces). A hit that lands exactly on a volume's box face takes the
  probes or the SH term by the last bit of its distance, so there the two kinds can differ.
- **Hit shading.** A hit adds its diffuse direct light, its emission and the bounce the atlases already hold (`albedo / PI`
  times the irradiance at the hit), so light bounces further with every update. `BASIC` is its unlit albedo, `STANDARD` and
  `PHYSICAL` use `albedo * (1 - metallic)` so metals bounce nothing (a Physical hit adds no clearcoat, specular or
  transmission), `TOON` uses its bands and `CUSTOM` is a grey Lambert surface. Misses read the lighting environment, or the
  flat ambient without one. Back faces return no light and mark the probe's view of that direction as blocked.
- **Lights.** Hits are lit by every light on a visible node with nonzero layers, whatever the camera sees. A light skips a
  hit whose node `layers` do not intersect `Light.layers` (the [receiver mask](lights.md#concepts)); emission and the bounce
  do not use the mask. Every light with shadows enabled traces one shadow ray per hit that it can reach; the shadow atlas is
  not used. Up to `RendererDesc.max_lights` lights apply, with drops counted in `Stats.lights_dropped`. Each scene update
  owns a separate no-frustum [spatial lookup](lights.md#spatial-light-lookup).
- **Fog.** A hit takes the scene's height fog and, behind it, its atmosphere over the ray from the probe. A miss takes the
  height fog to infinity. The fog is the first valid `HeightFog` on a visible node of any layer; see
  [fog at hits](fog.md#where-fog-applies).

### Sweeps and movement

- **First sweep.** A new atlas is cleared in the frame it is created, and each probe's first visit replaces its texels
  instead of blending. Views keep the SH until every probe holds an estimate: the first frame with
  `probes_per_frame = 0`, else `ceil(count / window)` frames.
- **Moving the node.** A move of more than half the smallest spacing between two updates restarts the atlas. Smaller moves
  are followed with the lag of the blend, about 33 updates of travel at the default hysteresis.
- **Hidden volumes** are not updated. They keep their texels and resume from them when shown.
- **Two scenes in one frame** both update; the trace is rebuilt for each.
- **Trace preparation.** A scene with a `SCENE` volume prepares the scene trace every frame it renders. On a ray-query
  renderer the first due update also builds one bottom level per traceable geometry, so a scene whose only trace consumer is
  a probe volume pays those builds in its first frame. A traced view of the same scene reuses them.

### Probes in walls

A scheduled visit excludes a probe when more than 25 percent of all its rays hit the back of the nearest accepted
single-sided surface. Misses stay in the denominator; alpha-rejected intersections and double-sided surfaces do not count as
burial. A probe behind a single-sided wall can be excluded even when the wall is not a closed solid.

- An excluded probe gets exactly zero weight at sampling. If all eight surrounding probes are excluded, the result is the
  diffuse fallback outside all volumes: the environment SH when available, otherwise zero probe irradiance.
- Excluded probes still trace on every scheduled visit, so a geometry change shows by the next visit. Reactivation replaces
  irradiance and visibility with fresh estimates regardless of hysteresis.
- Probes are provisionally eligible after a fill, restart or recreation until a `SCENE` visit measures them.
- An enclosure smaller than the grid spacing can have all eight probes buried and show global diffuse. Use a finer grid or
  different placement. A seam can appear between an all-excluded cell and an eligible neighbor.

## Debug probes

- `DebugDraw.probe_volumes(scene, rgba)` draws each visible volume's box and a small cross per probe. A 32 x 32 x 32 volume
  exceeds the default line sink, which drops the rest silently.
- `gui::targets_panel` lists `probe irradiance N` and `probe visibility N` for every live atlas. The scene panel's inspector
  edits every field; dragging `counts` creates new atlases on every changed value.
- The public include `probe_classification.glsl` provides `uint probe_classification(ProbeVolumeGpu volume, uvec3 probe)`
  for an in-range grid coordinate. It returns `PROBE_CLASS_PROVISIONAL`, `PROBE_CLASS_ELIGIBLE` or `PROBE_CLASS_EXCLUDED`.
  View rows flagged `PROBE_VOLUME_UNSWEPT` are available for inspection while ordinary lighting retains the first-sweep gate.
  Custom shaders that use `ibl.glsl` apply exclusion automatically.

Run `python3 scripts/fetch_benchmark_assets.py` and `python3 scripts/build.py --example probe_volume` for Sponza lit by one
volume. `--fill none|environment|scene` selects the source, `--trace hardware` creates the renderer with ray queries, and
`--deferred` uses the deferred path. Markers are gray for provisional probes, green for eligible probes and red for excluded
probes. `gltf_viewer --benchmark` takes `--probe-volumes`, `--probe-counts`, `--probe-fill`, `--probe-window` and
`--probe-rays`; see [benchmarking](benchmarking.md).

## Reference

### Capacity and memory

- A renderer keeps atlases for 8 volumes across every scene it renders (`shader::PROBE_VOLUME_CAPACITY`). A volume that
  finds no free slot renders with the SH and counts in `Stats.probe_volumes_dropped`, once per view that tried. Within one
  scene the volumes that took a slot first keep it. The atlases of a scene that has not been rendered for more than
  `FRAMES_IN_FLIGHT + 1` frames can be taken by another scene's volumes. Atlases are released the first frame after their
  node dies or loses the component.
- Each probe costs 1,536 bytes of atlas: 512 for irradiance and 1,024 for visibility. A 32 x 32 x 32 volume holds 48 MiB,
  and eight of them 384 MiB.
- A `SCENE` update keeps a ray buffer of 16 bytes per ray at the largest window seen (64 MiB for 32 x 32 x 32 probes at 128
  rays), until `destroy_renderer`.

### Cost per update

- `window x rays_per_probe` primary rays, counted in `Stats.probe_rays`, and at most one shadow ray per hit and shadowing
  light.
- Five dispatches: trace, two blends and two border copies over the whole atlas. An `ENVIRONMENT` fill runs two dispatches
  per atlas on the frames listed above. `Pass.PROBE_UPDATE` times both. On a ray-query renderer `Pass.ACCELERATION_BUILD`
  times the first frame's builds.
- Shading tests up to 8 boxes per shaded fragment and per shaded reflection hit and, inside a volume, reads 8 probes with
  one irradiance and one visibility sample each.

### Faults

A scene with a due `SCENE` volume can make `render_view` fault as a ray-traced view does:

| Fault | Cause |
| --- | --- |
| `c3d::CAPACITY_EXCEEDED` | More traceable instances than `RendererDesc.max_trace_instances` |
| `c3d::ASSET_DATA_UNAVAILABLE` | A traceable geometry's CPU arrays were released before its first trace upload |
| `gpu::OUT_OF_DEVICE_MEMORY`, `gpu::OUT_OF_HOST_MEMORY` | The trace or ray buffer, or on a ray-query renderer a bottom level, the top level or their scratch |
| `gpu::UNSUPPORTED_FEATURE` | An acceleration-structure build the device refuses |
| `gpu::SLOT_TABLE_FULL`, `gpu::DESCRIPTOR_HEAP_FULL` | The top-level view cannot be published |

## Limits

- 8 volumes at once, 32 probes per axis, no blending between volumes or between a volume and the SH.
- A volume lights the diffuse term only; specular stays with the environment and reflection probes.
- Seams show at box faces. Enclosures thinner than the probe spacing can show global diffuse.
- A `SCENE` volume follows changes with the lag of its blend: `hysteresis` sets how many updates a change takes.

## See also

- [Scene tracing](scene_trace.md) for what the trace contains and the two kinds.
- [Lighting techniques](lighting_techniques.md) for choosing between effects.
- [Environments](environments.md) and [sky](sky.md) for the fills.
- [Ambient occlusion](ambient_occlusion.md#bent-normals) for bent-normal use of the diffuse term.
