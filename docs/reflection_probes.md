# Reflection probes

A reflection probe lights the specular reflections of surfaces inside an oriented box from a cube
environment. The component is `light::ReflectionProbe`; its `environment` names an
[environment](environments.md) whose filtered cube the renderer samples. Diffuse light, the path
tracer, probe-volume updates and ray misses never read a reflection probe; diffuse light from a grid
of probes is described in [probe volumes](probe_volumes.md).

The cube comes from the application (any environment) or from `Renderer.capture_reflection_probe`,
which renders the scene around the probe.

## Workflow

```c3
Node* probe_node = scene.add_node(name: "living_room_probe")!;
probe_node.local.position = { 0, 1.5f, 0 };
ReflectionProbe probe = light::reflection_probe({ 3, 1.5f, 3 }, {});
probe.capture_offset = { 0, -0.3f, 0 };
scene.add(probe_node, probe);
scene.update_world();

EnvironmentId captured = renderer.capture_reflection_probe(&scene, probe_node)!;
scene.get(probe_node, ReflectionProbe).environment = captured;
renderer.upload_environment(captured)!;
renderer.prepare_scene(&scene)!;
```

1. Place the node at the box centre and size `half_extents` to the interior. The node's rotation orients
   the box; its scale is ignored.
2. Capture outside a frame, assign the returned id and prepare. The renderer writes no component or
   node data; recording updates only batch aggregates.
3. Move the node or change the room, then call `recapture_reflection_probe(&scene, probe_node)`. It
   keeps both the environment and the texture ids.

`reflection_probe(half_extents, environment)` returns a `BOX` probe with `blend_distance` 0.5, unit
intensity and the capture point at the node. `reflection_probe_valid` reports whether the renderer can
read a component: finite positive half extents, a capture offset strictly inside the box on every axis,
and finite nonnegative `blend_distance` and `intensity`. A zeroed `ReflectionProbe` is not valid; the renderer requires `light::reflection_probe_valid`.

## Placement and capture point

The capture point is `node position + rotation * capture_offset`. Place it where a viewer stands, away
from large reflective or emissive objects near the centre. The box is the region the probe lights; it
need not match the room exactly, but a point outside every box reads the global environment.

## Overlap and edges

A view gathers every visible probe on a layer of the camera that names a live environment, keeps the 16
nearest to the camera, and sorts them by `priority` (higher first), then box volume (smaller first), then
entity index. At each shaded point the first box that contains it lights the point, the second fades in
under it, and later boxes are not read. The shares of the two probes and the global environment sum to
one; without a global environment the global share is zero specular.

`blend_distance` is the inward fade at every face. The weight is the distance to the nearest face over
`blend_distance`, clamped to one. With 0 the edge is hard and the first box that contains the point
supplies all its light. A blend wider than the smallest half extent is clamped to it. Near a face a point
reads two cubes; keep the fade only as wide as the seam needs.

Without a global environment, a point outside every box and the fade band at the edge of a lone probe
receive no specular for the share the missing environment would have supplied. In a scene without a global
environment, set a global environment or `blend_distance = 0` so a probe does not fade to black at its faces.

## Projection

| Projection | Use |
| --- | --- |
| `BOX` | Interiors: the reflected direction is intersected with the box and aimed from the capture point |
| `INFINITE` | Far surroundings: the world direction samples the cube unchanged |

Rough lobes are not distance-corrected. Cubes are world-aligned: an authored cube does not turn with its
node, and the box axes turn only the volume and the projection.

## Lobes

Every positional environment-specular lookup selects once per pixel and re-aims its own direction through
each selected probe: Standard and Physical base specular, clearcoat, sheen (through the probe's own
Charlie cube) and the transmission fallback. Forward and deferred views, custom stages that call
`shade_standard_surface` or `evaluate_environment`, and the shading of traced reflection hits all apply
probes. Toon has no environment specular.

A traced reflection replaces the probe term on smooth pixels, the probe term remains above
`max_reflection_roughness`, and the two mix over the top fifth of the threshold, so no specular is counted
twice ([reflections](reflections.md)).

A probe's sheen cube is built the first time a view contains a sheen material, like the global one;
until then no draw has sheen. That first use stalls for about the prefilter cost.
`Renderer.prepare_scene` prepares every probe environment and its sheen cube, which avoids the stall.

## What a capture sees

A capture renders six forward frames of 90 degrees from the capture point at `LINEAR_HDR`, with no
anti-aliasing or post processing, then waits and copies them into the cube.

- Seen: shadows from every shadowing light, the global environment and background, the atmosphere sky and
  its aerial perspective, probe volumes and every other reflection probe.
- Not seen: the probe being captured, ambient occlusion, screen-space indirect light, traced effects,
  volumetric fog and `HeightFog`. A static cube would freeze the fog the capture point saw and leave every
  probe stale after each fog edit; the sky and aerial perspective are one fog pass, so the aerial
  perspective stays.
- Frames run at time 0: sway, water waves and animated custom stages are captured at time 0.

`ReflectionCaptureDesc` sets the face edge (`size`, a power of two from
`asset::MIN_ENVIRONMENT_SPECULAR_SIZE` to `MAX_REFLECTION_CAPTURE_SIZE`; default
`DEFAULT_REFLECTION_CAPTURE_SIZE`), the depth range and the layers the faces render.
`Renderer.last_reflection_capture` holds the time and bytes of the last capture.

Both entry points need an unopened frame. A capture checks the node, the component, the description, the
key and the free store, view and target slots before it creates anything; a fault leaves the store, the
frame index and an existing cube unchanged.

## Invalidation and removal

Captures are static. A moved node moves its box and capture point but not its cube; a changed light or
global environment leaves captures stale. Nothing marks staleness; call `recapture_reflection_probe`.

A re-capture at the same size rewrites the cube in place. The next preparation re-uploads the texture and
re-filters the environment without a new GPU allocation. It rewrites the cube the environment borrows, so
every probe that names that environment changes.

To remove a captured probe's assets, read `assets.environment(id).desc.source`, then call
`remove_environment(id)` and `remove_texture(source)`, in that order. A probe whose environment was
removed is skipped and counted in `Stats.dangling_refs`; removing the component or the node removes the
probe from every view.

## Capacity and memory

Per probe:

| Face size | Source cube (GPU) | GGX cube | SH buffers | Charlie cube (sheen only) | CPU copy | Capture readback (temporary) |
| --- | --- | --- | --- | --- | --- | --- |
| 128 | 768 KiB | 1,023.75 KiB | 18 KiB | 1,023.75 KiB | 768 KiB | 768 KiB |
| 256 | 3 MiB | 4.0 MiB | 18 KiB | 4.0 MiB | 3 MiB | 3 MiB |
| 1024 | 48 MiB | 64.0 MiB | 18 KiB | 64.0 MiB | 48 MiB | 48 MiB |

- A resolved probe holds 38 texture heap slots, 75 with a Charlie cube, of the 4,096-slot heap. Only probes a
  renderer has resolved hold cubes and slots.
- Each probe takes one environment and one texture record from the asset store. Raise
  `AssetStoreDesc.max_environments` (default 16, shared with authored environments) for more than 15 probes
  beside a global environment.
- A view packs 1,552 bytes of frame upload ring for the probe set and allocates nothing else per frame.
- `assets.release_texture_cpu(source)` frees the CPU copy once the renderer has prepared the probe. A
  renderer created afterwards cannot upload that probe and counts it in `Stats.reflection_probes_unavailable`;
  it still takes one of the 16 nearest slots. A re-capture restores the copy.

## Stats and debugging

| Counter | Meaning |
| --- | --- |
| `Stats.reflection_probes_dropped` | This frame, per view: probes past the nearest 16 |
| `Stats.reflection_probes_unavailable` | This frame, per view: probes whose CPU copy was released before this renderer uploaded them |
| `Stats.dangling_refs` | Includes probes whose environment is dead |

`DebugDraw.reflection_probes(scene, rgba)` draws each visible probe's oriented box and a cross at its capture
point. `gui::scene_panel` edits the component through the inspector, and `gui::reflection_capture_buttons`
adds "Capture new" and "Re-capture" for the selected probe. "Capture new" keeps the previous environment and texture
in the store, so repeated presses fill the environment pool (`max_environments`) and then fault with
`CAPACITY_EXCEEDED`; remove the old assets first or use "Re-capture". The `targets_panel` previews a probe's cube when
given its environment id.

## Example

`python3 scripts/build.py --example reflection_probes` builds and runs two rooms with a probe each: warm and
cool walls and lamps, a window in the cool room, a glossy floor across both, rows of metal spheres from
roughness 0 to 1, and a clearcoat and a sheen sphere. Flags: `--deferred`; `--reflections` (deferred view with
traced reflections); `--gpu-timings`; `--capture-size N`; `--validation`; `--benchmark [--frames N]`, which
renders headless at 2560 by 1440 and prints each capture's time, the first frame's `environment.prefilter` and
`environment.irradiance` stage times, and the mean GPU time of the pass that samples the probes
(`Pass.FORWARD_OPAQUE` forward, `Pass.LIGHTING` deferred). GPU times need the profiling build used for `sky`:

```bash
c3c build reflection_probes --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL
```

`gltf_viewer --benchmark` adds probes over the model bounds with `--reflection-probes 0|1|2|16` and
`--reflection-probe-placement inside|outside`; see [benchmarking](benchmarking.md).

## Measured cost

Measured on an RTX 4090, three runs each. Sampling runs Sponza at 2560 by 1440; capture runs the example. The
commands are in [benchmarking](benchmarking.md) and the example section above.

| Measurement | Result |
| --- | --- |
| Sampling, `gpu_opaque_ms` with 0, 1, 2 and 16 probes, and 16 probes with none inside | not yet recorded |
| Sampling, `gpu_lighting_ms` with the same placements, deferred | not yet recorded |
| Capture time per probe, steady (the second probe) | 4.6 to 5.8 ms at 128; 17 to 19 ms at 256 |
| Capture time of the first probe in a run, with first-use pipeline creation | 59 to 61 ms at 128 (839 ms on a cold first run); 56 to 64 ms at 256 |
| First-frame `environment.prefilter`, two probes | 1.00 to 1.07 ms at 128; 4.0 to 4.4 ms at 256 |
| First-frame `environment.irradiance`, two probes | 0.017 ms at 128; 0.045 to 0.047 ms at 256 |
| The example's forward opaque pass | 0.17 to 0.20 ms at both sizes |

The profiler sums stage times over a frame, so the environment rows cover both probes.
