# Many lights

`many_lights` compares flat and clustered Forward+ lighting on the same view. The scene
is a procedural 40 × 64 hall: a floor, three walls and 40 pillars share box geometry and
an opaque Standard material. Colored, finite, unshadowed point lights are static between
workload edits; their arrangement is deterministic. There are no external scene assets.
Only this example raises the renderer light budget to 4096.

## Launch

Run from the repository root with the platform's compiler and native dependencies installed.
Full Vulkan validation is enabled in the interactive example; GPU timestamps are opt-in.

Linux / WSL:

```bash
python3 scripts/build.py --target many_lights --opt O3
./examples/build/many_lights
c3c build many_lights --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL -O3
./examples/build/many_lights --gpu-timings
```

Native Windows PowerShell:

```powershell
python scripts/build.py --target many_lights --opt O3
.\examples\build\many_lights.exe
c3c build many_lights --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL -O3
.\examples\build\many_lights.exe --gpu-timings
```

These are separate platform runs, not interchangeable performance evidence. For a fixed
headless workload, add `--benchmark`; see [Benchmarking](benchmarking.md) for options,
automatic sweeps, CSV fields and measurement limits. Benchmark mode disables validation
by default and accepts `--validation` for a separate correctness run, `--capture` to run
a profiler capture around every frame, `--window` for a presented run, `--panel` to draw
the profiler panel, and `--print-features` to report the compiled profiling features.

## Controls and diagnostics

The initial workload is 256 lights with range 6. The view starts clustered with the
constructor preset: 16 × 9 × 24 cells, capacity 64 per cell, far distance 100.

- **Many lights:** choose 64, 256, 1024 or 4096 lights; adjust finite light range from
  1 to 32; choose cell capacity 1, 16, 64 or 256. Count changes reposition the active
  lights deterministically; range changes do not move them. Capacity is a storage limit,
  not a light-selection budget. Changes are applied between renderer frames.
- **Depth pruning:** a checkbox for `ClusterDesc.depth_pruning`; see [depth pruning](#depth-pruning).
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
all global lights: blue is empty, red is full, intermediate occupancy adds green,
magenta is overflow and dark grey is a cell [depth pruning](#depth-pruning) skipped. It shows
one selected depth slice, not the cells occupied by visible surfaces. Slice labels are
camera-depth bounds from the last matching render; lighting mode, depth-slice or
far-distance changes invalidate labels until new data is rendered. An inactive grid has no
available depth labels or occupancy image.

## Selection behavior

Clustering changes candidate lookup, not the accepted scene-light budget, receiver masks,
shadow mapping or BRDF. Finite point/spot lights use conservative range spheres. Directional
and range-zero lights are globals evaluated once. A cell that overflows or that
[depth pruning](#depth-pruning) skipped, a shaded position outside the grid or its finite
depth interval, and inactive coverage all use the complete flat light list. Small capacity
therefore trades potential savings for fallback; it does not intentionally remove light
contributions.

Standard, Toon and non-transmitting Physical materials use the selector, including ordinary
blended surfaces. Active Physical transmission keeps its entire direct-light loop flat
because exit-point lighting can lie outside the surface cell. Existing custom shaders
remain flat unless they opt into the shared `LightList` helpers. See
[views](views.md#light-selection) for configuration, validation and buffer lifetime, and
[custom shaders](custom_shaders.md#light-selection) for opt-in compatibility.

## Spatial light lookup

Cluster construction can build a private BVH over the final packed finite point/spot ranges.
A private admission check keeps small or widely overlapping lists on the complete flat
construction path. For admitted lists, the workgroup rejects node boxes against the cell
planes, then applies the existing sphere admission test to every selected leaf light. Indices still name the original packed array.
Globals remain separate, and an overflowing cell retains its complete flat fallback.

Reflection hits, path bounces and scene-probe hits use a point cursor over a separate BVH
for their own no-frustum light list. They visit every candidate and evaluate each global
once. Raster FLAT selection, the public `LightList` helpers, transmitting Physical raster
lighting and the fog selector retain their existing behavior.

Each list's nodes, index map, globals and root occupy immutable frame-upload storage.
They are rebuilt from that rendering's accepted lights; no scene cache or additional light
budget is introduced. Empty/all-global lists use the flat path. Subnormal squared ranges
and nonfinite derived bounds or builder arithmetic also use the complete flat path. Upload
and device failures retain their ordinary fault propagation.

## Depth pruning

`ClusterDesc.depth_pruning` (off by default) lets the cull skip cells that no opaque surface
can occupy. Before the cull the view reduces its depth image to one value per cluster tile:
the farthest view depth of the tile's pixels, or unbounded when any of them shows no
geometry. A cell whose near boundary lies beyond that value is not assigned lights or decals.
It is written as an empty overflowing range and counted in the completed `cluster_skipped`
counter, which is not part of `cluster_overflows`. Shading is unchanged: an overflowing cell
already selects the complete flat list, so any point that reaches a skipped cell receives
every light and decal. Opaque surfaces do not lie in skipped cells. Fog froxels and draws
without a depth test, behind the farthest opaque depth of their tile, do; they differ from
an unpruned view only in the order the same lights are summed.

Limits:

- Only the far side is pruned. Cells in front of the nearest surface of a tile keep their
  lists, because fog froxels and blended surfaces read them.
- A tile with a single background pixel (sky, or depth cleared and never drawn) is never
  pruned, so open horizons prune little. The savings are the cells behind the visible
  geometry of each tile.
- The reduction reads the depth image once and adds a dispatch and a barrier to `LIGHT_CULL`.
  Compare the completed `LIGHT_CULL` time with the setting off.
- Pruning needs depth before any pass reads the cell lists. A forward view with no depth
  prepass (and no ambient occlusion or screen-space GI, each of which implies one) ignores
  the field without a fault, and so does a forward view with traced reflections: its thin
  reflection prepass is both the depth producer and a reader of the decal lists. Deferred
  views always have depth.
- On a pruned view the reduction, the cull and the [volumetric fog](sky.md#volumetric-fog)
  volume are recorded after the depth prepass instead of before every other pass: on a
  deferred view between the prepass and the G-buffer pass, whose stages read the decal lists.
- The reduction maps pixels to tiles as cluster selection does, from the unjittered view.
  Under TAA a pixel within half a pixel of a tile edge can shade with the neighbouring tile's
  lists; when that tile's bound is nearer, the point takes the complete flat list.
- The tile bounds take 4 bytes per tile (576 bytes at the default grid) in the view's cluster
  buffer, reserved with pruning on or off.

The benchmark flag is `--depth-pruning on|off` (off by default). Keep the camera fixed when
comparing: the effect depends on how much of the grid lies behind the visible geometry.

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
| Completed GPU light cull | Private light upload/reset (an unpruned view only), the tile-depth reduction (a pruned view only), cluster assignment and counter copy from a completed slot |

The renderer's CPU clock starts after frame-slot completion/readback processing, so neither
CPU timing row includes that initial wait. Wall interval can expose pacing those rows omit.

GPU times require `--gpu-timings` and a [profiling-enabled build](profiling.md#capture-gpu-work). Completed cluster view/count/overflow counters do not:
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
