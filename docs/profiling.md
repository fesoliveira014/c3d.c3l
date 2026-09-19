# CPU profiling

`c3d_profile` is a separate, source-only C3 library in `addons/c3d_profile.c3l`.
It provides the `c3d::profile` module and requires only C3 0.8.3 and its standard
library. It can capture an application without loading c3d, creating a GPU
device, or linking SDL, ImGui or the renderer's native dependencies.

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

A c3d application adds `c3d_profile` to its existing dependencies. Core's
manifest does not require it. These are consumer-selected features:

| Features | Behavior |
| --- | --- |
| None | Profiling macros execute their bodies without evaluating profiling arguments. Collector types, storage, TLS and clocks are absent. |
| `C3D_PROFILE_CPU` | Application scopes and CPU capture/export. |
| `C3D_PROFILE_CPU`, `C3D_PROFILE_INTERNAL` | Application scopes plus library scopes. `Scene.update_world` is instrumented. |

Application source that imports `c3d::profile` keeps the package selected even
when CPU capture is compiled out; the package supplies its no-op macros. Core
itself builds with the package entirely absent when internal CPU profiling is
off. `C3D_PROFILE_INTERNAL` requires CPU or GPU profiling; this package currently
implements CPU capture. GPU collection and a profiler panel are not provided.

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
or scopes. The application owns the recorder's lifetime; c3d does not create
another recorder or advance the application's frame ids.

## Read captures and interpret bounds

`Recorder.frame(frame_id)` returns a borrowed `FrameCaptureView`. It returns
`profile::NOT_FOUND` for a missing, disabled, still-open or evicted frame. The
borrow remains valid until its history slot is reused. Consume the view
synchronously or export it before reuse; destroying the recorder also ends
all borrows.

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

Core's private instrumentation bridge calls the collector only when internal
CPU profiling is selected. The collector does not import core, the renderer or
GUI. A profiler panel belongs in a separate presentation package that consumes
captures and ImGui; the application calls it while its GUI context is active.
Neither the collector nor core needs to discover or invoke that panel.

## Verify the standalone package

These commands need no renderer dependencies or shader build tools:

```bash
c3c test profile_off --path addons/c3d_profile.c3l
c3c test profile_cpu --path addons/c3d_profile.c3l
c3c test profile_internal --path addons/c3d_profile.c3l
c3c run capture --path addons/c3d_profile.c3l
```

The full `python3 scripts/build.py --test` also runs these tests and the scene
integration targets. The default repository build builds the standalone
example; a targeted renderer example build stays scoped to that target.
