# Benchmarking

`scripts/benchmark.py` runs the benchmark mode of the example programs, repeats each job in independent processes and
summarizes the per-frame CSV. Four suites exist: `cpu` (library operations, no GPU device), `render` (headless
many-light rendering), `scene` (a glTF scene) and `instancing`. Some examples also print their own benchmark output.
This page covers the runner, the CSV the examples write, each benchmark's options and the profiling configurations.
Profiler contracts are in [profiling](profiling.md).

## Quick start

Build with the pinned dependencies, C3 0.8.3 and `-O3`, which enables C3's unsafe release mode. Compare runs only when
they use the same optimization and safety settings.

```bash
python3 scripts/benchmark.py cpu --output results/cpu --repeats 3 --build
python3 scripts/benchmark.py render --output results/render --repeats 3 --build
```

Each `--output` directory must be new. Run suites one at a time on an otherwise idle machine. Without `--build`, the
runner uses the last build of the target in `examples/build/`; record the build flags with the results.

A single example runs by hand:

```bash
python3 scripts/build.py --target cpu_bench --opt O3
./examples/build/cpu_bench meshes 4096 100 30
```

## Concepts

- **Job.** One command line of an example binary, for example one case at one node count, or one lighting mode at one
  light count.
- **Repeat.** One sweep over all jobs. Each job of a sweep is a separate process, and alternate sweeps run the jobs in
  reverse order, so a drifting machine does not correlate with job order.
- **Summary.** Per job, repeat and timing column, `summary.csv` holds samples, median, mean, p95, minimum and maximum.
  Columns that end in `_ms`, and `us_per_iteration`, are summarized. A column that reads `-1` (unavailable) is skipped.
- **Environment record.** `environment.json` holds the revision, uncommitted-change summary, dependency revisions,
  platform, CPU, compiler, build flags, binary hash, all runner options, the Vulkan driver variables and, for GPU
  suites, the `vulkaninfo --summary` text. Keep it beside `summary.csv`.

The output directory also holds, per job and repeat, `<job>-r<N>.command.json` (the command), `.csv` (raw samples) and
`.log` (standard error).

## Runner options

| Option | Meaning | Default |
| --- | --- | --- |
| `suite` | `cpu`, `render`, `scene` or `instancing`. | required |
| `--output DIR` | New directory for the results. | required |
| `--build` | Build the suite's target with `-O3` and the selected profiling configuration. | off |
| `--binary PATH` | Run this binary instead of the default build output. Excludes `--build`. | none |
| `--repeats N` | Independent sweeps per job. | 3 |
| `--timeout SECONDS` | Limit per job process. | 180 |
| `--cpu N` | Linux: pin the runner and its children to logical CPU `N`. Do not pin a software Vulkan driver when comparing with unpinned runs. | none |
| `--dry-run` | Print the build command and every job command as JSON lines; run nothing. | off |
| `--features NAME` | Profiling configuration compiled into the binary, see [Profiling configurations and overhead](#profiling-configurations-and-overhead); not for the `cpu` suite. | `off` |
| `--capture`, `--window`, `--panel` | Pass through to every job; not for the `cpu` suite. `--panel` implies `--window`. | off |

Suite options:

| Suites | Options |
| --- | --- |
| `cpu` | `--nodes N...` (1024 4096 16384), `--cases NAME...` (the nine cases below), `--iterations` (100), `--samples` (30). |
| `render`, `scene` | `--lights N...` (`render`: 64 256 1024 4096; `scene`: 16 64 256), `--modes flat clustered`, `--shadings forward deferred path-traced` (forward), `--msaa 1 2 4 8...` (1), `--capacity` (64), `--range` (`render`: 6 units; `scene`: 0.08 of the model extent). |
| `render`, `scene`, `instancing` | `--frames` (300), `--warmup` (60), `--width` (1440), `--height` (900), `--anti-aliasing none\|fxaa\|taa` (fxaa), `--ambient-occlusion none\|half\|full\|ray-traced` (none), `--depth-prepass on\|off` (on), `--auto-exposure on\|off` (off), `--gpu-timings`, `--validation`. `--reflections on\|off` (off) applies to `render` and `scene`. |
| `scene` | `--model PATH` (Sponza), `--shadows on\|off` (on). |
| `instancing` | `--fade-fields off on` selects the `fade-field-off` and `fade-field-on` jobs. |

Job names carry the shading path, mode, light count and, for `scene`, the shadow setting; a multisample count above 1
ends the name in `-msaa<N>`.

## CPU extraction and transforms

```bash
python3 scripts/benchmark.py cpu --output results/cpu --repeats 3
./examples/build/cpu_bench CASE [nodes=4096] [iterations=100] [samples=30]
```

`cpu_bench` creates no GPU device. The runner sweeps these cases; `nodes` is the node count:

| Case | Work inside each timed iteration |
| --- | --- |
| `world` | Update every node's world matrix. |
| `hidden_world` | The same update with all mesh nodes hidden. |
| `meshes` | Extract visible mesh candidates, including transformed bounds and frustum tests. |
| `culled_meshes` | The same extraction with every mesh outside the frustum. |
| `hidden_meshes` | The same extraction with every mesh hidden. |
| `shadows` | Extract shadow candidates without camera-frustum filtering. |
| `lights` | Extract and pack visible unshadowed point lights. |
| `hidden_lights` | The same light extraction with every light hidden. |
| `sort` | Extract candidates and sort them with the transparent comparator. |

Run by hand, `cpu_bench` also takes these cases:

| Case | `nodes` is | Work inside each timed iteration |
| --- | --- | --- |
| `bvh_triangles` | plane segments per side (128; at most 1024) | Bottom-level BVH build over a plane. |
| `bvh_top` | box count | Top-level BVH build over scattered boxes. |
| `texture_plan` | synthetic texture records | Texture residency planning. |
| `texture_mips EXTENT rgba8\|srgb [iterations=3] [samples=5]` | not used | CPU mip-chain generation for one image; prints `ms_per_call`. |

Nodes are flat children of the root at deterministic positions. Meshes share a box geometry and material. An
orthographic camera encloses the ordinary mesh workload. The cases measure single library operations. They do not
simulate animation, deep hierarchies, asset streaming or a whole renderer frame. `sort` is a candidate-sort stress case;
the renderer sorts a different, private draw-item structure.

Allocation and temporary-pool cleanup are inside the timed call. Scene and asset setup are outside it. Five warmup
batches precede the measured batches, and a consumed checksum keeps the compiler from removing the work.
`us_per_iteration` is the average of one batch; its p95 describes batch averages, not single-frame latency. The CSV
columns are `case,nodes,batch,iterations,us_per_iteration,checksum`.

For instruction attribution with Valgrind:

```bash
valgrind --tool=callgrind --collect-atstart=no \
  '--toggle-collect=*run_iteration*' --callgrind-out-file=callgrind.meshes \
  ./examples/build/cpu_bench meshes 4096 10 3
callgrind_annotate --inclusive=no callgrind.meshes
```

The collection filter excludes scene setup and CSV output but includes warmup iterations. Check that the instruction
total is nonzero. Instruction shares and Valgrind elapsed times are not native CPU-time shares; confirm a change with
independent native runs and matching output.

### Scene index and triangle trees

```bash
./examples/build/cpu_bench index_refresh_crowd 1 10 300
./examples/build/cpu_bench index_pick_crowd 1 10 30
./examples/build/cpu_bench triangle_warmup 128 2 30
```

| Case | Work inside each timed iteration |
| --- | --- |
| `index_refresh_crowd`, `index_refresh_batch` | `SceneIndex.refresh` with nothing changed. |
| `index_build_crowd`, `index_build_batch` | The tree build of the first pick after the entries changed, plus that one ray. |
| `index_pick_crowd`, `scan_pick_crowd` | 64 fixed-seed rays at bounds precision through the index, or through `spatial::pick`. |
| `index_pick_triangles`, `scan_pick_triangles` | The same rays at triangle precision, triangle trees built beforehand. |
| `triangle_warmup` | `prepare_triangle_picks` on one plane mesh after `mark_geometry_dirty`; `nodes` is the plane segment count per side. |

The crowd scene holds 2,000 unit-box mesh nodes on a grid and one 4,096-instance batch. The batch scene holds one
65,536-instance batch. The scene cases ignore `nodes` and print the entry count in its column. Each pick case checksums
its rays' hit counts and nearest node and instance, so an index case and its scan case print equal checksums.
`triangle_warmup` prints `# triangle tree bytes` after the CSV.

### ECS queries

```bash
./examples/build/cpu_bench ecs_each2 16384 1 300
./examples/build/cpu_bench ecs_each2_shuffled 2097152 1 30
```

Each case builds a standalone `World` with two four-byte component types and no scene. `nodes` is the entity count, at
most 2,097,152. Every second entity carries the walked type, added once. Before each batch, outside the timed region,
the queried type is removed and placed again:

| Case | Queried type on | Work inside each timed iteration |
| --- | --- | --- |
| `ecs_each` | no entity | `@each` over the walked type. |
| `ecs_each2` | a fresh seeded random half of all entities | `@each2` over both types. |
| `ecs_each2_dense` | every candidate | `@each2` over both types. |
| `ecs_get` | as `ecs_each2` | `@each` over the walked type and `get` of the queried type per candidate. |
| `ecs_get_absent` | every entity without the walked type | as `ecs_get`. |
| `ecs_has` | as `ecs_each2` | `@each` over the walked type and `has` of the queried type per candidate. |

Without a suffix, both types are added in entity order. The `_shuffled` suffix adds them in a seeded random order, so
the walk reads the other arrays at random positions. The seed is fixed and printed as `# seed:` before the CSV header.
Each batch draws a new random half and times one pass (`iterations` 1), so the branch predictor cannot learn a repeated
half. The checksum sums the visited values. Use a small entity count (arrays that fit one core's cache) and a large one
(arrays beyond the last-level cache) to separate compute from memory cost.

## Headless many-light rendering

```bash
python3 scripts/benchmark.py render --output results/render --repeats 3
./examples/build/many_lights --benchmark --mode clustered --lights 256 \
  --frames 300 --warmup 60 --capacity 64 --range 6 --width 1440 --height 900
```

`many_lights --benchmark` reuses the interactive example's hall, deterministic light placement and reset camera. It
renders a display-LDR texture without a window, GUI or presentation. All 4,096 light nodes exist in every workload and
inactive lights are hidden. World matrices update every frame, as in the interactive loop. The cluster grid stays 16 x 9
x 24 with a far distance of 100. Warmup excludes pipeline creation and first-use uploads from the samples; raise it if a
driver has not reached steady state.

Benchmark mode of `many_lights`, `gltf_viewer` and `instancing` disables validation and timestamps by default. Run a
correctness smoke with `--validation`, then collect timing without it. Add `--gpu-timings` for a separate diagnostic
run, because timestamp instrumentation can change performance. `effects`, `rt_shadows` and `rt_effects` always run with
validation on, so their timings include its cost.

### Options of every benchmark example

These options are parsed the same way by `many_lights`, `gltf_viewer` and `instancing`. An option that needs a compiled
feature is rejected at parse time with the build recipe when the binary lacks it, so an excluded mode never reports zero
timings silently.

The loop rejects, as `c3d::INVALID_ARGUMENT`: a frame count of 0 or above 100,000, a warmup above 100,000, a width or
height of 0 or above 8,192, `--ssgi-steps` outside 4 to 64 with screen-space GI on, `--panel` without `--window` and
`--capture`, `--trace software` with path tracing, and a multisample count above 1 with TAA or path tracing.
`gltf_viewer` also rejects more than 4,096 lights, a capacity outside 1 to 256 and a range outside 0 to 2.

| Option | Needs | Effect |
| --- | --- | --- |
| `--benchmark` | | Selects benchmark mode. |
| `--frames N`, `--warmup N`, `--width N`, `--height N` | | Frames measured (300), frames before measuring (60), and the extent (1440 x 900). |
| `--gpu-timings` | `C3D_PROFILE_GPU` | Enables per-pass timestamps. |
| `--validation` | | Enables Vulkan validation. |
| `--capture` | `C3D_PROFILE_CPU` or `C3D_PROFILE_GPU` | Opens a `profile::@capture` with one `application.frame` scope around every frame, so library scopes and GPU capture run. Nothing is exported. |
| `--window` | | Presents to a window with immediate present mode instead of an offscreen target, using the renderer's default view. Events are polled and ignored. Closing the window ends the run with the rows collected so far. |
| `--panel` | `--window`, `--capture`, `C3D_PROFILE_GUI` | Draws the profiler panel every frame through the overlay and reports its cost as `gui_ms`. |
| `--print-features` | | Prints `cpu=<0\|1> gpu=<0\|1> internal=<0\|1> gui=<0\|1>` and exits. |
| `--anti-aliasing none\|fxaa\|taa` | | Anti-aliasing filter of the measured view; FXAA by default. |
| `--msaa 1\|2\|4\|8` | | `many_lights` and `gltf_viewer` only; `instancing` parses it and ignores it. Samples per pixel of the measured view; 1 by default. A count above 1 with `--anti-aliasing taa` or `--shading path-traced` is rejected. A deferred count above 1 reports its classification pass as `gpu_msaa_edges_ms`. |
| `--depth-prepass on\|off` | | Depth prepass of a forward view; on by default. Deferred views always run it. |
| `--ambient-occlusion none\|half\|full\|ray-traced` | `ray-traced`: a ray-query adapter, unless `--trace software` | Screen-space AO at half or full resolution, or ray traced at half resolution with 4 rays; none by default. Reported as `gpu_ambient_occlusion_ms`. |
| `--auto-exposure on\|off` | | Automatic exposure; off by default. Reported as `gpu_exposure_ms`. |
| `--reflections on\|off` | a ray-query adapter, unless `--trace software`; deferred or forward shading | Ray-traced reflections; off by default. A path-traced view faults `UNSUPPORTED`. Reported as `gpu_rt_reflections_ms`. |
| `--screen-space-gi on\|off` | | [Screen-space GI](screen_space_gi.md); off by default. Reported as `gpu_screen_space_gi_ms` and `gpu_ssgi_copy_ms`. |
| `--ssgi-trace linear\|hierarchical` | `--screen-space-gi on` | Ray search; `linear` by default. Orthographic views use `linear`. A hierarchical perspective view also reports `gpu_depth_pyramid_ms`; add it to `gpu_screen_space_gi_ms` when comparing modes. |
| `--ssgi-steps N` | `--screen-space-gi on` | Steps per ray, 4 to 64; default 24. Keep it equal across compared trace modes. |
| `--trace software\|hardware` | `hardware`: a ray-query adapter | Creates the renderer with or without ray queries; every trace consumer of the run, probe updates included, follows. The default is `hardware` exactly when `--reflections on` or `--ambient-occlusion ray-traced` is given. `software` with `--shading path-traced` is rejected. |
| `--shading forward\|deferred\|path-traced` | `path-traced`: a ray-tracing-pipeline adapter | `many_lights` and `gltf_viewer`: shading path of the measured view; path tracing uses the default settings and forces the flat light mode. Reported as `gpu_path_trace_ms`. |

`many_lights` takes its own options on top of these ([examples](../examples/README.md#materials-lights-and-shaders)). Keep
extent, camera, range, capacity and material fixed when comparing flat and clustered modes or the shading paths. Report
overflow counts: an overflow falls back to the complete flat light list instead of dropping contributions. `many_lights`
rejects fewer than 1 or more than 4,096 lights, a capacity outside 1 to 256 and a range outside 1 to 32. A correctness
stress:

```bash
./examples/build/many_lights --benchmark --mode clustered --lights 256 \
  --capacity 1 --range 32 --frames 10 --warmup 10 --validation --gpu-timings
```

### CSV fields

Every benchmark loop writes one row per measured frame, led by a `frame` column:

| Field | Interval or result |
| --- | --- |
| `wall_ms` | Scene update through submission, including frame-slot waiting. |
| `update_ms` | The benchmark's own per-frame scene edits plus `Scene.update_world`. |
| `begin_ms` | `begin_frame`, including prior-slot completion, readbacks and cache sweeps. |
| `render_ms` | `render_view`, including CPU extraction and command recording. |
| `finish_ms` | `finish_view`. |
| `end_ms` | `end_frame` submission, including presentation in windowed runs. |
| `gui_ms` | Profiler panel draw and overlay recording; zero without `--panel`. |
| `cpu_record_ms` | `Stats.cpu_record_ms`; excludes the waiting, readback and sweep work of `begin_frame`. |
| `draws`, `lights`, `dropped` | Current-frame renderer counters. |
| `overflows` | Completed cluster overflow count, attributed to its submitted frame. |
| `material_resolutions` | Fresh material dependency resolutions in the frame; one per material per view traversal. |
| `pipeline_lookups` | Draw pipeline cache lookups in the frame; one per prepared draw item and shadow draw. |
| `batches_faded` | `Stats.batches_faded`: view batches inside the frustum and wholly past their fade band. |
| `upload_bytes` | `Stats.upload_bytes`: bytes staged for upload this frame. |
| `gpu_<pass>_ms` | Completed per-pass timestamp, see below. |

The GPU columns are `gpu_shadow_ms`, `gpu_cull_ms`, `gpu_prepass_ms`, `gpu_gbuffer_ms`, `gpu_depth_pyramid_ms`,
`gpu_ambient_occlusion_ms`, `gpu_rt_reflections_ms`, `gpu_path_trace_ms`, `gpu_lighting_ms`, `gpu_opaque_ms`,
`gpu_post_ms`, `gpu_composite_ms`, `gpu_velocity_ms`, `gpu_taa_ms`, `gpu_probe_update_ms`, `gpu_acceleration_build_ms`,
`gpu_screen_space_gi_ms`, `gpu_ssgi_copy_ms`, `gpu_instance_cull_ms`, `gpu_environment_ms`, `gpu_exposure_ms` and
`gpu_msaa_edges_ms`. Three more are stages of `gpu_post_ms` (`gpu_bloom_ms`, `gpu_dof_ms`, `gpu_motion_blur_ms`) and
eight are stages of `gpu_environment_ms`: `gpu_environment_source_ms`, `gpu_environment_irradiance_ms`,
`gpu_environment_prefilter_ms`, `gpu_environment_sheen_ms`, `gpu_environment_luts_ms`,
`gpu_environment_sky_transmittance_ms`, `gpu_environment_sky_multi_scattering_ms` and `gpu_environment_sky_ms`. Stage
columns are parts of their parent column; do not add them to it. A GPU column reads `-1` when timestamps are off and
zero for an omitted pass.

GPU results are read when the frame slot is reused and attached to the row of the submitting frame. Two extra frames
drain the last measured slots. Sample storage is allocated before the loop and the CSV is written after it. `wall_ms`
measures steady-state submission throughput with frames in flight, not isolated GPU latency. Pass timestamps are partial
intervals; do not present them as total frame time.

A windowed run presents the same view settings to the window, and window-system pacing applies. Compare windowed rows
only with other windowed rows.

When the run traces rays, the loop prints `first frame: trace preparation ... ms CPU, acceleration build ... ms GPU` to
standard error once the first frame's GPU time arrives.

## Scene benchmark

```bash
python3 scripts/fetch_benchmark_assets.py
python3 scripts/build.py --target gltf_viewer --opt O3
python3 scripts/benchmark.py scene --output results/scene --repeats 3
./examples/build/gltf_viewer --benchmark --lights 64 --mode clustered --shadows on
```

The scene suite renders Crytek Sponza from `KhronosGroup/glTF-Sample-Assets`. `scripts/fetch_benchmark_assets.py`
downloads it at a pinned commit into `examples/assets/benchmark/sponza/`, which is gitignored: the model files are under
the Cryengine Limited License Agreement and are not redistributed here. The fetch skips files that already exist with
the right size; `--force` downloads everything again. `benchmark.py scene` refuses to run without the model and prints
the fetch command. Any glTF file replaces Sponza through the positional path of `gltf_viewer` or
`benchmark.py scene --model`; light and camera placement derive from the model bounds.

`gltf_viewer --benchmark` reuses the viewer's loading and environment: one instance at the origin, the studio HDR as
environment and background, a sun, and `--lights N` point lights on a deterministic grid inside the model bounds at 0.35
of the vertical extent. The camera sits inside the model at 0.3 of the height, 0.35 of the long axis behind the center,
looking along the long axis. Shadow casting dominates the draw count. The options of the previous section apply, and
`gltf_viewer` adds light, shadow, probe and environment options; they are listed under
[`gltf_viewer`](../examples/README.md#assets-and-models). `--range R` is a fraction of the largest horizontal extent
(0.08 by default). With `--reflection-probes`, the probe-sampling cost shows in `gpu_opaque_ms` (forward) or
`gpu_lighting_ms` (deferred). With `--environment-refresh on`, the environment regenerates every frame and is reported as
`gpu_environment_ms` and its stage columns ([environments](environments.md#preparation-and-edits)).

The banner printed to standard error repeats the effective settings.

## Instancing benchmark

```bash
python3 scripts/benchmark.py instancing --output results/instancing --build --features gpu --gpu-timings \
  --width 1280 --height 720 --repeats 3
./examples/build/instancing --benchmark --fade-field --frames 300 --warmup 60 --width 1280 --height 720
```

`instancing --benchmark` renders the interactive example's scene headless from its starting camera, with instance
culling and motion blur on and four sun cascades. The scene is still: only the sway moves, on the loop's fixed frame
time. The options of the many-light section apply, and the CSV columns are the same. `--fade-field`, `--instance-edit`
and `--move-node` are listed in the [examples](../examples/README.md#scene-scale); `--fade-field` raises
`RendererDesc.max_instance_batches` to hold every cell, `batches_faded` counts the skipped cells, and `upload_bytes` shows
the difference between `--instance-edit range` and `whole`.

`benchmark.py instancing` runs the `fade-field-off` and `fade-field-on` jobs.

## Sky benchmark

```bash
python3 scripts/build.py --target sky --opt O3 --define C3D_PROFILE_GPU --define C3D_PROFILE_INTERNAL --lib c3d_profile
./examples/build/sky --benchmark --gpu-timings
```

`sky --benchmark [frames]` renders the [sky example](sky.md#example) offscreen at 2560 x 1440 after 60 warmup frames.
`frames` is the length of each segment (300 by default; at least 2). The segments run in order: `noon`, `twilight`,
`valley` (camera low, looking into the fog), `pan` (the camera yaw sweeps), `orbit` (the camera far above the
atmosphere), `ascent` (the camera rises through the top of the atmosphere) and `time-lapse` (the sun rises over four
segments' frames). The output lines are:

```
# sky shading=forward shadows=atlas ... extent=2560x1440 frames=300
sun_extract_us median=<>
gpu_ms view=<main|mirror> segment=<s> pass=<pass> median=<> p99=<>
frame_ms segment=<s> median=<> p99=<>
refresh_ms segment=time-lapse stage=<environment.sky|environment.prefilter|environment.irradiance|total> median=<> max=<> count=<n>
refreshes_per_minute segment=time-lapse value=<>
gate time_lapse_regenerations expected=<n> found=<n> <pass|fail>
gate steady_sky <pass|fail>
gate ascent_regenerations <pass|fail>
```

`refresh_ms` reads the frames that regenerated the sky environment; `total` is the whole `ENVIRONMENT` pass. The gates
check the regeneration policy: the time-lapse expects `floor(sweep / period)` regenerations after its first frame, where
`sweep` is the sun's total elevation change and `period = (floor(0.5° / step) + 1) · step` for a per-frame change
`step`, and none without an atmosphere; `steady_sky` expects none after the first frame of `noon`;
`ascent_regenerations` expects none after the first frame of `ascent`. A failed gate exits 1.

The options of the benchmark are the `sky` options listed in the [examples](../examples/README.md#sky-post-processing-and-effects).
The `FOG_SCATTERING` and `FOG_INTEGRATION` lines report the froxel volume, and the `CLOUDS` and `CLOUD_SHADOWS` lines
report the cloud layer.

## Post-processing benchmark

```bash
python3 scripts/build.py --target effects --opt O3 --define C3D_PROFILE_GPU --define C3D_PROFILE_INTERNAL \
  --lib c3d_profile
./examples/build/effects --gpu-timings --benchmark 300 [--auto-focus] [--focus-point X Y]
```

`effects --benchmark FRAMES` renders the interactive example's scene offscreen through the shared benchmark loop, at
1920 x 1080 after 30 warmup frames. Bloom, depth of field, motion blur and FXAA are on, and the cube spins at the loop's
fixed frame time. It needs `--gpu-timings`, prints no CSV, and prints the mean over the frames of each [post
stage](post.md) and of the whole post chain. The stages are parts of the post chain, so their sum is at most its
mean. The other benchmark examples report the same stages as the `gpu_bloom_ms`, `gpu_dof_ms` and `gpu_motion_blur_ms`
columns when their view enables the effects.

## Traced effects in software and on ray queries

```bash
./examples/build/rt_shadows --gpu-timings --benchmark 300 --atlas-shadows
./examples/build/rt_shadows --gpu-timings --benchmark 300 [--software] [--twin-ground]
./examples/build/rt_effects --gpu-timings --benchmark 300 [--software] [--forward] [--no-reflections]
./examples/build/gltf_viewer --benchmark --gpu-timings --frames 300 --warmup 60 --shading deferred \
    --ambient-occlusion ray-traced --reflections on --trace software|hardware --width 3840 --height 2160
./examples/build/gltf_viewer --benchmark --gpu-timings --frames 300 --warmup 60 --shading deferred \
    --shadows on|traced --trace software|hardware --width 3840 --height 2160
```

Build the three targets with `--opt O3 --define C3D_PROFILE_GPU --define C3D_PROFILE_INTERNAL --lib c3d_profile`.
`rt_shadows` and `rt_effects` benchmark at 1920 x 1080 and print pass means and the GPU frame (the sum of the pass
timestamps).

- `rt_shadows` reports the forward pass, where traced shadows cost. `--atlas-shadows` gives the atlas base to subtract.
  `--twin-ground` draws the ground with the custom twin of its Standard material, which shades through
  `standard_shading.glsl` and its traced forms.
- `rt_effects` runs deferred with traced reflections unless `--forward` or `--no-reflections` say otherwise. It
  configures the view before `prepare_scene` and prints `first frame:` with the pipelines the first frame created and
  its recording time.
- `gltf_viewer --shadows traced` traces the sun's shadow; `--shadows on` keeps the atlas as its base. A run of either
  with `--trace software` uses the software walk and with `--trace hardware` ray queries.

Quote a ratio between the two traces only where both frames exceed 1 ms; shorter frames carry timer noise.

## Profiling configurations and overhead

`benchmark.py render --features NAME` (and `scene` and `instancing`) selects the profiling features compiled into the
workload binary. With `--build`, the runner builds the suite's target with the matching `--define` and `--lib` flags
through `scripts/build.py`, copies the binary to `examples/build/bench/<target>-NAME` so configurations coexist, and
checks the binary's `--print-features` line against the request before any job runs. Without `--build`, a configuration
other than `off` needs `--binary`. `environment.json` records `features`, `defines`, `libraries` and
`features_reported`.

| Configuration | Defines | Libraries |
| --- | --- | --- |
| `off` | none | none |
| `cpu` | `C3D_PROFILE_CPU` | `c3d_profile` |
| `internal` | `C3D_PROFILE_CPU C3D_PROFILE_INTERNAL` | `c3d_profile` |
| `gpu` | `C3D_PROFILE_GPU C3D_PROFILE_INTERNAL` | `c3d_profile` |
| `gui` | `C3D_PROFILE_GUI C3D_PROFILE_CPU C3D_PROFILE_INTERNAL` | `c3d_profile_gui c3d_profile` |
| `full` | `C3D_PROFILE_GUI C3D_PROFILE_CPU C3D_PROFILE_GPU C3D_PROFILE_INTERNAL` | `c3d_profile_gui c3d_profile` |

`--capture` needs a configuration other than `off`. `--panel` needs `--features gui` or `full` and `--capture`.
`--dry-run` prints the resolved build command and every job command without running anything.

Measure the overhead of a configuration on an idle machine, per suite (`render` and `scene`), with the same `--lights`,
`--mode`, extent, `--frames` and `--warmup` throughout and three repeats per configuration:

1. Headless capture cost: `off`; `cpu --capture`; `internal --capture`; `gpu --capture --gpu-timings`;
   `full --capture --gpu-timings`. Compare medians of `wall_ms` and the phase columns against `off`. Run `gpu` and
   `full` once more without `--gpu-timings` to separate query cost from capture cost.
2. Presentation cost: `gui --capture --window` and `gui --capture --panel`. Compare `wall_ms` and read `gui_ms`. Do not
   compare these rows with headless rows.
3. Correctness: `draws`, `lights`, `dropped` and `overflows` must match across every configuration of the same workload.
   A `--validation` run of `full` must finish clean.

## Limits

- Software Vulkan (lavapipe) verifies a path. It cannot establish hardware GPU speedups or a light-count crossover.
  Record any driver workaround with the results.
- Headless runs omit window-system pacing. Measure the interactive example, or a `--window` run, when pacing is the
  question.
- `scene` needs the fetched model, which has its own licence and is never committed.
- `--cpu` pins with `os.sched_setaffinity`, so it works on Linux only.
- On Windows, run the commands with `python`. `vulkaninfo` is `vulkaninfoSDK.exe` in the Vulkan SDK; `environment.json`
  records whichever is on `PATH`.
- Results age with hardware and drivers. Keep them with their `environment.json`, not in this repository.

## See also

- [Profiling](profiling.md): capture lifetimes, scopes and the GPU capture these options enable.
- [Jobs](jobs.md): `job_bench`, the job pool benchmark.
- [Development](development.md): building, and running on software Vulkan.
- Example options that select a benchmark live with their feature: [lights](lights.md), [sky](sky.md), [fog](fog.md),
  [clouds](clouds.md), [instancing](instancing.md), [post](post.md), [environments](environments.md), [reflection
  probes](reflection_probes.md) and [shadows](shadows.md).
