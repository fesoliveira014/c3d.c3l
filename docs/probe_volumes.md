# Probe volumes

A probe volume stores diffuse indirect light on a grid of probes and lights every surface inside
its box from that grid instead of the environment's spherical harmonics. The component is
`light::ProbeVolume`; the renderer owns its atlases. Specular light stays with the environment.

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
| `fill` | Source of the atlas texels: `NONE` or `ENVIRONMENT` |

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
  holds no fill and lights nothing.
- `NONE` never fills. A volume that was filled keeps its texels, so switching `ENVIRONMENT` to
  `NONE` freezes the atlas; a volume that was never filled lights nothing.
- A volume lights a view when its node is visible (`visible_effective`) and shares a layer bit
  with the camera. Hiding the node switches the volume off without losing its atlases.

## Which volume lights a surface

Each view packs every filled volume it sees, smallest box first. A surface takes its diffuse
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
visibility sample each.

## Debugging

- `DebugDraw.probe_volumes(scene, rgba)` draws each visible volume's box and a small cross per
  probe; a 32 x 32 x 32 volume exceeds the default line sink, which drops the rest silently.
- The targets panel lists `probe irradiance N` and `probe visibility N` for every live atlas;
  visibility previews show the mean distance over the panel's depth range.
- The scene panel's inspector edits every field.

## Example

`examples/probe_volume` lights Sponza from one environment-filled volume. Its controls hide the
volume node (the SH term returns) and toggle the probe crosses; the targets panel shows both
atlases. `--deferred` uses the deferred shading path.

```bash
python3 scripts/fetch_benchmark_assets.py
python3 scripts/build.py --example probe_volume
```

`gltf_viewer --benchmark` takes `--probe-volumes 0|1|8` and `--probe-counts X,Y,Z` (default
16,8,8) to measure the shading cost: 1 places one volume over the model bounds, 8 one per octant.
