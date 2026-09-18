# Many lights

`many_lights` compares flat and clustered Forward+ lighting on the same view. The scene
is a procedural 40 × 64 hall: a floor, three walls and 40 pillars share box geometry and
an opaque Standard material. Colored, finite, unshadowed point lights are static between
workload edits; their arrangement is deterministic. There are no external scene assets.
Only this example raises the renderer light budget to 4096.

## Launch

Run from the repository root with the platform's compiler and native dependencies installed.
Full Vulkan validation is enabled in both modes; GPU timestamps are opt-in.

Linux / WSL:

```bash
python3 scripts/build.py --target many_lights --opt O3
./examples/build/many_lights
./examples/build/many_lights --gpu-timings
```

Native Windows PowerShell:

```powershell
python scripts/build.py --target many_lights --opt O3
.\examples\build\many_lights.exe
.\examples\build\many_lights.exe --gpu-timings
```

These are separate platform runs, not interchangeable performance evidence. The example
has no benchmark CLI or automatic sweep; `--gpu-timings` is its only command-line option.

## Controls and diagnostics

The initial workload is 256 lights with range 6. The view starts clustered with the
constructor preset: 16 × 9 × 24 cells, capacity 64 per cell, far distance 100.

- **Many lights:** choose 64, 256, 1024 or 4096 lights; adjust finite light range from
  1 to 32; choose cell capacity 1, 16, 64 or 256. Count changes reposition the active
  lights deterministically; range changes do not move them. Capacity is a storage limit,
  not a light-selection budget. Changes are applied between renderer frames.
- **Targets:** switch Flat/Clustered without changing the scene or camera. Deferred is
  disabled. Choose `Cluster slice` and expand `clusters` for its occupancy heatmap.
- **Camera:** left-drag to orbit and use the wheel to zoom. GUI mouse capture suppresses
  these actions. `Reset camera` restores the same orbit and perspective lens for each
  comparison. Releasing Escape quits unless the GUI captured that key interaction;
  native window close remains available.
- **Statistics:** requested lights appear beside selected and dropped totals. Workload
  edits are immediate, but rendering counters shown before the next frame can lag them.
  The panel also reports wall interval, working extent, framebuffer size and actual
  presentation mode. Cluster counters and optional GPU times are delayed completed results.

Capacity 1 with overlapping lights deliberately exercises overflow. The heatmap excludes
all global lights: blue is empty, red is full, intermediate occupancy adds green, and
magenta is overflow. It shows one selected depth slice, not the cells occupied by visible
surfaces. Slice labels are camera-depth bounds from the last matching render; lighting
mode, depth-slice or far-distance changes invalidate labels until new data is rendered.
An inactive grid has no available depth labels or occupancy image.

## Selection behavior

Clustering changes candidate lookup, not the accepted scene-light budget, receiver masks,
shadow mapping or BRDF. Finite point/spot lights use conservative range spheres. Directional
and range-zero lights are globals evaluated once. A cell that overflows, a shaded position
outside the grid or its finite depth interval, and inactive coverage all use the complete
flat light list. Small capacity therefore trades potential savings for fallback; it does
not intentionally remove light contributions.

Standard, Toon and non-transmitting Physical materials use the selector, including ordinary
blended surfaces. Active Physical transmission keeps its entire direct-light loop flat
because exit-point lighting can lie outside the surface cell. Existing custom shaders
remain flat unless they opt into the shared `LightList` helpers. See
[views](views.md#light-selection) for configuration, validation and buffer lifetime, and
[custom shaders](custom_shaders.md#light-selection) for opt-in compatibility.

## Comparing costs

Keep light count, range, capacity, camera, working extent and material settings identical
when changing only Flat/Clustered. Reset the camera, allow pipeline/configuration warmup,
and wait for completed counters to settle. Close heatmaps and other previews for the main
comparison; record a separate diagnostic run with them open. Collect several separated
steady-state observations rather than one transient FPS value.

The timing displays measure different intervals:

| Display | Meaning |
| --- | --- |
| Wall interval | Window clock delta between loop ticks; includes application work, GUI, rendering and pacing |
| Stats `Frame` | Renderer CPU-side frame interval through submission/presentation; not the whole application loop |
| Stats `CPU record` | Renderer CPU interval through submission, before presentation; not isolated GPU work |
| Completed GPU opaque | Timestamped opaque pass from a completed frame slot |
| Completed GPU light cull | Private light upload/reset, cluster assignment and counter copy from a completed slot |

The renderer's CPU clock starts after frame-slot completion/readback processing, so neither
CPU timing row includes that initial wait. Wall interval can expose pacing those rows omit.

GPU times require `--gpu-timings`. Completed cluster view/count/overflow counters do not:
they are read after a frame slot's normal completion wait, with no synchronous readback
inside `render_view`. With multiple views, they describe the slot's last recorded drawable
view rather than an aggregate; a later flat view clears the cluster result. See
[GUI diagnostics](gui.md#cluster-diagnostics).

The example requests immediate presentation, but the **Presentation** label reports the
mode actually obtained. FIFO fallback or compositor pacing can dominate wall intervals;
neither proves GPU throughput. Timestamp instrumentation can add substantial overhead,
particularly on WSL/dzn, so compare timestamp-disabled wall intervals too. Do not subtract
a presumed fixed timestamp cost or count opaque-pass savings alone as total improvement.
Dense overlap and overflow fallback can eliminate an advantage.

For each comparison record platform, source/dependency/compiler/driver/backend versions,
validation and timestamp settings, actual presentation mode and working extent, camera
pose, light count/range, grid/capacity/far settings, selected/dropped lights and completed
overflows. Report cull and opaque times alongside wall and CPU observations. This guide
makes no claim of a universal speedup or a light-count crossover threshold.
