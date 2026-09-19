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

| CSV field | Interval or result |
| --- | --- |
| `wall_ms` | Scene update through submission, including frame-slot waiting |
| `update_ms` | `Scene.update_world` |
| `begin_ms` | `begin_frame`, including prior-slot completion, readbacks and cache sweeps |
| `render_ms` | `render_view`, including CPU extraction and command recording |
| `finish_ms` | `finish_view` |
| `end_ms` | `end_frame` submission |
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
