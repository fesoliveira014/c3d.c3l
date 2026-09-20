# Profiling

`c3d_profile` is a separate, source-only C3 library in `addons/c3d_profile.c3l`.
It provides CPU and GPU capture in one bundle. CPU-only use of `c3d::profile`
requires just C3 0.8.3 and its standard library: no core, device, SDL or ImGui.
The feature-gated GPU module uses gpu.c3l and integrates with renderer timing.
`c3d_profile_gui`, in `addons/c3d_profile_gui.c3l`, is a separate optional
ImGui presentation package for those captures.

## Select the package and features

An application using the repository's library directory selects the package
explicitly:

```json
{
  "dependency-search-paths": ["path/to/c3d.c3l/lib"],
  "dependencies": ["c3d_profile"],
  "features": ["C3D_PROFILE_CPU"]
}
```

For a standalone installation, copy `addons/c3d_profile.c3l` into the
application's own library directory and search that directory. The bundle's
manifest selects its `src/**` files and declares no other packages or native
libraries. Its tests and example are outside that source selection.

To display the profiler panel, also install `addons/c3d_profile_gui.c3l` and
select both add-ons. A CPU panel consumer selects the pinned ImGui package and
its Vulkan binding even though the panel creates no device: the ImGui package's
compiled backend imports `vk`. For example:

```json
{
  "dependency-search-paths": ["path/to/c3d.c3l/lib", "path/to/c3d.c3l/lib/gpu.c3l/lib"],
  "dependencies": ["c3d_profile_gui", "c3d_profile", "c3imgui", "vk"],
  "features": ["C3D_PROFILE_GUI", "C3D_PROFILE_CPU"],
  "wincrt": "static"
}
```

Linux consumers link the C++ runtime used by the pinned ImGui archive; the
add-on manifest supplies that link requirement. Windows consumers use
the pinned packages' static CRT. A full windowed c3d application also ships
the SDL3 runtime beside its executable. GPU panel consumers additionally select
`gpu`, `vma` and `spvreflect` and enable `C3D_PROFILE_GPU`.

A c3d application adds `c3d_profile` to its existing dependencies. Core's
manifest does not require it. These are consumer-selected features:

| Features | Behavior |
| --- | --- |
| None | Bodies run without evaluating profiling arguments. Collector storage, TLS, clocks and GPU queries are absent; the small skipped GPU token remains available. |
| `C3D_PROFILE_CPU` | Application scopes and CPU capture/export. |
| `C3D_PROFILE_CPU`, `C3D_PROFILE_INTERNAL` | Application scopes plus the library scopes listed under Library scopes. |
| `C3D_PROFILE_GPU` | Explicit application GPU scopes and completed capture history. |
| `C3D_PROFILE_GPU`, `C3D_PROFILE_INTERNAL` | Automatic frame/view/pass/shadow-layer/custom-dispatch intervals and Stats. |
| CPU + GPU + INTERNAL | Both domains in one application capture; independent clocks. |

Application source that imports `c3d::profile` keeps the package selected even
when CPU capture is compiled out; the package supplies its no-op macros. Core
itself builds without the package when GPU profiling and internal CPU profiling
are off. `C3D_PROFILE_INTERNAL` requires CPU or GPU profiling.
`C3D_PROFILE_GUI` also requires CPU or GPU profiling and adds no declarations
when it is absent. Per-draw graphics scopes are not provided.

### Library scopes

With CPU and INTERNAL profiling, c3d records these LIBRARY scopes beneath the
application scope that encloses the call. Labels are fixed; a child label is
nested under the entry point that contains it. No loop records one scope per
item, so the sample count per frame depends on code structure, not on scene
size.

| Entry point | Label | Region |
| --- | --- | --- |
| `Scene.update_world` | `scene.update_world` | world matrices and effective visibility |
| `anim::update` | `anim.update` | every animator advance and blend |
| `Renderer.begin_frame` | `renderer.begin_frame` | the whole call |
| | `renderer.present` | presentation of a pending window output |
| | `renderer.wait_slot` | completion wait for the reused frame slot |
| | `renderer.readback` | completed GPU profile and cluster statistics |
| | `renderer.retire` | retired resource drain and mirror sweeps |
| | `renderer.acquire_output` | window output recovery and acquisition |
| `Renderer.render_view` | `renderer.render_view` | the whole call |
| | `view.extract` | mesh candidate extraction and culling |
| | `view.resolve` | geometry, material, skin and morph resolution into draw items |
| | `view.sort` | draw list sorting |
| | `view.uploads` | scene color, environment resolution, pending copies, sampled targets |
| | `view.lights` | light extraction, shadow recording, light and cluster upload |
| | `view.roots` | frame root and draw root writes |
| | `view.record` | scene pass, sky, transmission, transparent, debug and motion-blur recording |
| `Renderer.finish_view` | `renderer.finish_view` | depth of field, view output, post chain closure |
| `Renderer.end_frame` | `renderer.end_frame` | the whole call |
| | `renderer.submit` | pending copies, upload flush, command list end and submission |
| | `renderer.present` | window presentation |
| `Renderer.prepare_scene` | `renderer.prepare_scene` | the whole call |
| `Renderer.prepare_model` | `renderer.prepare_model` | the whole call |
| `Renderer.upload_texture` | `renderer.upload_texture` | the whole call |

`renderer.present` appears under both frame boundaries; summaries count both.
`Renderer.render` adds no scope of its own. First-use resource work inside a
warm `render_view`, such as an asset revision bump, is attributed to
`view.resolve`; cold preparation is attributed to the `prepare_*`,
`upload_texture` and `view.uploads` scopes.

Budget guidance for `RecorderDesc`: one animated scene with one view records at
most 19 library samples per frame (`anim.update` 1, `begin_frame` 6,
`render_view` 8, `finish_view` 1, `end_frame` 3) plus one per `prepare_*` or
`upload_texture` call, at depth 2 beneath the enclosing application scope.
Each additional view adds 9. Size `cpu_scopes_per_frame` for the application
scopes plus that count, and `max_depth` for the application nesting plus 2.

## Capture application work

Construct one `profile::Recorder` per writing thread with an allocator and a
`RecorderDesc`. Set `frame_capacity`, `cpu_scopes_per_frame`, `max_depth` and
`label_bytes_per_frame` explicitly. Each must be nonzero; depth cannot exceed
the scope capacity. Invalid budgets or allocation-size overflow return
`profile::INVALID_ARGUMENT`. Allocator exhaustion follows the allocator's
existing behavior.

Wrap the application frame in `profile::@capture(&recorder, frame_id)` and
individual operations in `profile::@scope("label")`. Bodies execute exactly
once, including when capture is disabled or full. Keep creation, lookup and
export inside the CPU feature selection; the body macros can remain in shared
application source. The standalone example demonstrates a complete lifecycle:

```bash
c3c run capture --path addons/c3d_profile.c3l
```

`@capture` installs this recorder for the calling thread and restores the
previous recorder on normal exit, early return and propagated faults. Captures
on different recorders may nest. A disabled inner capture masks the outer
recorder while its body runs. Capturing twice concurrently on the same recorder
is a programming error. Frame ids increase strictly for that recorder, including
disabled captures; zero is a valid first id.

Labels are copied into bounded capture storage. The caller can reuse its label
buffer after a scope begins. A label is evaluated only when the collector
attempts to admit its scope; a label too large for the remaining arena is
evaluated once to determine that it does not fit. Hot scopes do not allocate
from a general-purpose allocator.

The recorder owns its storage, must stay at a stable address while capturing,
and must not be copied. Call `profile::destroy_recorder` with no active capture
or scopes, attached renderers or pending GPU captures. The application owns the recorder's lifetime; c3d does not create
another recorder or advance the application's frame ids.

## Read captures and interpret bounds

`Recorder.frame(frame_id)` returns a borrowed `FrameCaptureView`. It returns
`profile::NOT_FOUND` for a missing, disabled, still-open or evicted frame. The
borrow remains valid until its history slot is reused or GPU publication mutates
that capture. Reacquire views after renderer completion collection. Consume or
export them synchronously; recorder destruction ends every borrow.

Samples retain begin order, parent index, application/library origin, label,
start offset, inclusive duration and self time. Times are integer nanoseconds
from the frame's monotonic CPU origin. Self time subtracts direct children's
inclusive durations once. Repeated labels remain separate events, so consumers
can aggregate call counts without losing the original hierarchy.

The first sample, nesting or label-budget overflow marks the capture truncated.
It stops admitting new scopes until the next frame, counts omitted scopes and
continues application work. Accepted scopes still close. Subsequent omitted
scopes do not evaluate labels or read scope clocks.

`self_complete` is false on open ancestors affected by an omitted scope.
Their `self_ns` is a residual upper bound, not an exact exclusive duration.
Display or compare it as incomplete. Already completed unaffected samples keep
their valid self times. Call counts from a truncated capture are partial.

Closed CPU captures are `READY`, `TRUNCATED` or `ABORTED`. A fault leaving the
capture sets `ABORTED`, preserving the separate truncation flag and omitted
count if both occurred. A fault caught inside the capture does not abort it.

`Recorder.set_enabled` selects recording for the next capture. Changing it
inside a capture does not cut off that capture. Disabled captures do not evict
retained history.

## Export and storage

`profile::capture_json(allocator, frame)` returns an owned String; release it
through that allocator. The exported string outlives the borrowed capture and
recorder. Export performs no file I/O. The example prints JSON to stdout and
the recorder's backing-storage byte count to stderr, so stdout can be redirected
to a capture file.

The JSON envelope uses schema `c3d.profile`, version `1`, compiled `cpu` and
`internal` feature availability, and a `frames` array containing the selected
frame. Each frame preserves CPU state, truncation, omitted count and its `cpu`
sample array. All sample fields, including `self_complete`, are retained.
Output is deterministic for an unchanged capture. Integer text retains all
64 bits; consumers that need exact values beyond 2^53 must use an
integer-preserving JSON parser.

The example budgets 120 retained frames, 2048 scopes per frame, depth 64 and
64 KiB of labels per frame. `Recorder.allocated_bytes` reports requested
backing-storage bytes, excluding allocator overhead and the Recorder value.
On x64, those example budgets allocate 23,600,896 bytes (about 22.5 MiB).
Budgets are constructor choices and storage never grows during recording.

## Package composition

The neutral `c3d::profile` module imports only the standard library. The same
bundle contains `c3d::render::profile_gpu`, selected only for GPU profiling; it
imports gpu.c3l and neutral capture values, with no core Renderer/Scene types.
Core bridges supply copied identities and completion hooks. This keeps the
package dependency direction one-way. The separate `c3d_profile_gui` adapter
extends `c3d::gui` and imports only neutral capture values, ImGui and the standard
library. Neither collector nor core discovers or invokes it.

## Inspect captures with ImGui

Create one `gui::ProfilerPanel` for one stable recorder on their owning thread.
The panel borrows the recorder and allocates one fixed block from the supplied
allocator; its capacity comes from the recorder's budgets. Panel refresh and
drawing perform no general-purpose c3d allocation and do not pin capture slots
or own native resources. Call `gui::profiler_panel` only inside an active ImGui
frame. Data selection helpers do not require a GUI frame.

Create the recorder before any renderer attached to it. After creating the GUI
renderer, create the panel. At shutdown, destroy the panel, finish and destroy
the GUI, destroy the renderer so it drains and detaches its GPU source, and then
destroy the recorder. The recorder, its producers and panel remain on one thread.

In Live mode, the panel follows the greatest retained frame id whose compiled
domains are settled. A newer pending frame remains visible in history without
replacing the detail snapshot. Pause freezes the owned snapshot immediately.
Selecting any retained row, including a pending capture with a completed prefix,
also freezes it while history continues to advance. The frozen copy does not
change when GPU publication completes or recorder slots are reused. `Reselect
source frame` refreshes it from the same id; if that id was evicted, the panel
keeps the frozen copy and reports the eviction. Resume follows the latest settled
capture again.

CPU and GPU axes fit the measured scope span from the earliest recorded begin to
the latest recorded end. They are not application wall-frame totals. CPU and GPU
clocks are independent, and each GPU source/renderer-frame group has its own
axis. A measured zero remains zero; absent data is N/A. Nested inclusive values
overlap and must not be summed as total time. CPU summaries retain call counts,
self-time completeness and upper bounds after truncation.

GPU details preserve exact source and renderer-frame ids plus captured view,
pass, light, layer and shader revision identity. The panel does not infer context
from duration containment. Export remains `profile::capture_json`; the panel
does not perform file I/O.

The four worked windowed modes are:

```bash
python3 scripts/build.py --example profile_gui_cpu
python3 scripts/build.py --example profile_gui_internal
python3 scripts/build.py --example profile_gui_gpu
python3 scripts/build.py --example profile_gui
```

The CPU mode captures application scopes. The internal CPU mode also shows
the library scopes nested beneath them. The GPU mode records application GPU work and automatic
renderer identities without inventing CPU durations. The combined mode shows
both domains on independent axes. Closing the panel only removes presentation
work; capture and frame submission continue. Correctness tests do not establish
instrumentation overhead. An overhead claim requires a fixed workload, repeated
measurements and comparison with capture and presentation independently disabled.

## Verify the standalone package

These commands need no renderer dependencies or shader build tools:

```bash
c3c test profile_off --path addons/c3d_profile.c3l
c3c test profile_cpu --path addons/c3d_profile.c3l
c3c test profile_internal --path addons/c3d_profile.c3l
c3c run capture --path addons/c3d_profile.c3l
```

The full `python3 scripts/build.py --test` also runs these tests, the profiler
panel data targets and the scene integration targets. The default repository
build builds the standalone example and all four windowed profiler targets; a
targeted renderer example build stays scoped to that target. Automated panel
tests create neither a device nor a window.

## Capture GPU work

GPU-enabled applications add `c3d_profile` to their existing core dependencies
and select `C3D_PROFILE_GPU`; add `C3D_PROFILE_INTERNAL` for automatic pass timing.
A consumer of just the bundle's GPU module selects `c3d_profile`, `gpu`, `vk`,
`vma` and `spvreflect`, searching both the installation's library directory and
`gpu.c3l/lib`. The package manifest imposes no GPU dependency on CPU consumers.
Native Windows GPU consumers use the backend's static CRT configuration.

To enable pass timing in an existing example, build it explicitly:

```bash
c3c build shadows --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL
./examples/build/shadows --gpu-timings
```

Use the equivalent `.exe` path on Windows. Ordinary example targets do not
compile profiling. Requesting `RendererDesc.gpu_timings` in an excluded build
returns `c3d::UNSUPPORTED`; unsupported graphics timestamp hardware still renders
and reports unavailable timings.

Create a recorder with `gpu_scopes_per_frame`, `frame_capacity` and
`label_bytes_per_frame`, then set `RendererDesc.profiler` to its stable address
and `gpu_timings = true`. GPU-only descriptors omit CPU budget fields. Combined
CPU/GPU builds require CPU budgets and accept GPU capacity zero for CPU-only
use; attaching that recorder as a GPU sink returns `profile::INVALID_ARGUMENT`.
The recorder must outlive its renderers and their pending submissions.

Within `profile::@capture`, call `begin_frame`, record work, and call `end_frame`.
Use `render::@gpu_begin(&renderer, label)!` and `render::@gpu_end(&renderer, token)!`
for application intervals. Pair them in LIFO order within one open recording,
outside an active overlay borrow. Keep `defer catch render::abort_frame(&renderer)`
after `begin_frame`; if a recording fault is caught locally, abort that recording
before continuing. A fault after successful submission does not discard its
pending measurements.

Labels are copied. The wrappers skip label evaluation when timing is disabled,
unsupported, full, or lacks an admitted application capture. INTERNAL scopes
can still supply Stats with a null capture sink. In all-off builds both wrapper
calls retain optional `!`/`!!` syntax and discard their arguments.

The renderer binds its configured recorder's capture at `begin_frame`. Nested
CPU captures on another recorder cannot redirect it, and a capture opened later
does not adopt part of an existing renderer recording. History slots remain
pinned until their GPU results publish or the recording is canceled. A pin can
last `FRAMES_IN_FLIGHT` renderer frames, so `frame_capacity` must exceed that
count (currently 2) or steady-state captures drop. If all slots are pinned,
`Recorder.dropped_frames` increases and the capture body runs unrecorded. The
collector never waits for a GPU slot or resumes midway through that dropped
capture.

A capture may expose completed GPU samples while other submissions remain
`PENDING`. After the last pin releases, GPU state is `ABORTED` if a recording was
canceled, otherwise `TRUNCATED` on capacity loss, otherwise `UNAVAILABLE` when a
source could not measure or none completed, otherwise `READY`. Separate flags
and counters preserve partial results and lower-priority outcomes. Disabling
capture affects the next application capture; pending results still publish.

`RendererDesc.gpu_scope_capacity` and `gpu_label_bytes_per_slot` bound pending
storage independently of history. Zero selects 2048 scopes and 65536 label bytes
per native slot. Both timestamp ends are reserved at begin. The first query or
label exhaustion stops admission until the next recording; accepted scopes
still close, and omitted scopes are counted. History copies a parent-complete
prefix and keeps GPU truncation separate from CPU truncation.

On x64, the default adapter requests 983,296 host bytes for its two slots, plus
a 192-byte owning value and backend pool overhead. Its pool holds 8192 timestamp
entries. Disabled or unsupported instances allocate no recording arrays. This
excludes retained capture history and the renderer's copied shadow summary.

Each GPU sample has a source id, renderer frame, parent, origin, label and copied
view/pass/light/shader identity where relevant. GPU nanoseconds are floating
point, relative to the first accepted begin in that `(source, renderer_frame)`.
They are broad command intervals, not exclusive shader execution times. They
are neither calibrated to CPU time nor aligned between renderers. Do not sum
nested parents and children as a total.

## GPU summaries and export

`Stats.gpu_pass_ms` sums every measured instance of each pass in the completed
`gpu_frame_index`: two views taking 2 ms and 3 ms contribute 5 ms. Frame, view,
application and shadow-layer parents/children do not inflate those buckets.
Custom dispatches each have their own interval and keep the active successful
shader revision, including fallback after a rejected replacement. `POST_CHAIN`
is split into contiguous render/finish segments under its single pass bucket.

`gpu_pass_valid` distinguishes an absent measurement from a measured zero.
`gpu_timing_state` distinguishes unavailable, pending, ready and truncated data;
`gpu_scopes_dropped` counts omitted intervals. The latest completed summary
survives CPU/work-counter reset while newer results are pending. GPU results
may therefore describe an older frame than the current CPU counters.
`shadow_timings` retains every measured layer instance with its original ViewId.
The fixed-layout `pass_timestamp_slot` helper remains compatibility arithmetic;
it does not locate the dynamic profiler's queries.

GPU-enabled JSON extends schema version 1 with GPU feature availability, state,
counts and completed samples. GPU-only captures have unavailable, empty CPU
lanes. CPU-only output remains unchanged. Export owns its text, so subsequent
GPU publication does not mutate an earlier export.

The worked headless example records two views and custom dispatches and drains
its renderer before exporting, while its recorder is still alive:

```bash
python3 scripts/build.py --example profile_gpu
c3c test acceptance --path test/gpu/profile
```

The second command runs manual Vulkan acceptance and is outside CI. Both use
validation. The existing renderer can discard recordings containing only
non-view work (for example, a warm compute-only frame); profiling reports such
recordings as aborted and never makes timestamp writes count as rendering work.
Use explicit `render_view`/`finish_view` calls for the example workload.

GPU-enabled add-on data tests require backend libraries, but create no device:

```bash
c3c test profile_gpu --path addons/c3d_profile.c3l
c3c test profile_gpu_internal --path addons/c3d_profile.c3l
c3c test profile_cpu_gpu --path addons/c3d_profile.c3l
c3c test profile_full --path addons/c3d_profile.c3l
```

`profile_full` selects CPU + GPU + INTERNAL; it does not enable a profiler GUI.
The repository build compiles the GPU example and runs these deterministic tests
on Linux and Windows. Hardware acceptance and performance measurements remain
separate; successful correctness tests do not establish instrumentation overhead.
