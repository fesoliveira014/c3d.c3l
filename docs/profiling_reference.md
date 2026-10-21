# Profiling reference

Reference tables for [profiling](profiling.md): the features, the library scopes and their sample budget, the
descriptors, the capture types, the JSON export and the GPU statistics.

## Features

| Feature | Requires | Effect |
| --- | --- | --- |
| `C3D_PROFILE_CPU` | | Application scopes, CPU capture and export. |
| `C3D_PROFILE_GPU` | | Application GPU scopes, completed GPU capture history, `Stats` GPU fields. Compiles `c3d::render::profile_gpu`. |
| `C3D_PROFILE_INTERNAL` | CPU or GPU | CPU: the library scopes below. GPU: automatic frame, view, pass, pass-stage, shadow-layer and custom-dispatch intervals. |
| `C3D_PROFILE_GUI` | CPU or GPU | The `c3d_profile_gui` panel in `c3d::gui`. Adds no declarations when absent. |

The test targets of the standalone package are `profile_off`, `profile_cpu`, `profile_internal`, `profile_gpu`,
`profile_gpu_internal`, `profile_cpu_gpu` and `profile_full`; `profile_full` selects CPU, GPU and INTERNAL and no GUI.
The GPU targets need the backend libraries and create no device. The panel's data targets are `panel_off`, `panel_cpu`,
`panel_gpu` and `panel_combined`. See [development.md](development.md#test-targets).

## Library scopes

With CPU and INTERNAL profiling, c3d records these `LIBRARY` scopes beneath the application scope that encloses the
call. Labels are fixed, and a child label nests under the entry point that contains it. No loop records one scope per
item, so the sample count per frame follows code structure, not scene size.

| Entry point | Label | Region |
| --- | --- | --- |
| `Scene.update_world` | `scene.update_world` | World matrices and effective visibility. |
| `anim::update` | `anim.update` | Every animator advance and blend. |
| `Renderer.begin_frame` | `renderer.begin_frame` | The whole call. |
| | `renderer.present` | Presentation of a pending window output. |
| | `renderer.wait_slot` | Completion wait for the reused frame slot. |
| | `renderer.readback` | Completed GPU profile, cluster, exposure, focus and cull statistics. |
| | `renderer.retire` | Retired resource drain and mirror sweeps. |
| | `renderer.texture_residency` | The texture residency step. |
| | `renderer.acquire_output` | Window output recovery and acquisition; window renderers only. |
| `Renderer.render_view` | `renderer.render_view` | The whole call. |
| | `view.extract` | Mesh candidate extraction and culling. |
| | `view.resolve` | Geometry, material, skin and morph resolution into draw items. |
| | `view.sort` | Draw list sorting. |
| | `view.layers` | Splitting scene-reading draws into transmission layers; only with more than one transmission layer. |
| | `view.decals` | Decal extraction and packing. |
| | `view.uploads` | Scene snapshot images, environment resolution, pending copies, sampled targets. |
| | `view.trace` | Scene trace preparation; only for a view with traced effects. |
| | `view.lights` | Light extraction, shadow recording, light and cluster upload. |
| | `view.light_spatial` | Light BVH build and upload; a child of `view.lights` in a clustered or path-traced view. |
| | `view.light_spatial.build` | The BVH build, child of `view.light_spatial`. |
| | `view.light_spatial.upload` | The BVH upload, child of `view.light_spatial`. |
| | `view.roots` | Frame root and draw root writes. |
| | `view.record` | Scene pass, sky, scene snapshots and reads, transparent, debug and motion-blur recording. |
| `Renderer.finish_view` | `renderer.finish_view` | Depth of field, view output, post chain closure. |
| `Renderer.end_frame` | `renderer.end_frame` | The whole call. |
| | `renderer.submit` | Upload flush, command list end and submission. |
| | `renderer.present` | Window presentation. |
| `Renderer.prepare_scene` | `renderer.prepare_scene` | The whole call. |
| `Renderer.prepare_model` | `renderer.prepare_model` | The whole call. |
| `Renderer.upload_texture` | `renderer.upload_texture` | The whole call. |

- `view.layers` is a sibling of `view.sort`, and `view.trace` a sibling of `view.uploads`; both sit directly under
  `renderer.render_view`.
- A path-traced view records only `view.uploads`, `view.trace`, `view.lights`, `view.roots` and `view.record`, and
  always records `view.trace` and `view.light_spatial`.
- Probe-volume fills and reflection passes also record `view.light_spatial` when they upload light data.
- `renderer.present` appears under both frame boundaries; summaries count both.
- `end_frame` records pending copies and environment preparations before it decides whether to submit. That work belongs
  to `renderer.end_frame`, not to `renderer.submit`.
- `Renderer.render` adds no scope of its own. First-use resource work inside a warm `render_view`, such as an asset
  revision bump, belongs to `view.resolve`. Cold preparation belongs to the `prepare_*`, `upload_texture` and
  `view.uploads` scopes.

### Sample budget

Upper bounds for one frame with one animated scene and one raster view with the clustered light mode and traced effects:

| Source | Library samples |
| --- | --- |
| `scene.update_world` | 1 |
| `anim.update` | 1 |
| `renderer.begin_frame` and its children | 7 |
| `renderer.render_view` and its children | 14 |
| `renderer.finish_view` | 1 |
| `renderer.end_frame` and its children | 3 |
| Each `prepare_scene`, `prepare_model` or `upload_texture` call | 1 |
| Each additional view | 15 |

A window-less renderer records one fewer sample in `begin_frame` and `end_frame`. Probe fills and reflection passes add
three `view.light_spatial` samples each. Size `cpu_scopes_per_frame` for the application scopes plus these counts, with
margin. The library scopes nest at most four deep (`renderer.render_view`, `view.lights`, `view.light_spatial`,
`view.light_spatial.build`), so size `max_depth` for the application nesting plus 4.

## Descriptors

### `profile::RecorderDesc`

| Field | Feature | Meaning |
| --- | --- | --- |
| `frame_capacity` | any | Retained captures. Must be nonzero. With GPU profiling it must exceed `render::FRAMES_IN_FLIGHT` (2) for steady-state capture. |
| `cpu_scopes_per_frame` | CPU | CPU scopes per capture. Nonzero. |
| `max_depth` | CPU | Maximum scope nesting. Nonzero and at most `cpu_scopes_per_frame`. |
| `worker_samples_per_frame` | CPU | Worker samples per capture. Zero keeps none. |
| `gpu_scopes_per_frame` | GPU | GPU samples per capture. Nonzero in a GPU-only build; zero in a combined build disables GPU sources. |
| `label_bytes_per_frame` | any | Copied label bytes per capture, shared by scopes and worker samples. Nonzero. |

`profile::create_recorder(allocator, desc)` faults with `profile::INVALID_ARGUMENT` for a zero required field, a depth
above the scope capacity or a size overflow. `Recorder.allocated_bytes` reports the requested backing-storage bytes,
excluding allocator overhead and the `Recorder` value.

### `RendererDesc` profiling fields

| Field | Meaning |
| --- | --- |
| `gpu_timings` | Enables GPU timestamps. Faults `c3d::UNSUPPORTED` in a build without `C3D_PROFILE_GPU`. |
| `profiler` | Stable `profile::Recorder*` that receives GPU captures (`C3D_PROFILE_GPU` only). May be null. |
| `gpu_scope_capacity` | GPU scopes per frame slot. Zero selects 2048. |
| `gpu_label_bytes_per_slot` | Label bytes per frame slot. Zero selects 65536. |

## Recorder API

| Name | Meaning |
| --- | --- |
| `profile::@capture(&recorder, frame_id)` | Runs a body in one capture. `frame_id` must exceed the last id of the recorder. |
| `profile::@scope("label")` | Runs a body in one application CPU scope. |
| `Recorder.frame(frame_id)` | Borrowed `FrameCaptureView`. Faults `profile::NOT_FOUND`. |
| `Recorder.frame_ids(storage)` | Copies retained ids in ascending order; `storage.len` must be at least `frame_capacity`. Returns the count. |
| `Recorder.set_enabled(enabled)` | Selects recording for the next capture. |
| `Recorder.add_worker_interval(lane, label, start_ns, end_ns)` | Stores a worker range in the open capture. |
| `Recorder.add_dropped_worker_intervals(count)` | Adds to the capture's dropped worker count. |
| `Recorder.dropped_frames` | Captures dropped because every history slot was pinned (GPU profiling). |
| `profile::capture_json(allocator, frame)` | Owned JSON text of one capture. |
| `profile::destroy_recorder(&recorder)` | Releases storage. Requires no open capture, scope, GPU source or pending pin. |
| `render::@gpu_begin(&renderer, label)`, `render::@gpu_end(&renderer, token)` | Application GPU interval. |
| `gui::create_profiler_panel(allocator, &recorder)`, `gui::profiler_panel(&panel)`, `gui::destroy_profiler_panel(&panel)` | The ImGui panel. |

| Fault | Raised by |
| --- | --- |
| `profile::INVALID_ARGUMENT` | `create_recorder` with an invalid descriptor; attaching a recorder with `gpu_scopes_per_frame` zero as a GPU sink. |
| `profile::NOT_FOUND` | `Recorder.frame` for a frame that is not retained and closed. |
| `profile::CAPACITY_EXCEEDED` | Attaching a GPU source after the recorder exhausted its source identities. |
| `gui::PROFILE_STORAGE_OVERFLOW` | `create_profiler_panel` when the panel size overflows. |

## Capture types

| `CaptureState` | Meaning |
| --- | --- |
| `PENDING` | The CPU capture is open, or a GPU recording has not published. |
| `READY` | Complete. |
| `TRUNCATED` | A budget ran out; the capture holds a prefix. |
| `ABORTED` | A fault or a canceled recording ended the capture. |
| `UNAVAILABLE` | The domain is not compiled in, a GPU source could not measure, or none completed. |

`FrameCaptureView` fields:

| Field | Meaning |
| --- | --- |
| `frame_id`, `cpu_state`, `truncated`, `dropped_cpu_scopes` | Identity and CPU outcome. |
| `cpu` | `CpuSample[]`: `label`, `origin` (`APPLICATION` or `LIBRARY`), `parent_index`, `has_parent`, `start_ns`, `duration_ns`, `self_ns`, `self_complete`. |
| `workers`, `dropped_worker_samples` | `WorkerSample[]`: `label`, `lane`, signed `start_ns`, `duration_ns`; and the dropped count. CPU feature. |
| `gpu_state`, `gpu_truncated`, `dropped_gpu_scopes`, `pending_gpu_frames`, `unavailable_gpu_frames`, `aborted_gpu_frames` | GPU outcome and counters. GPU feature. |
| `gpu` | `GpuSample[]`: `label`, `source`, `renderer_frame`, `info`, `parent_index`, `has_parent`, `start_ns`, `duration_ns` (floating point). GPU feature. |

`GpuScopeInfo.kind` is `APPLICATION`, `FRAME`, `VIEW`, `PASS`, `SHADOW_LAYER`, `COMPUTE_DISPATCH` or `PASS_STAGE`; the
other fields identify the view, pass, stage, light, layer and shader revision.

## JSON export

`capture_json` writes one object with schema `c3d.profile`, version 1.

| Key | Content |
| --- | --- |
| `schema`, `version` | `"c3d.profile"` and `1`. |
| `features` | `cpu`, `internal` and, in a GPU build, `gpu` availability flags. |
| `frames` | An array with the one exported frame. |

Each frame holds `frame_id`, `cpu_state`, `truncated`, `dropped_cpu_scopes` and the `cpu` sample array with every sample
field, including `self_complete`. A GPU build adds `gpu_state`, `gpu_truncated`, `dropped_gpu_scopes`,
`pending_gpu_frames`, `unavailable_gpu_frames`, `aborted_gpu_frames` and the `gpu` array. A frame with worker samples or
dropped worker intervals also carries `dropped_worker_samples` and a `workers` array of `label`, `lane`, `start_ns` and
`duration_ns`; a frame with neither has neither key. GPU-only captures have empty CPU arrays. A sample's `pass_ordinal`
and `stage_ordinal` are ordinals of the producing build's `render::Pass` and of `render::EnvironmentStage` or
`render::PostStage`, as the pass says; match them across builds by `label`.

## GPU statistics

| `Stats` field | Meaning |
| --- | --- |
| `gpu_pass_ms` | Sum of every measured instance of each pass in the completed frame. Two views taking 2 ms and 3 ms contribute 5 ms. Frame, view, application, pass-stage and shadow-layer scopes do not inflate the buckets. |
| `gpu_environment_stage_ms` | Sum of the `PASS_STAGE` scopes inside `Pass.ENVIRONMENT` per `EnvironmentStage`. Parts of that pass's bucket. |
| `gpu_post_stage_ms` | Sum of the `PASS_STAGE` scopes inside `Pass.POST_CHAIN` per `PostStage` (`post.bloom`, `post.depth_of_field`, `post.motion_blur`). Parts of that pass's bucket. |
| `gpu_frame_index` | Renderer frame the GPU fields describe. It can trail the current CPU counters. |
| `gpu_pass_valid` | Per pass: a measured value (true) versus an absent measurement (false). A measured zero stays zero. |
| `gpu_timing_state` | `GpuTimingState`: `UNAVAILABLE`, `PENDING`, `READY` or `TRUNCATED`. |
| `gpu_scopes_dropped` | Intervals omitted from the completed summary. |
| `shadow_timings` | Every measured shadow layer instance with its original `ViewId`. |

The latest completed summary survives a reset of the CPU and work counters while newer results are pending. Custom
dispatches each have their own interval and keep the shader revision that was active and successful, including the
fallback after a rejected replacement. `POST_CHAIN` is split into contiguous render and finish segments under its single
pass bucket.
