# GUI overlay

`c3d::gui` provides an application-owned Dear ImGui overlay with scene, Basic material and
statistics panels. `cube_gui.c3` adds the overlay to the same scene as the first-mesh
`cube.c3` example. Run either example independently:

```bash
python3 scripts/build.py --example cube
python3 scripts/build.py --example cube_gui
c3c build cube_gui --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL
./examples/build/cube_gui --gpu-timings
```

In `cube_gui`, Spin starts off. Enabling it rotates from the current pose; pausing preserves
that pose for editing. Select a node in the scene tree to edit its local position, rotation in degrees,
nonzero scale, visibility and layer mask. The material panel edits the selected mesh's RGB
color; it advances the asset revision only after a change.

## Profiler panel

The optional `c3d_profile_gui` add-on extends `c3d::gui` with an owned
`ProfilerPanel`. Select `C3D_PROFILE_GUI` with at least one of
`C3D_PROFILE_CPU` or `C3D_PROFILE_GPU`, and select both `c3d_profile_gui` and
`c3d_profile`. Run the worked scene in any compiled mode:

```bash
python3 scripts/build.py --example profile_gui_cpu
python3 scripts/build.py --example profile_gui_internal
python3 scripts/build.py --example profile_gui_gpu
python3 scripts/build.py --example profile_gui
```

The example keeps capture and rendering active while the Profiler window is
hidden. Its panel supplies Pause and Resume, retained-frame selection and
explicit reselection of a frozen source frame. It uses the same GUI frame and
renderer overlay order as `cube_gui`; `gui::profiler_panel(&panel)` runs after
`new_frame()` and before `finish_frame()`.

Create the recorder before its renderer and keep both at stable addresses.
Create the panel after the GUI renderer. Destroy the panel before the GUI,
destroy the GUI before the renderer, and destroy the recorder only after the
renderer has drained and detached. One thread owns the recorder, its producers
and panel. The complete capture states, measured-span axes and frozen-snapshot
behavior are described in [Profiling](profiling.md#inspect-captures-with-imgui).

## Creation and ownership

Create the window, asset store and renderer first, then call
`gui::create_gui_renderer(allocator, &renderer, &window)`. The renderer must have a configured
window output and no open frame. Both borrowed objects stay at stable addresses until the
GUI is destroyed.

The adapter owns its ImGui context, SDL backend, fixed font atlas texture/view and pipeline
cache. Creation uploads the RGBA8 font through the renderer and waits for that upload.
The supplied allocator owns c3d-side cache storage; ImGui and SDL retain their native
allocation policy. The font is not an asset-store texture.

Call `gui::destroy_gui_renderer(&gui)` before destroying the renderer or window. It waits
for renderer submissions before releasing GPU objects. If waiting fails, the optional result
preserves ownership for the caller to retry. Finish any open GUI frame before destruction.

## Input and frame order

The adapter owns its ImGui platform side. `new_frame()` reads the window's translated event
list (`window.events()`), size, pixel density and clock, and feeds ImGui keys, modifiers, text,
mouse and focus from them; nothing is forwarded by the application. It starts and stops OS text
input through `Window.set_text_input` as widgets ask for it, and ImGui copy and paste go through
the platform clipboard wrappers. The platform helper does not import or own GUI.

Call `new_frame()` after polling. It sets `window.input.mouse_captured_by_gui` and
`keyboard_captured_by_gui` independently. Apply these gates before application controls:
mouse capture suppresses orbit/wheel actions; keyboard capture suppresses movement, lens
switches and keyboard quit actions. The example retains capture ownership from Escape down through its release, so cancelling
a text edit does not also quit. Native window close remains effective.

The frame sequence is:

1. Poll; begin the GUI frame.
2. Apply controls and automatic motion, then draw GUI panels.
3. Call `scene.update_world()` so edits reach the current output.
4. Call `gui.finish_frame()` to finalize native draw data.
5. Begin the renderer frame. When `renderer.has_output`, record
   `render_view(scene, camera, renderer.default_view)` and `finish_view(renderer.default_view)`,
   then `begin_overlay()`, `gui.record(&overlay)` and `end_overlay(&overlay)`. The view writes the
   window inside `finish_view`; the overlay draws over it.
6. End the renderer frame.

Always call `finish_frame()` after `new_frame()`, including dormant/minimized windows and
an early exit. GPU recording consumes finalized draw data; it does not close the GUI frame.
The `cube_gui.c3` example's private `draw_gui_frame` helper demonstrates error cleanup through
`render::abort_frame`.

`begin_overlay()` opens a color LOAD pass over the composed window. Its `OverlayContext`
borrows commands and frame allocation access until `end_overlay()`. Storage obtained through
`overlay.alloc()` survives until GPU completion. The adapter must not free those slices,
reset the frame arena, submit or present.

## Drawing contract

The backend copies ImGui's 20-byte vertices and native-width indices into frame storage.
Each command retains its own vertex/index offset, texture and clip rectangle. Display origin
and framebuffer scale come from ImGui draw data; they are not interchangeable with the
platform's framebuffer-pixel mouse coordinates.

Texture references must name live ordinary 2D sampled views on this renderer. The adapter
registers its fixed font view itself. Dynamic font/texture updates and multiple platform
viewports are not enabled. HDR, depth and cube images require an explicit visualization
path before use as ordinary GUI images.

The backend invokes ordinary draw callbacks and restores its graphics state afterward.
It also supports ImGui's legacy reset-state marker without invoking that sentinel. Callback-only
lists run even when they contain no geometry. The newer standard callback slots in PlatformIO
are not registered. Callbacks borrow their list/command and must not submit or present.

## Statistics

Draw totals include composition and GUI. Triangle totals include mesh and GUI geometry.
Asset upload bytes are not GPU resident memory. Ring usage reports the previous frame slot's head/capacity and overflow
allocation count separately; a dormant frame can also be the previous slot.

GPU timings are disabled by default and enabled at renderer creation with
`RendererDesc.gpu_timings`, or by the `cube_gui` example's `--gpu-timings` flag. Values come
from completed frame slots and may lag CPU counters. Build with the
[GPU profiling features](profiling.md#capture-gpu-work) before requesting them.
The panel shows the completed GPU frame, N/A for absent measurements and partial
status for truncated summaries; pass buckets sum all recorded views. Timestamp overhead
can be significant on WSL2 dzn; also compare ordinary rendering with timing disabled rather than subtracting
a fixed overhead. The memory panel displays the device's advisory per-heap usage, budget,
allocation and block sizes.

## Cluster diagnostics

Call `gui::targets_panel` before `begin_frame`: its Forward and Flat/Clustered controls
apply changes through `configure_view`. Deferred is visibly disabled because the API
rejects it with `UNSUPPORTED`. Configuration can propagate invalid-argument, unsupported,
allocation, recording and wait faults; do not treat the panel as an infallible display.
The [view contract](views.md#light-selection) describes the editable cluster settings.

For a clustered view, `Cluster slice` starts at zero and is clamped to the current slice
count. Expand `clusters` to see that depth slice's tile occupancy. Color is based on
stored finite-light count divided by per-cell capacity: blue is empty, intermediate
values add green, red is full, and **magenta marks overflow**. Globals are excluded.
This is a selected-slice heatmap, not the occupancy at visible surfaces or a readback
of the depth image. Overflow uses complete flat lighting, so magenta does not mean
lights were dropped.

Slice-depth labels use the active last-rendered camera mapping. Changing lighting mode,
depth-slice count or clustering far distance invalidates those labels; they read
`unavailable` until a successful render publishes matching depth data. An unchanged
configuration retains its labels. Inactive or unavailable cluster data clears the
preview instead of showing stale grid contents. A `VIEW_CLUSTERS` request requires a
live clustered view and an in-range slice (`PreviewSource.level`); a dead view faults
`INVALID_ID`, and a flat view or invalid slice faults `INVALID_ARGUMENT`.

The statistics panel labels cluster view, cell count and overflowing-cell count as
**Completed**. They arrive after frame-slot completion, can lag current controls and
CPU counters, and work with GPU timestamps disabled. With multiple views they follow
the [last-recorded-view policy](views.md#frames), not an aggregate. Timestamp-enabled
runs also show completed `LIGHT_CULL` and opaque GPU times. Cull time includes private
light upload/reset, assignment and counter copy; opaque time alone is not total cost.
Opening a preview adds work, so close it for the main timing comparison.

The [many-lights example](many_lights.md) combines these panels with fixed workload
presets, range/capacity controls, camera reset and separate wall-interval reporting.
