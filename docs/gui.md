# GUI overlay

`c3d::gui` is the Dear ImGui adapter. It owns one ImGui context, feeds it the window's input and records its draw data into
the renderer's overlay over the composed window. It is the only module that imports `imgui`; its backend submodule imports
`gpu`. The built-in scene, material, post, stats and targets panels are in [GUI panels](gui_panels.md).

## Quick start

```c3
import c3d::gui;
import c3d::platform;
import c3d::render;
import imgui;

GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!;
defer (void)gui::destroy_gui_renderer(&gui_renderer);

GuiPanelState panels;
while (window.poll()) {
    gui_renderer.new_frame();

    if (imgui::begin("Controls", null, {})) imgui::checkbox("Spin", &spin);
    imgui::end();
    gui::scene_panel(&scene, &panels);
    gui::stats_panel(&renderer)!;

    scene.update_world();
    gui_renderer.finish_frame();

    platform::sync_window(&window, &renderer);
    renderer.begin_frame(info)!;
    if (renderer.has_output) {
        renderer.render_view(&scene, camera_node, renderer.default_view)!;
        renderer.finish_view(renderer.default_view)!;

        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }
    renderer.end_frame()!;
}
```

Run the worked example with `python3 scripts/build.py --example cube_gui`. The same scene without a GUI is `cube`.

## Concepts

- **Ownership.** `GuiRenderer` owns the ImGui context, the font atlas texture and view, a sampler and a pipeline cache. It
  borrows the renderer and the window. Both stay at stable addresses until the GUI is destroyed. The supplied allocator owns
  c3d-side cache storage; ImGui keeps its native allocation policy.
- **Fonts.** ImGui's built-in font atlas is uploaded once at creation as an RGBA8 texture. The font is not an asset-store
  texture and `FontId` fonts do not apply to ImGui.
- **Input.** The adapter reads the window's translated event list, size, pixel density and clock. Nothing is forwarded by the
  application. ImGui receives keys with modifiers, text, mouse, wheel and focus events; gamepad events are not forwarded.
  ImGui copy and paste go through the platform clipboard. The adapter writes no `imgui.ini`.
- **Capture flags.** `new_frame()` sets `window.input.mouse_captured_by_gui` and `keyboard_captured_by_gui` independently
  from ImGui. Apply them before application controls: mouse capture suppresses orbit and wheel actions; keyboard capture
  suppresses keyboard controls such as movement, camera switches and quit keys. Native window close stays effective. A control that releases
  on a key, such as Escape, should remember whether the GUI held capture when the key went down, so cancelling a text edit
  does not also quit.
- **Text input.** `new_frame()` writes ImGui's text input want to `window.input.text_input_wanted_by_gui`. Other GUI layers,
  such as the game UI add-on, OR their own want into it after `new_frame()`. `finish_frame()` applies the combined want once
  through `Window.set_text_input`, so OS text input toggles only when the combined want changes. See
  [Windows and input](platform.md#gui-capture-flags).

## Create and destroy

`gui::create_gui_renderer(allocator, &renderer, &window)` needs a renderer with a configured window output and no open frame.
It uploads the font through the renderer and waits for the upload.

`gui::destroy_gui_renderer(&gui)` waits for renderer submissions before it releases GPU objects. Call it before destroying the
renderer or the window, with no GUI frame and no renderer frame open. If the wait fails, the optional result keeps ownership
with the caller to retry.

| Fault | Raised by |
| --- | --- |
| `CONTEXT_CREATE_FAILED` | `create_gui_renderer` when ImGui cannot create a context. |
| `FONT_BUILD_FAILED` | `create_gui_renderer` when ImGui cannot build the font atlas. |
| `UNSUPPORTED_INDEX_WIDTH` | `create_gui_renderer` when ImGui's index type is neither 16 nor 32 bits. |
| `gpu` and shader faults | Resource, pipeline and upload creation in `create_gui_renderer`; the wait in `destroy_gui_renderer`. |

## Frame sequence

1. Poll the window, then call `new_frame()`.
2. Apply controls and automatic motion, then draw GUI panels.
3. Call `scene.update_world()` so edits reach the current output.
4. Call `finish_frame()` to finalize ImGui's draw data.
5. Hand the window size to the renderer (`platform::sync_window`) and begin the renderer frame. When `renderer.has_output`,
   record `render_view` and `finish_view`, then `begin_overlay()`, `gui.record(&overlay)` and `end_overlay(&overlay)`. The view
   writes the window inside `finish_view`; the overlay draws over it.
6. End the renderer frame.

Always call `finish_frame()` after `new_frame()`, including for dormant or minimized windows and on an early exit.
`GuiRenderer.record` consumes finalized draw data; it does not close the GUI frame. The `cube_gui` example wraps the renderer
frame in a helper that calls `render::abort_frame` on error.

[Overlay lists](overlay.md) record in the same overlay before the GUI. Call `OverlayContext.draw_list` first and
`GuiRenderer.record` after it, so ImGui draws on top; the ImGui backend rebinds its own pipeline and state, so the list leaves
nothing for it to restore.

`begin_overlay()` opens a color pass that loads the composed window. Its `OverlayContext` borrows commands and frame
allocation access until `end_overlay()`. Storage obtained through `overlay.alloc()` survives until GPU completion. A recorder
must not free those slices, reset the frame arena, submit or present.

## Textures and callbacks

- The backend copies ImGui's 20-byte vertices and native-width indices into frame storage. Each command keeps its own
  vertex and index offset, texture and clip rectangle. Display origin and framebuffer scale come from ImGui's draw data; they
  are not interchangeable with the platform's framebuffer-pixel mouse coordinates.
- A texture reference names a live, ordinary 2D sampled view on this renderer, by its view index. The adapter registers its
  own font view. HDR, depth and cube images need an explicit visualization path, such as the
  [targets panel](gui_panels.md#targets-and-cluster-panel), before they serve as ordinary GUI images.
- Draw callbacks run in command order, and the backend restores its graphics state afterward. ImGui's legacy reset-state
  marker restores the state without being invoked. A list holding only callbacks still runs. The newer standard callback slots
  in ImGui's platform interface are not registered. Callbacks borrow their list and command and must not submit or present.

## Rebuild the native archive

The adapter links the c3imgui native archive: `lib/c3imgui.c3l/linked-libs/linux-x64/libdcimgui.a` on Linux and
`windows-x64/dcimgui.lib` on Windows. `python3 scripts/build.py --init-deps` downloads it from the c3imgui release at the
submodule's pinned tag. The Linux release archive is built on Ubuntu 22.04 and references no glibc symbol newer than 2.35.

On Linux, rebuild the archive on a host with an older glibc, where linking the release archive fails with undefined libc
symbols, or to change the Dear ImGui build. Install `clang`, `cmake`, a build tool, Python 3 with `venv`, `git` and the OpenGL
development headers (`libgl-dev`). Then, from `lib/c3imgui.c3l`:

```bash
bash scripts/bootstrap.sh
bash scripts/generate.sh
git clone --depth 1 --branch release-3.4.16 https://github.com/libsdl-org/SDL.git vendor/sdl-src
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_C_COMPILER=clang \
    -DSDL3_INCLUDE_DIR="$PWD/vendor/sdl-src/include"
cmake --build build --parallel
cp build/libdcimgui.a linked-libs/linux-x64/libdcimgui.a
```

- `bootstrap.sh` fetches Dear ImGui at `v1.92.8-docking` and `dear_bindings` at a pinned revision into `vendor/`;
  `generate.sh` writes the C API sources into `generated/`. Both directories and `build/` are ignored by the submodule.
- The build needs the Vulkan headers. Install `libvulkan-dev`, or pass `-DVULKAN_INCLUDE_DIR=<Vulkan-Headers>/include` to
  `cmake -S . -B build`.
- Keep the C3 declarations of the pinned package. Do not patch symbols or edit the generated bindings to work around a libc
  mismatch.
- `--init-deps` downloads the release archive again and overwrites the local one. Rebuild and copy it afterward on that host.

## Limits

- One ImGui context per `GuiRenderer`; the adapter enables no dynamic font or texture updates and no multiple platform
  viewports.
- Gamepad input does not reach ImGui.

## See also

- [GUI panels](gui_panels.md) for the built-in panels and what the stats panel counts.
- [Windows and input](platform.md) for capture flags and text input.
- [Overlay list](overlay.md) for application-drawn 2D items that draw before the GUI.
- [Profiling](profiling.md#inspect-captures-with-imgui) for the profiler panel, and the
  [physics inspector](physics_inspector.md) for the physics panel.
- [Development](development.md#native-libraries) for the other native libraries.
