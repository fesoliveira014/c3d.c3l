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
| `gpu_*_ms` | Completed per-pass timestamps; `-1` when unavailable, zero for an omitted pass |
| `draws`, `lights`, `dropped` | Current-frame renderer counters |
| `overflows` | Completed cluster overflow count attributed to its submitted frame |

GPU results are read when the frame slot is reused and attached to the originating
row. Two additional frames drain the final measured slots. Sample storage is
allocated before the loop; CSV output follows completion. `wall_ms` measures
steady-state submission throughput with frames in flight, not isolated GPU latency.
The pass timestamps are partial intervals and should not be presented as total
frame time.

Keep extent, camera, range, capacity and material fixed when comparing flat and
clustered modes. Report overflow counts: overflow falls back to the complete flat
light list rather than dropping contributions. A useful correctness stress is:

```bash
./examples/build/many_lights --benchmark --mode clustered --lights 256 \
  --capacity 1 --range 32 --frames 10 --warmup 10 --validation --gpu-timings
```

On a machine without a physical GPU, software Vulkan can verify the path, but it
cannot establish hardware GPU speedups or a useful light-count crossover. Record
any driver-specific workarounds. Headless results also omit window-system pacing;
measure the interactive example separately when that is the question.

## Profiling configurations and overhead

`benchmark.py render --features NAME` selects the profiling features compiled into
the workload binary. With `--build` the runner builds `many_lights` with the matching
`--define` and `--lib` flags through `scripts/build.py`, copies the binary to
`examples/build/bench/many_lights-NAME` so configurations coexist, and checks the
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

Overhead protocol, on an idle machine with the same `--lights`, `--mode`, extent,
`--frames` and `--warmup` throughout, three repeats per configuration:

1. Headless capture cost: `off`; `cpu --capture`; `internal --capture`;
   `gpu --capture --gpu-timings`; `full --capture --gpu-timings`. Compare medians
   of `wall_ms` and the phase columns against `off`. Run `gpu` and `full` once more
   without `--gpu-timings` to separate query cost from capture cost.
2. Presentation cost: `gui --capture --window` and `gui --capture --panel`. Compare
   `wall_ms` and read `gui_ms` directly. Do not compare these with headless rows.
3. Correctness: `draws`, `lights`, `dropped` and `overflows` must match across every
   configuration of the same workload; a `--validation` run of the `full`
   configuration must finish clean.

Report each configuration's `environment.json` beside its `summary.csv`.

Deviations from the milestone sketch: there is no dedicated shader-workload target
and no output checksum. The flat and clustered modes already exercise distinct raster
and compute shader paths with per-pass timestamps, and no CPU readback API exists
for a checksum, so the counters above are the correctness proxy. A scene-level
benchmark with a fetched glTF asset is planned separately.

## Measured allocation experiment

The [candidate-allocation patch](benchmarks/no-zero-extraction.patch) replaces two
zeroed allocations with uninitialized allocations. It is a separate experiment;
the benchmark target uses the unchanged library until the patch is applied.
On a Xeon 8370C virtual machine with C3 0.8.3 `-O3`, five paired process repeats
at 4,096 meshes reduced median visible extraction from 199.20 to 187.81 µs and
hidden extraction from 11.91 to 4.14 µs. Every emitted candidate is assigned
before it is returned. All 383 CPU unit tests passed with the temporary change.
These are operation timings, not whole-frame speedups; larger visible workloads
showed more timing noise. Reproduce on the target machine before adopting it.
