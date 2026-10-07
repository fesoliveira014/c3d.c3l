# Probe volumes

A probe volume stores diffuse indirect light on a grid of probes and lights every surface inside
its box from that grid instead of the environment's spherical harmonics. The component is
`light::ProbeVolume`; the renderer owns its atlases. Specular light stays with the environment; local specular reflections come from
[reflection probes](reflection_probes.md).

```c3
Node* volume_node = scene.add_node(name: "probe_volume")!;
volume_node.local.position = (bounds.min + bounds.max) * 0.5f;
scene.add(volume_node, light::probe_volume((bounds.max - bounds.min) * 0.5f, { 16, 8, 8 }));
```

| Field | Meaning |
| --- | --- |
| `half_extents` | Half size of the axis-aligned box around the node's world position, world units |
| `counts` | Probes per axis, `PROBE_COUNT_MIN` (2) to `PROBE_COUNT_MAX` (32); the first and last probe of an axis sit on the box faces |
| `normal_bias` | Offset along the surface normal before sampling, world units |
| `view_bias` | Offset toward the viewer before sampling, world units |
| `energy` | Scale of the sampled irradiance |
| `max_distance` | Visibility clamp, world units |
| `fill` | Source of the atlas texels: `NONE`, `ENVIRONMENT` or `SCENE` |
| `update` | Ray budget and blend of `SCENE` updates (`ProbeUpdateDesc`) |

`probe_volume(half_extents, counts, fill = ENVIRONMENT)` derives the rest from the probe spacing:
`normal_bias` 0.05 and `view_bias` 0.1 of the smallest spacing, `max_distance` 1.5 times the
largest, `energy` 1. The node's rotation and scale are ignored. A zeroed `ProbeVolume` is not a
valid component (its counts are 0); the renderer requires `light::probe_volume_valid`.

## What the fields select

`fill` selects where the texels come from; the node's visibility and layers select whether the
volume lights anything.

- `ENVIRONMENT` fills both atlases from the scene environment: irradiance from its SH (with the
  scene's environment intensity and rotation baked in), visibility at `max_distance`. The fill runs
  when the renderer first sees the volume, when `counts` changes, and when the environment, its
  lighting (a regenerated source included), its intensity or its rotation changes; a changed
  `max_distance` refills the visibility atlas only. Without a live scene environment the volume
  holds no fill and lights nothing. Under an [atmosphere](sky.md) the fill reads the atmosphere's SH, with
the sun's intensity, and refills on every regeneration of its lighting.
- `SCENE` traces the scene from every probe each update and blends the result into the atlases (see
  [Scene updates](#scene-updates)).
- `NONE` never fills. A volume that was filled keeps its texels, so switching `ENVIRONMENT` to
  `NONE` freezes the atlas; a volume that was never filled lights nothing. Changing `counts` under
  `NONE` replaces the atlases and loses the frozen texels.
- A volume lights a view when its node is visible (`visible_effective`) and shares a layer bit
  with the camera. Hiding the node switches the volume off without losing its atlases.

## Scene updates

A `SCENE` volume casts `update.rays_per_probe` rays from each probe of a window through the
[scene trace](scene_trace.md), shades each hit, and blends the per-texel estimate into the atlases:
`texel = mix(estimate, previous, update.hysteresis)`.

**Trace kind.** A renderer created with `RendererDesc.ray_queries` traces probe rays through ray queries;
any other renderer uses the software walk. There is no setting: comparing the two means two renderers. Both
kinds hit the same triangles, report back faces the same way (a probe inside a wall is excluded on both: the probe
ray keeps both faces through `trace_scene_with_back_faces`, while its hits' shadow rays follow the atlas) and
use the same default of 128 rays per probe; on the RTX 4090 every ray result of the acceptance room agrees
between them. A hit that lands exactly on a volume's box face takes the probes or the SH term by the last
bit of its distance, so there the kinds can differ. The ray rotations start after the all-zero Halton point,
which would keep one ray of every probe in its layer's plane.

| `ProbeUpdateDesc` field | Meaning |
| --- | --- |
| `rays_per_probe` | `PROBE_RAYS_MIN` (32) to `PROBE_RAYS_MAX` (256); default 128 |
| `probes_per_frame` | Round-robin window; 0 (default) or at least the probe count updates every probe |
| `hysteresis` | Share of the previous texel kept per update, `[0, 1)`; default 0.97, 95 percent of a change after 99 updates of a probe |

A hit adds its diffuse direct light, its emission and the bounce the probe atlases already hold
(`albedo / PI` times the irradiance at the hit), so light bounces further with every update. Misses read the
lighting environment (or the flat ambient without one). Back faces return no light, count in the
probe's irradiance with their weight and mark the probe's view of that direction as blocked. Every update
rotates its ray set by a rotation drawn from the frame index.

- **Lights.** Hits are lit by every light on a visible node with nonzero layers, whatever the camera sees
  and whatever the light's layers say: a light hidden from one camera by a layer still lights the probes.
  Every light with shadows enabled traces one shadow ray per hit that it can reach (facing, in range and
  cone); the shadow atlas is not used. Up to `RendererDesc.max_lights` lights; drops count in
  `Stats.lights_dropped`.
- **First sweep.** A new atlas is cleared (zero irradiance) in the frame it is created, and each probe's first
  visit replaces its texels instead of blending. Views keep the SH until every probe holds an estimate; with
  `probes_per_frame = 0` that is the first frame, with a window `ceil(count / window)` frames. Bounces during
  the sweep read the texels as they stand.
- **Switching fill.** `ENVIRONMENT` to `SCENE` blends from the environment texels without a sweep; `SCENE`
  to `ENVIRONMENT` refills at once; `SCENE` to `NONE` freezes the texels.
- **Moving the node.** A move of more than half the smallest spacing between two updates restarts the atlas
  (clear and first sweep); smaller moves are followed with the lag of the blend, about 33 updates of travel
  at the default hysteresis.
- **Hidden volumes** are not updated; they keep their texels and resume from them when shown.
- **Energy** scales what views see; the bounce between probes always uses the texels at unit energy, so a
  high `energy` cannot make the feedback diverge.
- **Traced geometry only.** Skinned and morphed meshes are hit at their raster pose; crowd placements are hit only through `add_crowd(trace: true)`; custom vertex stages and batches or meshes with `trace = false` are not
  hit. A scene with a `SCENE` volume prepares the scene trace every frame it renders, which walks every
  traceable mesh and batch instance and rewrites the software top level and rows when they change, on
  either kind. On a ray-query renderer the first due update also builds one bottom level per traceable
  geometry (once per geometry revision) and the top level whenever the traced set changes; a scene whose
  only trace consumer is a probe volume pays those builds in the first frame it renders. They record in the
  frame's uploads, before `Pass.PROBE_UPDATE`, and a traced view of the same scene reuses them.
- **Two scenes in one frame** both update; the trace is rebuilt for each.
- **Probes inside or behind geometry.** Each scheduled visit excludes a probe when more than 25 percent
  of all its rays hit the back of the nearest accepted single-sided surface. Misses remain in the
  denominator; alpha-rejected intersections and double-sided surfaces do not count as burial. A probe
  behind a single-sided wall can be excluded even when the wall is not a closed solid. Probes in front
  remain eligible in the covered thin-wall placement. The same rule uses current posed geometry on both
  trace kinds; the probe ray must continue accepting both faces.
- **Classification refresh.** Excluded probes still trace on every scheduled visit. A geometry change is
  reflected by the next visit, within one rendered, visible update sweep. Exclusion takes effect on that
  visit; reactivation replaces both irradiance and visibility with fresh estimates, regardless of
  hysteresis. Neither a trace revision nor a pure frame-origin rebase restarts classification. There is
  no relocation or temporal classification filter.
- **Classification history.** Fill, restart and recreation make probes provisionally eligible until a
  SCENE visit measures them. ENVIRONMENT to SCENE retains eligibility until each visit; SCENE to NONE
  and hiding a SCENE volume freeze estimates and classification. Counts changes recreate both with the
  atlases; removal/reuse retires them together. Discarded frames publish no new classification. The
  first-sweep view gate remains unchanged, even though debug shaders can inspect provisional probes.
- **Faults.** A scene with a due `SCENE` volume can make `render_view` fault as a ray-traced view does:
  `c3d::CAPACITY_EXCEEDED` when the scene has more traceable instances than
  `RendererDesc.max_trace_instances`, `c3d::ASSET_DATA_UNAVAILABLE` when a traceable geometry's CPU arrays
  were released before its first trace upload, and the gpu faults of the trace and ray-buffer allocation. On
  a ray-query renderer the acceleration-structure faults join them: `gpu::OUT_OF_DEVICE_MEMORY` or
  `gpu::OUT_OF_HOST_MEMORY` for a bottom level, the top level or their scratch, `gpu::UNSUPPORTED_FEATURE`
  for a build the device refuses, `gpu::SLOT_TABLE_FULL` or `gpu::DESCRIPTOR_HEAP_FULL` when the top-level
  view cannot be published.

Cost per update: `window x rays_per_probe` primary rays (`Stats.probe_rays`; shadow rays are not counted, at
most one per hit and shadowing light), five dispatches (trace, two blends, two border copies over the whole
atlas), and a ray buffer of 16 bytes per ray at the largest window seen (64 MiB for 32 x 32 x 32 probes at
128 rays), kept until `destroy_renderer`. Classification adds a back-face count to the existing irradiance
blend and uses its unused alpha channel; it adds no allocation or dispatch. Excluded probes retain their
tracing cost so moving geometry can uncover them. `Pass.PROBE_UPDATE` times fills and updates.

Matched classification measurements on an RTX 4090 (driver 610.88), Sponza at 3840 x 2160,
fixed camera, sun only and 128 rays per probe. Both builds used O3, GPU profiling and validation off,
with 64 warm-up and 256 measured frames per run. The table reports the median of three interleaved
runs; [the review](https://github.com/fesoliveira014/c3d.c3l/pull/254#pullrequestreview-5436918402)
records the run ranges and exact commands.

| Volume | Trace | Before classification | With classification |
| --- | --- | ---: | ---: |
| 8 x 4 x 8 probes, full window | Ray queries | 0.0796 ms | 0.0848 ms |
| 8 x 4 x 8 probes, full window | Software | 0.7857 ms | 0.7986 ms |
| 16 x 16 x 16 probes, window 512 | Ray queries | 0.1058 ms | 0.1096 ms |
| 16 x 16 x 16 probes, window 512 | Software | 0.7232 ms | 0.7557 ms |

All four configurations passed the added-cost bound of `max(10% of baseline, 0.02 ms)`.

Historical measurements before classification, on an RTX 4090 over Sponza at 3840 x 2160,
`Pass.PROBE_UPDATE` median per frame:

| Volume | Trace | Sun only | 64 shadowing point lights |
| --- | --- | --- | --- |
| 8 x 4 x 8 probes, 128 rays, every probe | software | 0.69 ms | 0.96 ms |
| 8 x 4 x 8 probes, 256 rays, every probe | software | 0.79 ms | 1.08 ms |
| 8 x 4 x 8 probes, 128 rays, every probe | ray queries | 0.08 ms | 0.10 ms |
| 8 x 4 x 8 probes, 256 rays, every probe | ray queries | 0.11 ms | 0.14 ms |
| 16 x 16 x 16 probes, 128 rays, window 512 | software | 0.65 ms | 0.80 ms |
| 32 x 32 x 32 probes, 128 rays, window 512 | software | 0.70 ms | |

On ray queries the first frame builds the bottom levels of every traceable geometry: `Pass.ACCELERATION_BUILD`
read 51 ms in that frame for Sponza (one reading), and zero afterwards while the scene holds still.

A window's cost depends on how many of its rays hit: the windowed rows range from about 0.25 ms to
about 1.0 ms between the 10th and 90th percentiles, and the border copies over the 32 x 32 x 32 atlases do
not show above that spread. A ray-traced reflection view records in 0.21 ms of CPU with a `SCENE` volume
and 0.18 ms without one.

## Which volume lights a surface

Each view packs every defined volume it sees, smallest box first, with a flag preserving first-sweep
sampling eligibility. A surface takes its diffuse
irradiance from the first volume whose box contains its position; outside every box it keeps the
SH term. There is no blending between volumes or between a volume and the SH, so a box face can
show a seam. Two overlapping boxes of equal size resolve by renderer slot order, which the
application does not control.

Forward and deferred views, Standard, Physical and Toon materials, and ray-traced reflection hits
all read the same term. A path-traced view never reads probe volumes.

## Sampling

Every probe keeps an 8 x 8 texel octahedral irradiance cell (6 x 6 interior texels) and a 16 x 16
visibility cell holding the mean and squared mean distance to the nearest surface. A shaded point
offsets itself by the two biases, finds the eight surrounding probes and weights each by the
trilinear factor, a backface term that fades probes behind the surface, and a Chebyshev visibility
term that drops probes whose view of the point is blocked. Under an `ENVIRONMENT` fill every
visibility texel reads `max_distance`, so the result equals the SH up to the atlas resolution.

Excluded probes receive exactly zero weight before any positive weight floor. The remaining weights
are normalized over eligible probes. If all eight are excluded, the result is exactly the diffuse
fallback outside all volumes: environment SH when available, otherwise zero probe irradiance. Ordinary
ambient remains separate; no other overlapping volume is searched. Receiver shading and probe-hit
bounces use the same shared sampling and fallback.

The closed-room guarantee requires a cell with usable local probes. An enclosure smaller than the grid
spacing can have all eight probes buried and show global diffuse. Use a finer grid or different probe
placement in that case. A seam can appear between an all-excluded cell and an eligible neighbor.

## Capacity and memory

A renderer keeps atlases for 8 volumes across every scene it renders
(`shader::PROBE_VOLUME_CAPACITY`). A volume that finds no free slot renders with the SH and counts
in `Stats.probe_volumes_dropped`, once per view that tried. Within one scene the volumes that took
a slot first keep it; the fix for drops is fewer volumes. The atlases of a scene that has not been
rendered for more than `FRAMES_IN_FLIGHT + 1` frames can be taken by another scene's volumes.
Atlases are released the first frame after their node dies or loses the component.

Each probe costs 512 B of irradiance and 1024 B of visibility (1536 B); a 32 x 32 x 32 volume
holds 48 MiB, eight of them 384 MiB. Z slices are laid side by side and wrap into rows, so every
volume fits a 4096 x 4096 image. Dragging `counts` in the inspector creates new atlases and
retires the old ones on every changed value.

## Cost

The fill runs two compute dispatches per atlas (fill and border copy) on the frames listed above,
timed as `Pass.PROBE_UPDATE`, and none otherwise. Shading tests up to 8 boxes per shaded fragment
and per shaded reflection hit and, inside a volume, reads 8 probes with one irradiance and one
visibility sample each; excluded probes skip the visibility sample.

## Debugging

- `DebugDraw.probe_volumes(scene, rgba)` draws each visible volume's box and a small cross per
  probe; a 32 x 32 x 32 volume exceeds the default line sink, which drops the rest silently.
- The targets panel lists `probe irradiance N` and `probe visibility N` for every live atlas;
  visibility previews show the mean distance over the panel's depth range.
- The scene panel's inspector edits every field.
- Public `probe_classification.glsl` provides
  `uint probe_classification(ProbeVolumeGpu volume, uvec3 probe)` for an in-range grid coordinate.
  It reads the live atlas and returns `PROBE_CLASS_PROVISIONAL`, `PROBE_CLASS_ELIGIBLE` or
  `PROBE_CLASS_EXCLUDED`. Provisional probes remain eligible but have no geometric measurement since
  their last fill, restart or recreation. View rows flagged `PROBE_VOLUME_UNSWEPT` are available for
  inspection while ordinary lighting retains the first-sweep gate. A volume without defined atlases
  has no packed row; debug displays may show it as provisional without an atlas read.
- Custom shaders using `ibl.glsl` apply exclusion automatically. There is no CPU per-probe snapshot or
  excluded-count field: flat probe views have no existing frame-slot readback resource for that counter.

## Example

`examples/probe_volume` lights Sponza from one environment-filled volume. Its controls hide the
volume node (the SH term returns) and toggle the live probe markers; the targets panel shows both
atlases. `--deferred` uses the deferred shading path.

```bash
python3 scripts/fetch_benchmark_assets.py
python3 scripts/build.py --example probe_volume
```

`--fill none|environment|scene` selects the source and a "Move sun" control turns the sun, so a `SCENE`
volume shows its update converge; the stats panel lists probe rays and updates. `--trace hardware` creates
the renderer with ray queries (the example exits with the reason on a device without them); the controls
panel names the kind in use.

Markers are gray for provisional probes, green for measured eligible probes and red for measured
excluded probes. They read the same live classification as the view and remain visible through geometry.
One fixed-capacity billboard batch holds the grid coordinates; only placement changes update those
records. The markers never participate in tracing. ENVIRONMENT and unfilled NONE volumes appear gray.

`gltf_viewer --benchmark` takes `--probe-volumes 0|1|8`, `--probe-counts X,Y,Z` (default 16,8,8),
`--probe-fill environment|scene` and `--probe-window N` to measure the shading and update costs: 1 places
one volume over the model bounds, 8 one per octant; `--point-shadows on` gives the point lights shadows, so
every one of them traces at probe hits; `--probe-rays N` sets `rays_per_probe`; `--trace software|hardware`
selects the kind. The CSV has `gpu_probe_update_ms` and `gpu_acceleration_build_ms`.
