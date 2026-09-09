# GUI overlay

`c3d::gui` provides an application-owned Dear ImGui overlay with scene, Basic material and
statistics panels. The renderer also works without constructing an adapter. The cube example
uses an overlay by default:

```bash
python3 scripts/build.py --example cube
./examples/build/cube --no-gui
./examples/build/cube --gpu-timings
```

Spin starts off. Enabling it rotates from the current pose; pausing preserves that pose for
editing. Select a node in the scene tree to edit its local position, rotation in degrees,
nonzero scale, visibility and layer mask. The material panel edits the selected mesh's RGB
color; it advances the asset revision only after a change.

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

Forward the raw SDL event from the platform poll callback to `GuiRenderer.process_event`.
The event pointer is borrowed only for that call. Pass the native event unchanged: the native
ImGui SDL backend reads its own C layout. The platform helper does not import or own GUI.

Call `new_frame()` after polling. It sets `window.input.mouse_captured_by_gui` and
`keyboard_captured_by_gui` independently. Apply these gates before application controls:
mouse capture suppresses orbit/wheel actions; keyboard capture suppresses movement, lens
switches and keyboard quit actions. The example retains capture ownership from Escape down through its release, so cancelling
a text edit does not also quit. Native window close remains effective.

The frame sequence is:

1. Poll and forward events; begin the GUI frame.
2. Apply controls and automatic motion, then draw GUI panels.
3. Call `scene.update_world()` so edits reach the current output.
4. Call `gui.finish_frame()` to finalize native draw data.
5. Begin the renderer frame. When `renderer.has_output`, record `render_view()`,
   `composite_view()`, `begin_overlay()`, `gui.record(&overlay)` and `end_overlay(&overlay)`.
6. End the renderer frame.

Always call `finish_frame()` after `new_frame()`, including dormant/minimized windows and
an early exit. GPU recording consumes finalized draw data; it does not close the GUI frame.
The cube example's private `draw_gui_frame` helper demonstrates error cleanup through
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
`RendererDesc.gpu_timings`, or by the cube's `--gpu-timings` flag. Values come from completed
frame slots and may lag CPU counters. The existing WSL2 dzn measurement found about 0.9 ms
of overhead per timed pass, so compare ordinary rendering with timing disabled. The memory
panel displays the device's advisory per-heap usage, budget, allocation and block sizes.
