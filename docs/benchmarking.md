# Benchmarking

Build with the pinned dependencies and C3 0.8.3. `-O3` enables C3's unsafe release
mode; comparisons must use the same optimization and safety settings.

```bash
python3 scripts/build.py --target cpu_bench --opt O3
python3 scripts/build.py --target many_lights --opt O3
python3 scripts/build.py --test
```

Run suites serially on an otherwise idle machine. The runner preserves raw CSV,
commands, stderr, process-level summaries, source/dependency revisions, compiler,
binary hash and environment metadata. Each output directory must be new. Repeats
launch independent processes and reverse the workload order on alternate sweeps.
`--build` builds the selected target with `-O3`; otherwise record the build flags
alongside the output. `--binary` selects an alternative build for experiments.

## CPU extraction and transforms

```bash
python3 scripts/benchmark.py cpu --output results/cpu --repeats 3
./examples/build/cpu_bench meshes 4096 100 30
```

On Linux, optionally add `--cpu 2` to pin the runner and its children to an available
logical CPU. Do not pin a software Vulkan driver when comparing it with unpinned
results. The default sweep uses 1,024, 4,096 and 16,384 nodes; `--nodes` and `--cases`
select a smaller sweep.

| Case | Work inside each timed iteration |
| --- | --- |
| `world` | Update every node's world matrix |
| `hidden_world` | The same update with all mesh nodes hidden |
| `meshes` | Extract visible mesh candidates, including transformed bounds and frustum tests |
| `culled_meshes` | The same extraction with every mesh outside the frustum |
| `hidden_meshes` | The same extraction with every mesh hidden |
| `shadows` | Extract shadow candidates without camera-frustum filtering |
| `lights` | Extract and pack visible unshadowed point lights |
| `hidden_lights` | The same light extraction with every light hidden |
| `sort` | Extract candidates and sort them with the transparent comparator |

Nodes are flat children of the root with deterministic positions. Meshes share a
box geometry and material. The orthographic camera encloses the ordinary mesh
workload. These cases measure individual library operations without creating a GPU
device. They do not simulate animation, deep hierarchies, asset streaming or an
entire renderer frame. `sort` is a candidate-sort stress case; the actual renderer
sorts a different, private draw-item structure.

Allocation and temporary-pool cleanup are inside the timed extraction call. Scene
and asset setup are outside it. Five warmup batches precede measured batches;
defaults are 30 batches of 100 iterations. A consumed checksum prevents removal of
the measured work. CSV is written after measurement. `us_per_iteration` is the
batch average; its p95 describes batch averages, not individual-frame latency.

For instruction attribution with Valgrind installed:

```bash
valgrind --tool=callgrind --collect-atstart=no \
  '--toggle-collect=*run_iteration*' --callgrind-out-file=callgrind.meshes \
  ./examples/build/cpu_bench meshes 4096 10 3
callgrind_annotate --inclusive=no callgrind.meshes
```

The collection filter excludes scene setup and CSV output but includes warmup
iterations. Check that the instruction total is nonzero. Instruction shares and
Valgrind elapsed times are not native CPU-time shares or speedup measurements;
confirm a candidate change with independent native runs and matching output.

### Scene index and triangle trees

```bash
./examples/build/cpu_bench index_refresh_crowd 1 10 300
./examples/build/cpu_bench index_refresh_batch 1 10 300
./examples/build/cpu_bench index_build_crowd 1 10 30
./examples/build/cpu_bench index_build_batch 1 10 30
./examples/build/cpu_bench index_pick_crowd 1 10 30
./examples/build/cpu_bench scan_pick_crowd 1 10 30
./examples/build/cpu_bench index_pick_triangles 1 10 30
./examples/build/cpu_bench scan_pick_triangles 1 10 30
./examples/build/cpu_bench triangle_warmup 128 2 30
./examples/build/cpu_bench triangle_warmup 362 1 10
```

Build with `--opt O3` for readings. The crowd scene holds 2,000 unit-box mesh nodes on a
grid and one 4,096-instance batch (6,096 index entries); the batch scene holds one
65,536-instance batch. The scene cases ignore the `nodes` argument and print the entry
count in its column.

| Case | Work inside each timed iteration |
| --- | --- |
| `index_refresh_crowd`, `index_refresh_batch` | `SceneIndex.refresh` with nothing changed |
| `index_build_crowd`, `index_build_batch` | The tree build of the first pick after the entries changed, plus that one ray |
| `index_pick_crowd`, `scan_pick_crowd` | 64 fixed-seed rays at bounds precision through the index or `spatial::pick` |
| `index_pick_triangles`, `scan_pick_triangles` | The same rays at triangle precision, triangle trees built beforehand |
| `triangle_warmup` | `prepare_triangle_picks` on one plane mesh after `mark_geometry_dirty`; `nodes` is the plane segment count per side |

The pick cases checksum each ray's hit count and nearest node and instance, so an index
case and its scan case print equal checksums. `triangle_warmup` prints the tree's bytes
(`# triangle tree bytes`) after the CSV.

Readings on an Intel Core i9-14900K at O3 (medians; Windows host, WSL in parentheses):

| Case | Microseconds per iteration |
| --- | --- |
| `index_refresh_crowd` | 14.2 (15.3) |
| `index_refresh_batch` | 0.01 (0.011); a batch whose key changed recomputes and compares every instance, 1,244 (WSL) measured before the per-batch skip |
| `index_build_crowd` | 524 (505) |
| `index_build_batch` | 6,959 (6,354) |
| `index_pick_crowd` | 265 (260) |
| `scan_pick_crowd` | 11,429 (8,049) |
| `index_pick_triangles` | 283 (298) |
| `scan_pick_triangles` | 11,253 (8,061) |
| `triangle_warmup` 128 (32,768 triangles, 655,328 bytes) | 3,231 (3,210) |
| `triangle_warmup` 362 (262,088 triangles, 5,601,280 bytes) | 31,818 (32,278) |

### Traced effects in software and on ray queries

```bash
./examples/build/rt_shadows --gpu-timings --benchmark 300 --atlas-shadows
./examples/build/rt_shadows --gpu-timings --benchmark 300 [--software] [--twin-ground]
./examples/build/rt_effects --gpu-timings --benchmark 300 [--software]
./examples/build/gltf_viewer --benchmark --gpu-timings --frames 300 --warmup 60 --shading deferred \
    --ambient-occlusion ray-traced --reflections on --trace software|hardware --width 3840 --height 2160
./examples/build/gltf_viewer --benchmark --gpu-timings --frames 300 --warmup 60 --shading deferred \
    --shadows on|traced --trace software|hardware --width 3840 --height 2160
```

Build the three targets with `--opt O3 --define C3D_PROFILE_GPU --define C3D_PROFILE_INTERNAL --lib
c3d_profile`. `rt_shadows` and `rt_effects` benchmark at 1920x1080 and print pass means and the GPU frame
(the sum of the pass timestamps); `rt_shadows` reports the forward pass, where traced shadows cost, and
`--atlas-shadows` gives the base to subtract; `--twin-ground` draws the ground with the custom twin of its
Standard material, which shades through `standard_shading.glsl` and its traced forms, and the line names the
ground. `gltf_viewer` prints `first frame:` with the trace
preparation's CPU time and the acceleration builds' GPU time; `--shadows traced` traces the sun's shadow
(an `AUTO` run then creates the renderer with ray queries), and `--shadows on` keeps the atlas as its base.

Readings on an RTX 4090 (medians of 300 frames; GPU frame in parentheses):

| Run | Ray queries | Software walk |
| --- | --- | --- |
| `rt_shadows`, forward pass, atlas base | 0.051 (0.121) | 0.051 (0.120) |
| `rt_shadows`, forward pass, traced | 0.077 (0.159) | 0.213 (0.270) |
| `rt_effects` AO / reflections | 0.138 / 0.095 (0.509) | 0.414 / 0.603 (1.607) |
| Sponza 1080p AO / reflections | 0.270 / 0.160 (0.820) | 2.978 / 1.822 (5.184) |
| Sponza 2160p AO / reflections | 0.852 / 0.453 (2.364) | 9.181 / 5.400 (15.656) |
| Sponza first frame | 49.9 GPU acceleration builds, 0.6 CPU | 31.0 CPU (triangle trees and upload) |
| Sponza 2160p lighting pass, atlas sun shadow (base) | 0.464 (1.070) | 0.450 (1.038) |
| Sponza 2160p lighting pass, traced sun shadow | 0.789 (1.280) | 6.261 (6.768) |

Ratios are quoted only where both frames exceed 1 ms: at 2160p the software walk costs 10.8 times the ray
queries for AO, 11.9 times for reflections, and 17.9 times for the sun's traced shadow (5.81 against 0.325 ms of
lighting pass over the atlas base). The `rt_shadows` and `rt_effects` frames stay below 1 ms, so their figures carry
no ratio.

## Headless many-light rendering

```bash
python3 scripts/benchmark.py render --output results/render --repeats 3
./examples/build/many_lights --benchmark --mode clustered --lights 256 \
  --frames 300 --warmup 60 --capacity 64 --range 6 --width 1440 --height 900
```

This reuses the interactive example's hall, deterministic light placement and reset
camera. It renders a display-LDR texture without a window, GUI or presentation.
All 4,096 light nodes exist in every workload; inactive lights are hidden. Scene
world matrices are updated every frame, matching the interactive loop's policy.
The grid remains 16 × 9 × 24 with far distance 100. Warmup excludes initial pipeline
creation and first-use uploads from the reported samples; increase it if a target
driver has not reached steady state.

Benchmark mode disables validation and timestamps by default. Run a separate
correctness smoke with `--validation`, then collect ordinary timing without it.
The interactive example continues to enable validation. Add `--gpu-timings` for a
separate diagnostic run; timestamp instrumentation can change performance.

Further options select profiler work inside the same loop. Each one that needs a
compiled feature is rejected at parse time with the build recipe when the binary
lacks it, so an excluded mode never silently reports zero timings.

| Option | Needs | Effect |
| --- | --- | --- |
| `--capture` | `C3D_PROFILE_CPU` or `C3D_PROFILE_GPU` | Opens a `profile::@capture` with one `application.frame` scope around every frame, so library scopes and GPU capture run. Nothing is exported. |
| `--window` | nothing | Presents to a window with immediate present mode instead of an offscreen target, using the renderer's default view. Events are polled and ignored; closing the window ends the run with the rows collected so far. |
| `--panel` | `--window`, `--capture`, `C3D_PROFILE_GUI` | Draws the profiler panel every frame through the overlay and reports its cost as `gui_ms`. |
| `--print-features` | nothing | Prints `cpu=<0|1> gpu=<0|1> internal=<0|1> gui=<0|1>` and exits. |
| `--anti-aliasing none\|fxaa\|taa` | nothing | Selects the measured view's anti-aliasing filter (`benchmark.py --anti-aliasing`); FXAA by default. |
| `--depth-prepass on\|off` | nothing | Selects the forward measured view's depth prepass (`benchmark.py --depth-prepass`); on by default, as in the view constructors. Deferred views always run it. |
| `--ambient-occlusion none\|half\|full\|ray-traced` | `ray-traced`: a ray-query adapter | Selects the measured view's AO: screen space at half or full resolution, or ray traced at half resolution with 4 rays (`benchmark.py --ambient-occlusion`); none by default. The CSV reports it as `gpu_ambient_occlusion_ms`. |
| `--reflections on\|off` | a ray-query adapter and `--shading deferred` | Ray-traced reflections on the measured view (`benchmark.py --reflections`); off by default. A forward view faults `UNSUPPORTED`. The CSV reports it as `gpu_rt_reflections_ms`. |
| `--screen-space-gi on\|off` | nothing | [Screen-space GI](screen_space_gi.md) at the defaults on the measured view; off by default. The CSV reports it as `gpu_screen_space_gi_ms` and the colour copy as `gpu_ssgi_copy_ms`; a view with it records velocity every frame. |
| `--trace software\|hardware` | `hardware`: a ray-query adapter | Creates the renderer with (`hardware`) or without (`software`) ray queries; every trace consumer of the run, probe updates included, follows. The default is `hardware` exactly when `--reflections on` or `--ambient-occlusion ray-traced` is given; `software` runs those effects on the software walk. `software` with `--shading path-traced` (whose ray-tracing pipelines imply ray queries) is rejected as an invalid argument. The banner prints `trace=none\|software\|hardware` (`none`: the run traces nothing). With a traced effect on the command line the probe update of a `--probe-fill scene` row now runs on ray queries; earlier rows ran it in software beside a hardware view. |
| `--shading path-traced` | a ray-tracing-pipeline adapter | Path traces the measured view with the default settings (6 bounces, one sample per frame, no cap); the light mode is forced to flat. The CSV reports the trace as `gpu_path_trace_ms`; samples per second is width x height / `gpu_path_trace_ms` x 1000. |

The windowed run is a different workload from the headless one: the default view
carries the interactive example's settings and window-system pacing applies. Compare
windowed rows only with other windowed rows.

| CSV field | Interval or result |
| --- | --- |
| `wall_ms` | Scene update through submission, including frame-slot waiting |
| `update_ms` | `Scene.update_world` |
| `begin_ms` | `begin_frame`, including prior-slot completion, readbacks and cache sweeps |
| `render_ms` | `render_view`, including CPU extraction and command recording |
| `finish_ms` | `finish_view` |
| `end_ms` | `end_frame` submission, including presentation in windowed runs |
| `gui_ms` | Profiler panel draw and overlay recording; zero without `--panel` |
| `cpu_record_ms` | Existing renderer statistic; excludes the beginning wait/readback/sweep work |
| `gpu_*_ms` | Completed per-pass timestamps for shadow atlas, light culling, depth prepass, G-buffer, ambient occlusion, ray-traced reflections, path tracing, lighting resolve, forward opaque, post chain, composite, velocity, temporal resolve, probe update, acceleration builds, screen-space GI, its colour copy and instance culling (`gpu_instance_cull_ms`, last); `-1` when unavailable, zero for an omitted pass |
| `draws`, `lights`, `dropped` | Current-frame renderer counters |
| `overflows` | Completed cluster overflow count attributed to its submitted frame |
| `material_resolutions` | Fresh material dependency resolutions in the frame; one per material per view traversal |
| `pipeline_lookups` | Draw pipeline cache lookups in the frame; one per prepared draw item and shadow draw |

GPU results are read when the frame slot is reused and attached to the originating
row. Two additional frames drain the final measured slots. Sample storage is
allocated before the loop; CSV output follows completion. `wall_ms` measures
steady-state submission throughput with frames in flight, not isolated GPU latency.
The pass timestamps are partial intervals and should not be presented as total
frame time.

`--shading forward|deferred|path-traced` selects the view's shading path (`benchmark.py --shadings`);
job names carry the path first. Keep extent, camera, range, capacity and material fixed when
comparing flat and clustered modes or the two shading paths. Report overflow counts: overflow falls back to the complete flat
light list rather than dropping contributions. A useful correctness stress is:

```bash
./examples/build/many_lights --benchmark --mode clustered --lights 256 \
  --capacity 1 --range 32 --frames 10 --warmup 10 --validation --gpu-timings
```

On a machine without a physical GPU, software Vulkan can verify the path, but it
cannot establish hardware GPU speedups or a useful light-count crossover. Record
any driver-specific workarounds. Headless results also omit window-system pacing;
measure the interactive example separately when that is the question.

## Scene benchmark

```bash
python3 scripts/fetch_benchmark_assets.py
python3 scripts/build.py --target gltf_viewer --opt O3
python3 scripts/benchmark.py scene --output results/scene --repeats 3
./examples/build/gltf_viewer --benchmark --lights 64 --mode clustered --shadows on
```

The scene suite renders Crytek Sponza from `KhronosGroup/glTF-Sample-Assets`,
pinned to one commit by the fetch script and stored under
`examples/assets/benchmark/sponza/`, which is gitignored: the model files are
under the Cryengine Limited License Agreement and are not redistributed here.
The fetch skips files that already exist with the right size; `--force`
downloads everything again. `benchmark.py scene` refuses to run without the
model and prints the fetch command.

`gltf_viewer --benchmark` reuses the viewer's loading and environment: one
instance at the origin, the studio HDR as environment and background, a sun
that casts shadows unless `--shadows off` (`--shadows traced` traces them), and `--lights N` point lights on a
deterministic grid inside the model bounds at 0.35 of the vertical extent, with
`--range R` as a fraction of the largest horizontal extent (default 0.08). The
camera sits inside the atrium at 0.3 of the height, 0.35 of the long axis behind
the center, looking along the long axis. `--mode`, `--capacity` and every common
option (`--frames`, `--warmup`, `--width`, `--height`, `--gpu-timings`,
`--validation`, `--capture`, `--window`, `--panel`, `--print-features`) behave as
in `many_lights --benchmark`, and the CSV columns are the same. Shadow casting
dominates the draw count: about 470 draws with the sun shadowed against about 85
without.

`--probe-volumes 0|1|8` adds probe volumes (one over the model bounds, or one per octant) with
`--probe-counts X,Y,Z` probes each (default 16,8,8), filled from the environment or, with
`--probe-fill scene`, traced every frame (`--probe-window N` probes per update, 0 for all);
`--point-shadows on` enables shadows on the point lights; `--probe-rays N` sets rays per probe (32 to
256, default 128). The banner prints them and the CSV has `gpu_probe_update_ms`. The kind of the probe
trace follows `--trace`. See [probe volumes](probe_volumes.md).

Any glTF file can replace Sponza through the positional path or
`benchmark.py scene --model`; the light and camera placement derive from the
model bounds.

## Instancing benchmark

```bash
python3 scripts/benchmark.py instancing --output results/instancing --build --features gpu --gpu-timings \
  --width 1280 --height 720 --repeats 3
./examples/build/instancing --benchmark --fade-field --frames 300 --warmup 60 --width 1280 --height 720
```

`instancing --benchmark` renders the interactive example's scene headless from its starting camera: the
99,856-prop batch, the trio, the pulse spheres and the glass cloud, with instance culling and motion blur on
and the sun's four cascades. The scene is still: nothing animates but the sway, which follows the loop's fixed
frame time. `--fade-field` adds a 64 × 64 grid of 32 m cell batches, 64 swaying props each (4,096 batches,
262,144 props), with a 60 to 90 m fade band: the shape of one foliage layer, most of whose cells lie wholly past
the band. `RendererDesc.max_instance_batches` is raised to hold every cell. The common options behave as in
`many_lights --benchmark`, and the CSV columns are the same.
`benchmark.py instancing` runs `fade-field-off` and `fade-field-on` jobs (`--fade-fields` selects them).

## Profiling configurations and overhead

`benchmark.py render --features NAME` (and `scene` and `instancing`) selects the profiling features compiled into
the workload binary. With `--build` the runner builds the suite's target with the matching
`--define` and `--lib` flags through `scripts/build.py`, copies the binary to
`examples/build/bench/<target>-NAME` so configurations coexist, and checks the
binary's `--print-features` line against the request before any job runs. Without
`--build`, a non-off configuration needs `--binary`. `environment.json` records
`features`, `defines`, `libraries` and `features_reported`.

| Configuration | Defines | Libraries |
| --- | --- | --- |
| `off` | none | none |
| `cpu` | `C3D_PROFILE_CPU` | `c3d_profile` |
| `internal` | `C3D_PROFILE_CPU C3D_PROFILE_INTERNAL` | `c3d_profile` |
| `gpu` | `C3D_PROFILE_GPU C3D_PROFILE_INTERNAL` | `c3d_profile` |
| `gui` | `C3D_PROFILE_GUI C3D_PROFILE_CPU C3D_PROFILE_INTERNAL` | `c3d_profile_gui c3d_profile` |
| `full` | `C3D_PROFILE_GUI C3D_PROFILE_CPU C3D_PROFILE_GPU C3D_PROFILE_INTERNAL` | `c3d_profile_gui c3d_profile` |

`--capture`, `--window` and `--panel` pass through to every job; `--panel` implies
`--window`. `--dry-run` prints the resolved build command and every job command as
JSON lines and runs nothing.

Overhead protocol, per suite (`render` and `scene`), on an idle machine with the same
`--lights`, `--mode`, extent, `--frames` and `--warmup` throughout, three repeats per
configuration:

1. Headless capture cost: `off`; `cpu --capture`; `internal --capture`;
   `gpu --capture --gpu-timings`; `full --capture --gpu-timings`. Compare medians
   of `wall_ms` and the phase columns against `off`. Run `gpu` and `full` once more
   without `--gpu-timings` to separate query cost from capture cost.
2. Presentation cost: `gui --capture --window` and `gui --capture --panel`. Compare
   `wall_ms` and read `gui_ms` directly. Do not compare these with headless rows.
3. Correctness: `draws`, `lights`, `dropped` and `overflows` must match across every
   configuration of the same workload; a `--validation` run of the `full`
   configuration must finish clean.

Report each configuration's `environment.json` beside its `summary.csv`. Measured
results are recorded on the M41 milestone page in Notion, not in this repository;
they age with hardware and drivers.

On Windows, run the same commands with `python`; `vulkaninfo` is `vulkaninfoSDK.exe`
in the Vulkan SDK, and `environment.json` records whichever is on `PATH`.

Deviations from the milestone sketch: there is no dedicated shader-workload target
and no output checksum. The flat and clustered modes already exercise distinct raster
and compute shader paths with per-pass timestamps, and no CPU readback API exists
for a checksum, so the counters above are the correctness proxy. A scene-level
benchmark with a fetched glTF asset is planned separately.
