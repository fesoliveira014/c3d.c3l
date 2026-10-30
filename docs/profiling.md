# Profiling

`c3d_profile` is a source-only C3 library in `addons/c3d_profile.c3l`. It records CPU scopes and GPU intervals into
bounded capture storage, exports them as JSON and, with the renderer's cooperation, measures GPU pass times.
`c3d_profile_gui`, in `addons/c3d_profile_gui.c3l`, is an optional ImGui panel for those captures. It extends `c3d::gui`
and imports only neutral capture values, ImGui and the standard library; neither the collector nor core invokes it.

CPU-only use of `c3d::profile` needs C3 0.8.5_1 and its standard library: no core, device, SDL or ImGui. The GPU module
(`c3d::render::profile_gpu`) uses gpu.c3l and is compiled only under `C3D_PROFILE_GPU`. Core never depends on the
packages unconditionally; an application selects them and the features it needs. The reference tables (features, library
scopes, descriptors, JSON schema and statistics fields) are in [profiling_reference.md](profiling_reference.md).

## Quick start

Add the package to `project.json` and enable CPU capture:

```json
{
  "dependency-search-paths": ["path/to/c3d.c3l/lib"],
  "dependencies": ["c3d_profile"],
  "features": ["C3D_PROFILE_CPU"]
}
```

Capture one frame and export it:

```c3
import c3d::profile;

fn void main() {
    profile::Recorder recorder = profile::create_recorder(mem, {
        .frame_capacity = 120,
        .cpu_scopes_per_frame = 2_048,
        .max_depth = 64,
        .label_bytes_per_frame = 65_536,
    })!!;
    defer profile::destroy_recorder(&recorder);

    profile::@capture(&recorder, 7) {
        profile::@scope("simulation") {
            // application work
        };
    };

    String json = profile::capture_json(mem, recorder.frame(7)!!);
    defer alloc::free(mem, json.ptr);
}
```

`c3c run capture --path addons/c3d_profile.c3l` runs the complete example. It prints the JSON capture to standard output
and the recorder's storage size to standard error.

## Select the package and features

An application that uses the repository's library directory selects the package explicitly. For a standalone
installation, copy `addons/c3d_profile.c3l` into the application's library directory and search that directory. The
manifest selects its `src/**` files and declares no other packages or native libraries. A c3d application adds
`c3d_profile` to its existing dependencies.

Features select what is compiled. The full matrix is in [the reference](profiling_reference.md#features).

| Features | Behavior |
| --- | --- |
| none | Scope bodies run and their arguments are not evaluated. No collector storage, thread-local state, clock or GPU query exists. |
| `C3D_PROFILE_CPU` | Application scopes, CPU capture and export. |
| `C3D_PROFILE_CPU`, `C3D_PROFILE_INTERNAL` | Application scopes plus the [library scopes](profiling_reference.md#library-scopes). |
| `C3D_PROFILE_GPU` | Application GPU scopes and completed capture history. |
| `C3D_PROFILE_GPU`, `C3D_PROFILE_INTERNAL` | Automatic frame, view, pass, pass-stage, shadow-layer and custom-dispatch intervals, and the GPU fields of `Stats`. |
| CPU, GPU, INTERNAL | Both domains in one capture, on independent clocks. |

Application source that imports `c3d::profile` keeps the package selected when capture is compiled out; the package
supplies no-op macros. `C3D_PROFILE_INTERNAL` and `C3D_PROFILE_GUI` each require CPU or GPU profiling. Per-draw graphics
scopes are not provided.

To show the panel, install `addons/c3d_profile_gui.c3l` and select both add-ons. A panel consumer selects the pinned
ImGui package and its Vulkan binding even for CPU captures, because the ImGui package's compiled backend imports `vk`:

```json
{
  "dependency-search-paths": ["path/to/c3d.c3l/lib", "path/to/c3d.c3l/lib/gpu.c3l/lib"],
  "dependencies": ["c3d_profile_gui", "c3d_profile", "c3imgui", "vk"],
  "features": ["C3D_PROFILE_GUI", "C3D_PROFILE_CPU"],
  "wincrt": "static"
}
```

Linux consumers link the C++ runtime that the pinned ImGui archive uses; the add-on manifest supplies that link. Windows
consumers use the static CRT. A windowed c3d application also ships the SDL3 runtime beside its executable. GPU
consumers additionally select `gpu`, `vma` and `spvreflect` and enable `C3D_PROFILE_GPU`. The dependency names are
listed in [release.md](release.md).

## Capture application work

Create one `profile::Recorder` per writing thread with `profile::create_recorder(allocator, desc)`. Set
`frame_capacity`, `cpu_scopes_per_frame`, `max_depth` and `label_bytes_per_frame`; each must be nonzero, and the depth
cannot exceed the scope capacity. An invalid budget or an allocation-size overflow faults with
`profile::INVALID_ARGUMENT`. Allocator exhaustion follows the allocator's own behavior. Storage is allocated once and
never grows during recording.

Wrap the application frame in `profile::@capture(&recorder, frame_id)` and individual operations in
`profile::@scope("label")`. Bodies run exactly once, including when capture is disabled or full. Keep recorder creation,
lookup and export inside the CPU feature selection; the body macros can stay in shared source.

- `@capture` installs the recorder for the calling thread and restores the previous one on normal exit, early return and
  propagated faults. Captures on different recorders may nest. A disabled inner capture masks the outer recorder while
  its body runs. Capturing twice concurrently on one recorder is a programming error.
- Frame ids increase strictly per recorder, including disabled captures. Zero is a valid first id.
- Labels are copied into bounded capture storage, so the caller can reuse its buffer after a scope begins. A label
  expression is evaluated only when the collector tries to admit the scope; a label too large for the remaining label
  storage is evaluated once to find that out. Hot scopes do not allocate from a general-purpose allocator.
- The recorder owns its storage, must stay at a stable address while capturing and must not be copied. Call
  `profile::destroy_recorder` only with no active capture or scope, no attached renderer and no pending GPU capture. The
  application owns the recorder's lifetime; c3d never creates a recorder or advances frame ids.
- `Recorder.set_enabled` selects recording for the next capture. Changing it inside a capture does not cut that capture
  off. Disabled captures do not evict retained history.

## Read captures and bounds

`Recorder.frame(frame_id)` returns a borrowed `FrameCaptureView`, or faults with `profile::NOT_FOUND` for a missing,
disabled, still-open or evicted frame. `Recorder.frame_ids(storage)` copies the retained ids in ascending order. The
borrow is valid until its history slot is reused or GPU publication mutates that capture. Reacquire views after the
renderer completes frames, and consume or export them synchronously. Destroying the recorder ends every borrow.

Samples keep begin order, parent index, origin (application or library), label, start offset, inclusive duration and
self time. Times are integer nanoseconds from the frame's monotonic CPU origin. Self time subtracts the direct
children's inclusive durations once. Repeated labels stay separate events, so a consumer can aggregate call counts
without losing the hierarchy.

The first sample, nesting or label-budget overflow marks the capture truncated. The collector then admits no new scope
until the next frame and counts the omitted scopes; accepted scopes still close and application work continues. Omitted
scopes do not evaluate labels or read clocks. `self_complete` is false on open ancestors of an omitted scope, and their
`self_ns` is a residual upper bound, not an exact exclusive duration. Display it as incomplete. Call counts from a
truncated capture are partial.

A closed CPU capture is `READY`, `TRUNCATED` or `ABORTED`. A fault that leaves the capture sets `ABORTED` and keeps the
truncation flag and omitted count. A fault caught inside the capture does not abort it.

## Worker ranges

Worker threads have no recorder. A producer such as the job pool keeps its own records, and the owning thread hands them
over with `Recorder.add_worker_interval(lane, label, start_ns, end_ns)`. The times are `clock::now()` values. The call
stores a `WorkerSample` in the open capture: the label, the lane (the worker index), a signed start offset from the
capture origin and the duration. A range that began before the capture keeps a negative offset.
`Recorder.add_dropped_worker_intervals(count)` adds intervals the producer lost. Outside a recording capture, both calls
do nothing.

`FrameCaptureView.workers` holds the samples in arrival order, and `dropped_worker_samples` counts those that did not
fit. `RecorderDesc.worker_samples_per_frame` bounds the samples of one capture. Zero keeps none and counts every
interval as dropped, unlike the renderer's descriptors, where zero selects a default.

Worker labels share the `label_bytes_per_frame` storage with scope labels. An interval whose label does not fit is
dropped and counted, and it does not truncate the CPU capture. Labels forwarded early use storage that later scope
labels need, so a burst at the start of a capture can truncate the scopes that follow; forward worker records late in
the frame. Worker samples are not CPU scopes: they have no parent, self time or origin and do not count toward
`cpu_scopes_per_frame`.

`JobPool.forward_records(&recorder)` makes these calls; see [the job pool](jobs.md#profiling).

## Export captures

`profile::capture_json(allocator, frame)` returns a JSON string owned by the caller, released through that allocator. It
outlives the borrowed capture and the recorder, and performs no file I/O. Output is deterministic for an unchanged
capture. Integers keep all 64 bits, so a consumer that needs exact values above 2^53 must use an integer-preserving JSON
parser. The schema is in [the reference](profiling_reference.md#json-export).

## Capture GPU work

A GPU-enabled application adds `c3d_profile` to its core dependencies and selects `C3D_PROFILE_GPU`. Add
`C3D_PROFILE_INTERNAL` for automatic pass timing. A consumer of only the bundle's GPU module selects `c3d_profile`,
`gpu`, `vk`, `vma` and `spvreflect`, searching the installation's library directory and `gpu.c3l/lib`. The manifest
imposes no GPU dependency on CPU consumers.

Ordinary example targets compile no profiling. Build one explicitly:

```bash
python3 scripts/build.py --target shadows --lib c3d_profile --define C3D_PROFILE_GPU --define C3D_PROFILE_INTERNAL
./examples/build/shadows --gpu-timings
```

Use `shadows.exe` on Windows.

Requesting `RendererDesc.gpu_timings` in a build without GPU profiling returns `c3d::UNSUPPORTED`. Hardware without
graphics timestamps still renders and reports unavailable timings.

Create a recorder with `gpu_scopes_per_frame`, `frame_capacity` and `label_bytes_per_frame`, then set
`RendererDesc.profiler` to its stable address and `RendererDesc.gpu_timings = true`. A GPU-only descriptor omits the CPU
budget fields. A combined CPU and GPU build requires the CPU budgets and accepts a GPU capacity of zero for CPU-only
use; attaching such a recorder as a GPU sink faults with `profile::INVALID_ARGUMENT`. The recorder must outlive its
renderers and their pending submissions.

Inside `profile::@capture`, call `begin_frame`, record work, and call `end_frame`. Mark application intervals with
`render::@gpu_begin(&renderer, label)!` and `render::@gpu_end(&renderer, token)!`. Pair them in LIFO order within one
open recording and outside an active overlay borrow. Keep `defer catch render::abort_frame(&renderer)` after
`begin_frame`; when a recording fault is caught locally, abort the recording before continuing. A fault after a
successful submission does not discard its pending measurements.

- Labels are copied. The wrappers skip label evaluation when timing is disabled, unsupported or full, or when no
  application capture admitted the scope. INTERNAL scopes can still supply `Stats` with no capture sink. In a build with
  profiling off, both macros keep their optional `!` and `!!` syntax and discard their arguments.
- The renderer binds its configured recorder's capture at `begin_frame`. A nested CPU capture on another recorder cannot
  redirect it, and a capture opened later does not adopt part of an existing renderer recording.
- History slots stay pinned until their GPU results publish or the recording is canceled. A pin can last
  `render::FRAMES_IN_FLIGHT` renderer frames (2), so `frame_capacity` must exceed that count or steady-state captures
  drop. When every slot is pinned, `Recorder.dropped_frames` increases and the capture body runs unrecorded. The
  collector never waits for a GPU slot or resumes midway through a dropped capture.
- A capture can show completed GPU samples while other submissions are still `PENDING`. After the last pin releases, the
  GPU state is `ABORTED` if a recording was canceled, otherwise `TRUNCATED` on capacity loss, otherwise `UNAVAILABLE`
  when a source could not measure or none completed, otherwise `READY`. Separate flags and counters keep partial results
  and lower-priority outcomes. Disabling capture affects the next application capture; pending results still publish.
- `RendererDesc.gpu_scope_capacity` and `gpu_label_bytes_per_slot` bound pending storage independently of history. Zero
  selects 2048 scopes and 65536 label bytes per slot. Each scope reserves both timestamp queries at begin. The first
  query or label exhaustion stops admission until the next recording; accepted scopes still close and omitted scopes are
  counted. History copies a parent-complete prefix and keeps GPU truncation separate from CPU truncation. Disabled or
  unsupported instances allocate no recording arrays.
- The adapter reserves two timestamp queries per scope in every frame slot, plus scope, sample and label storage. At the
  defaults (`FRAMES_IN_FLIGHT` slots of 2048 scopes and 65536 label bytes) it requests about 960 KiB of host storage on
  x64 (416 KiB of scope storage and 64 KiB of labels per slot), a timestamp pool of 8192 queries and the backend's pool
  overhead. Size `gpu_scope_capacity` and `gpu_label_bytes_per_slot` down when that is too much. The figure excludes the
  retained capture history and the renderer's copied shadow summary.
- A frame that records no work at all (no view, dispatch, upload, overlay or preparation) discards its recording, and
  the capture reports it as aborted.

Each GPU sample has a source id, renderer frame, parent, origin, label and, where relevant, a copied view, pass, stage,
light or shader identity. GPU times are floating-point nanoseconds relative to the first accepted begin of that
`(source, renderer_frame)`. They are broad command intervals, not exclusive shader execution times. They are not
calibrated to CPU time and not aligned between renderers. Do not add a nested parent and its children into a total.

`Stats.gpu_pass_ms` sums every measured instance of each pass in the completed frame `gpu_frame_index`. GPU results may
describe an older frame than the current CPU counters. The statistics fields are in
[the reference](profiling_reference.md#gpu-statistics).

The headless `profile_gpu` example records two views and custom dispatches, drains its renderer, and prints a JSON
capture while its recorder is still alive:

```bash
python3 scripts/build.py --example profile_gpu
```

The manual device acceptance project is `test/gpu/profile`; see its [README](../test/gpu/profile/README.md).

## Inspect captures with ImGui

`gui::create_profiler_panel(allocator, &recorder)` creates one `gui::ProfilerPanel` for one stable recorder on its
owning thread. The panel borrows the recorder and allocates one fixed block, sized from the recorder's budgets; it
faults with `gui::PROFILE_STORAGE_OVERFLOW` if that size overflows. Refreshing and drawing perform no general-purpose
allocation and pin no capture slot. Call `gui::profiler_panel(&panel)` only inside an active ImGui frame. The panel
needs `C3D_PROFILE_GUI` and CPU or GPU profiling.

Order the lifetimes: create the recorder before any renderer attached to it, create the panel after the GUI renderer. At
shutdown, call `gui::destroy_profiler_panel`, finish and destroy the GUI, destroy the renderer (which drains and
detaches its GPU source), and then destroy the recorder. The recorder, its producers and the panel stay on one thread.

- **Live** follows the greatest retained frame id whose compiled domains have settled. A newer pending frame appears in
  the history without replacing the detail view. An expanded scope stays expanded across snapshots; the CPU and GPU
  trees identify a scope by its label path, with repeated sibling labels told apart by their order.
- **Pause**, or selecting any retained row (including a pending capture with a completed prefix), freezes an owned copy.
  The copy does not change when GPU publication completes or recorder slots are reused. **Reselect source frame**
  refreshes it from the same id; if that id was evicted, the panel keeps the copy and says so. **Resume** follows the
  latest settled capture again.
- The CPU and GPU axes fit the span from the earliest recorded begin to the latest recorded end; they are not
  application frame totals. The CPU axis also spans the worker samples, drawn one row per lane below the scopes;
  hovering a range shows its label, lane, duration and offset. CPU and GPU clocks are independent, and each GPU source
  and renderer-frame group has its own axis. A measured zero stays zero; absent data shows as N/A. Nested inclusive
  values overlap and must not be added. CPU summaries keep call counts, self-time completeness and upper bounds after
  truncation.
- GPU details show the exact source and renderer-frame ids and the view, pass, stage, light, layer and shader revision
  identity. The panel does not infer context from duration containment. It performs no file I/O; export stays
  `profile::capture_json`.

The windowed examples show the four modes:

```bash
python3 scripts/build.py --example profile_gui_cpu
python3 scripts/build.py --example profile_gui_internal
python3 scripts/build.py --example profile_gui_gpu
python3 scripts/build.py --example profile_gui
```

`profile_gui_cpu` captures application scopes. `profile_gui_internal` adds the library scopes beneath them.
`profile_gui_gpu` records application GPU work and the automatic renderer identities without inventing CPU durations.
`profile_gui` shows both domains on independent axes. Closing the panel removes only presentation work; capture and
frame submission continue. See [GUI](gui.md) for the ImGui integration.

## Measure overhead

Correctness tests do not establish instrumentation overhead. A claim needs a fixed workload, repeated runs, and a
comparison with capture and presentation independently disabled.
[Benchmarking](benchmarking.md#profiling-configurations-and-overhead) describes the protocol and the runner options that
build each configuration.

## Limits

- One recorder belongs to one writing thread; worker threads contribute through `add_worker_interval`.
- Capture storage is fixed. Exceeding a budget truncates the capture instead of growing it.
- GPU intervals are broad command intervals and need graphics timestamp support.
- No per-draw GPU scopes exist.
- A recorder attached to a renderer outlives that renderer and its pending submissions.

## See also

- [Profiling reference](profiling_reference.md): features, library scopes, descriptors, JSON schema and statistics
  fields.
- [Job pool](jobs.md): the producer of worker ranges.
- [Benchmarking](benchmarking.md): the benchmark runner and its profiling configurations.
- [GUI](gui.md): the ImGui integration the panel draws into.
- [Development](development.md): the profiler test targets and the manual GPU acceptance project.
