# Profile add-on

`c3d_profile` captures CPU and GPU timing for c3d applications. A `Recorder` holds a fixed-size history of frame captures, scopes mark application work, and `capture_json` exports a frame. CPU-only use needs no core, device, SDL or ImGui. The GPU part records pass and view intervals when a renderer is attached.

| Module | Provides |
| --- | --- |
| `c3d::profile` | Recorder, scopes, frame history, worker ranges and JSON export; neutral values only |
| `c3d::render::profile_gpu` | GPU capture; private, in `src/gpu/`, present only under `C3D_PROFILE_GPU` |

## Boundaries

`c3d::profile` imports only the standard library. `c3d::render::profile_gpu` imports the standard library, gpu.c3l and neutral profile values, and never core types. Core reaches the package only through two gated bridges: `c3d::instrumentation` under `C3D_PROFILE_CPU` with `C3D_PROFILE_INTERNAL`, and `render/profile.c3` under `C3D_PROFILE_GPU`. Core has no unconditional profiler dependency. Applications and add-ons that record select the package explicitly. Its manifest declares no other package or native library.

## Select the package

List `c3d_profile` in `project.json` and enable the features you need; the [release guide](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/release.md) lists the names. Source that imports `c3d::profile` keeps the package selected even when capture is compiled out; the package supplies no-op macros then.

| Features | Behavior |
| --- | --- |
| none | Scope bodies run; collector storage and clocks are absent |
| `C3D_PROFILE_CPU` | Application scopes and CPU capture and export |
| `C3D_PROFILE_CPU`, `C3D_PROFILE_INTERNAL` | Also the library scopes inside core |
| `C3D_PROFILE_GPU` | Application GPU scopes and completed capture history; also select `gpu`, `vk`, `vma`, `spvreflect` |
| `C3D_PROFILE_GPU`, `C3D_PROFILE_INTERNAL` | Automatic frame, view, pass, pass-stage, shadow-layer and custom-dispatch intervals |

`C3D_PROFILE_INTERNAL` needs `C3D_PROFILE_CPU` or `C3D_PROFILE_GPU`.

## Quick start

```c3
profile::Recorder recorder = profile::create_recorder(mem, {
    .frame_capacity = 120,
    .cpu_scopes_per_frame = 2_048,
    .max_depth = 64,
    .label_bytes_per_frame = 65_536,
})!!;
defer profile::destroy_recorder(&recorder);

profile::@capture(&recorder, frame_id) {
    profile::@scope("simulation") {
        simulate();
    };
};

String json = profile::capture_json(mem, recorder.frame(frame_id)!!);
defer alloc::free(mem, json.ptr);
```

Create the recorder before any renderer attached to it and destroy it last. The recorder stays at a stable address while capturing.

## Targets and examples

| Target | Kind |
| --- | --- |
| `profile_off`, `profile_cpu`, `profile_internal` | CPU data tests; need no renderer dependency |
| `profile_gpu`, `profile_gpu_internal`, `profile_cpu_gpu`, `profile_full` | Data tests for the GPU feature combinations; none creates a device |
| `capture` | CPU example that prints a capture as JSON |

```bash
c3c test profile_cpu --path addons/c3d_profile.c3l
c3c run capture --path addons/c3d_profile.c3l
```

## Guides

- [Profiling](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/profiling.md): features, scopes, captures, export and GPU capture.
- [Profile panel add-on](https://github.com/fesoliveira014/c3d.c3l/blob/main/addons/c3d_profile_gui.c3l/README.md) for the ImGui presentation.
