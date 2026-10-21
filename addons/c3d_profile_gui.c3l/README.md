# Profile panel add-on

`c3d_profile_gui` shows `c3d_profile` captures in an ImGui panel: frame history, CPU scopes, worker ranges and GPU intervals, with live, paused and selected-frame views. It extends `c3d::gui`; every declaration exists only under `C3D_PROFILE_GUI`.

## Boundaries

The package imports the standard library, `c3d::profile` and `imgui`, and never core. It consumes neutral capture data and creates no GPU object or file I/O. Core, the collector and the packages it displays never import it. Its manifest names no dependency; consumers select the packages they display.

## Select the package

List `c3d_profile_gui`, `c3d_profile`, `c3imgui`, `sdl3` and `vk` in `project.json` and enable `C3D_PROFILE_GUI` with `C3D_PROFILE_CPU` or `C3D_PROFILE_GPU`; the [release guide](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/release.md) lists the names. With `C3D_PROFILE_GPU`, also select `gpu`, `vma` and `spvreflect`. A CPU-only panel creates no device, but the pinned ImGui package imports `vk`, so consumers list it.

## Quick start

```c3
gui::ProfilerPanel panel = gui::create_profiler_panel(mem, &recorder)!;
defer gui::destroy_profiler_panel(&panel);

// inside an active ImGui frame
gui::profiler_panel(&panel);
```

Create the panel after the recorder and the GUI renderer, and destroy it first. The panel borrows the recorder, allocates one fixed block from the allocator you pass, and performs no allocation when it refreshes or draws.

## Targets and examples

| Target | Kind |
| --- | --- |
| `panel_off`, `panel_cpu`, `panel_gpu`, `panel_combined` | Data tests for the feature combinations; none creates a device or a window |
| `profile_gui_cpu`, `profile_gui_internal`, `profile_gui_gpu`, `profile_gui` | Windowed examples in the repository's `examples/`; `python3 scripts/build.py --example profile_gui` |

## Guides

- [Profiling](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/profiling.md): the panel's modes and lifetimes.
- [Profile collector add-on](https://github.com/fesoliveira014/c3d.c3l/blob/main/addons/c3d_profile.c3l/README.md).
