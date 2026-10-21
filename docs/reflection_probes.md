# Reflection probes

A reflection probe lights the specular reflections of surfaces inside an oriented box from a cube environment. The
component is `light::ReflectionProbe`; its `environment` names an [environment](environments.md) whose filtered cube the
renderer samples. The cube comes from the application (any environment) or from `Renderer.capture_reflection_probe`, which
renders the scene around the probe. Diffuse light, the path tracer, probe-volume updates and ray misses never read a
reflection probe. Diffuse light from a grid of probes is in [probe volumes](probe_volumes.md).

## Quick start

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

1. Place the node at the box center and size `half_extents` to the interior. The node's rotation orients the box; its scale
   is ignored.
2. Capture outside a frame, assign the returned id and prepare. The renderer writes no component or node data.
3. Move the node or change the room, then call `recapture_reflection_probe(&scene, probe_node)`. It keeps both the
   environment and the texture ids.

## Concepts

- **Box.** The probe lights every shaded point inside its oriented box. `reflection_probe(half_extents, environment)`
  returns a `BOX` probe with `blend_distance` 0.5, unit intensity and the capture point at the node.
- **Capture point.** `node position + rotation * capture_offset`. Place it where a viewer stands, away from large
  reflective or emissive objects near the center. A point outside every box reads the global environment.
- **Projection.** `BOX` intersects the reflected direction with the box and aims it from the capture point, for interiors.
  `INFINITE` samples the cube with the world direction unchanged, for far surroundings. Rough lobes are not
  distance-corrected. Cubes are world-aligned: an authored cube does not turn with its node.
- **Static captures.** A capture is a snapshot. A moved node moves its box and capture point but not its cube, and a changed
  light or global environment leaves captures stale. Nothing marks staleness; call `recapture_reflection_probe`.
- **Validity.** `reflection_probe_valid` reports whether the renderer can read a component: finite positive half extents, a
  capture offset strictly inside the box on every axis, and finite nonnegative `blend_distance` and `intensity`. The renderer
  requires a valid component. A zeroed `ReflectionProbe` is not valid.

## Overlap and edges

A view gathers every visible probe on a layer of the camera that names a live environment, keeps the 16 nearest to the
camera (`REFLECTION_PROBE_CAPACITY`), and sorts them by `priority` (higher first), then box volume (smaller first), then
entity index. At each shaded point the first box that contains it lights the point, the second fades in under it, and later
boxes are not read. The shares of the two probes and the global environment sum to one. Without a global environment the
global share is zero specular.

- `blend_distance` is the inward fade at every face: the distance to the nearest face over `blend_distance`, clamped to
  one. With 0 the edge is hard. A blend wider than the smallest half extent is clamped to it. Near a face a point reads two
  cubes, so keep the fade only as wide as the seam needs.
- Without a global environment, the fade band at the edge of a lone probe and any point outside every box receive no
  specular for the share the missing environment would have supplied. Set a global environment or `blend_distance = 0` so a
  probe does not fade to black at its faces.

## Capture and re-capture

`capture_reflection_probe(&scene, probe_node, desc, key)` renders six forward frames of 90 degrees from the capture point at
`LINEAR_HDR`, with no anti-aliasing or post processing, waits, and copies them into a new store-owned cube environment.
`recapture_reflection_probe(&scene, probe_node, desc)` renders into the cube the probe's environment already borrows.

- **Seen:** shadows from every shadowing light, the global environment and background, the atmosphere sky and its aerial
  perspective, probe volumes and every other reflection probe.
- **Not seen:** the probe being captured, ambient occlusion, screen-space indirect light, traced effects, volumetric fog and
  `HeightFog`. A static cube would freeze the fog the capture point saw and leave every probe stale after each fog edit.
- **Time.** Frames run at time 0: sway, water waves and animated custom stages are captured at time 0.
- **Description.** `ReflectionCaptureDesc` sets the face edge in texels (`size`, a power of two from
  `asset::MIN_ENVIRONMENT_SPECULAR_SIZE` to `MAX_REFLECTION_CAPTURE_SIZE`; default `DEFAULT_REFLECTION_CAPTURE_SIZE`), the
  `near` plane (positive), the `far` plane (0 is infinite, else beyond `near`) and the `layers` the faces render.
  `Renderer.last_reflection_capture` holds the time and bytes of the last capture.
- **Frame state and faults.** Both entry points need an unopened frame. They fault `INVALID_ID` for a dead node,
  `INVALID_ARGUMENT` for a node without a probe, an invalid probe or description or a rejected key, `CAPACITY_EXCEEDED` for a
  full store, view or target pool, and the gpu faults of rendering six frames. A fault leaves the store, the frame index and
  an existing cube unchanged.

A re-capture at the same size rewrites the cube in place. The next preparation re-uploads the texture and re-filters the
environment without a new GPU allocation. Every probe that names that environment changes.

To author a cube yourself, register any cube [environment](environments.md) and assign it to `ReflectionProbe.environment`.

## Lobes that use probes

Every positional environment-specular lookup selects once per pixel and re-aims its own direction through each selected
probe: Standard and Physical base specular, clearcoat, sheen (through the probe's own Charlie cube) and the transmission
fallback. Forward and deferred views, custom stages that call `shade_standard_surface` or `evaluate_environment`, and the
shading of traced reflection hits apply probes. Toon has no environment specular.

A traced reflection replaces the probe term on smooth pixels; see [reflections](reflections.md#lighting).

A probe's sheen cube is built the first time a view contains a sheen material, and that first use stalls for about the
prefilter cost. `Renderer.prepare_scene` prepares every probe environment and its sheen cube, which avoids the stall.

## Remove probe assets

Read `assets.environment(id).desc.source`, then call `remove_environment(id)` and `remove_texture(source)`, in that order.
A probe whose environment was removed is skipped and counted in `Stats.dangling_refs`. Removing the component or the node
removes the probe from every view.

## Capacity and counters

| Face size | Source cube (GPU) | GGX cube | Charlie cube (sheen only) | CPU copy and capture readback |
| --- | --- | --- | --- | --- |
| 128 | about 1 MiB | about 1 MiB | about 1 MiB | 768 KiB each |
| 256 | 4 MiB | 4 MiB | 4 MiB | 3 MiB each |
| 1024 | 64 MiB | 64 MiB | 64 MiB | 48 MiB each |

- The source cube keeps its full mip chain, which the prefilters read: 1.33 times its base level. The CPU copy holds the base
  level only, and the readback is temporary.
- A resolved probe holds 38 texture heap slots, 75 with a Charlie cube. Only probes a renderer has resolved hold cubes and
  slots.
- Each probe takes one environment and one texture record from the asset store. Raise `AssetStoreDesc.max_environments`
  (default 16, shared with authored environments) for more than 15 probes beside a global environment.
- `assets.release_texture_cpu(source)` frees the CPU copy once the renderer has prepared the probe. A renderer created
  afterwards cannot upload that probe and counts it in `Stats.reflection_probes_unavailable`. A re-capture restores the copy.
- `Stats.reflection_probes_dropped` counts, per view and frame, probes past the nearest 16. `Stats.dangling_refs` includes
  probes whose environment is dead.

## Debug probes

- `DebugDraw.reflection_probes(scene, rgba)` draws each visible probe's oriented box and a cross at its capture point.
- `gui::scene_panel` edits the component. `gui::reflection_capture_buttons` adds "Capture new" and "Re-capture" for the
  selected probe. "Capture new" keeps the previous environment and texture in the store, so repeated presses fill the
  environment pool and then fault with `CAPACITY_EXCEEDED`; remove the old assets first or use "Re-capture".
- `gui::targets_panel` previews a probe's cube when given its environment id.

Run `python3 scripts/build.py --example reflection_probes` for two rooms with a probe each. It takes `--deferred`,
`--reflections`, `--capture-size N` and `--benchmark`. `gltf_viewer --benchmark` adds probes with `--reflection-probes`; see
[benchmarking](benchmarking.md).

## Limits

- A view reads the 16 nearest probes and blends at most two boxes at a point.
- Probes carry specular only. Captures are static.

## See also

- [Reflections](reflections.md) for traced reflections that replace the probe term on smooth pixels.
- [Environments](environments.md) for the environment asset and its pool limits.
- [Probe volumes](probe_volumes.md) for diffuse indirect light.
- [Lighting techniques](lighting_techniques.md) for choosing between effects.
