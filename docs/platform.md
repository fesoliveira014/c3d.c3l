# Windows and input

`c3d::platform` opens native windows, polls events and exposes keyboard, mouse and gamepad state, the clipboard and text
input. It is the only module that imports SDL; application code needs no `import sdl` unless it runs its own event loop.
It imports `gpu::surface` alone, to hand native window handles to the renderer. Named controls with rebinding are in
[Action maps](actions.md).

## Quick start

```c3
import c3d::platform;

Window window = platform::create_window(platform::default_window_desc("c3d", 1280, 720))!!;
defer platform::destroy_window(&window);

while (window.poll()) {
    Input* input = &window.input;
    if (input.key_pressed(Scancode.ESCAPE)) break;
    if (input.button_down(MouseButton.LEFT)) orbit(input.mouse_delta);
    update(window.clock.delta);
}
```

To render into the window, create the renderer from it and hand the window's pixel size to the renderer each frame:

```c3
import c3d::render;

Renderer renderer = platform::create_window_renderer(
    allocator: mem,
    window:    &window,
    assets:    &assets,
    desc:      { .validation = true },
)!!;
defer render::destroy_renderer(&renderer);

while (window.poll()) {
    platform::sync_window(&window, &renderer);
    // begin_frame, render_view, finish_view, end_frame
}
```

## Concepts

- **Framebuffer pixels.** `Window.width`, `height`, `Input.mouse_position` and `mouse_delta` are in framebuffer pixels.
  Window creation enables high pixel density, and `pixel_density` is the ratio to SDL's window coordinates.
- **One queue per process.** SDL has one global event queue. `Window.poll()` drains it for one window; with several
  windows, `platform::poll_windows` drains it once for the group.
- **Per-frame and held state.** `Input` holds held state (`keys`, `mouse_buttons`, `gamepads`) and state that lasts one
  frame (`keys_pressed`, `keys_released`, `mouse_pressed`, `mouse_delta`, `wheel`). Each poll clears the one-frame state
  before it reads new events.
- **Ordered events.** `Window.events()` lists the frame's translated events in arrival order. `Input` is the state view for
  controls; the list is for ordered consumers such as text fields and the GUI adapter.
- **Clock.** `Window.clock` advances once per poll: `delta` in seconds, `total` seconds since creation, `frame` count.

## Create a window

`create_window(WindowDesc)` opens a native window.

| `WindowDesc` field | Meaning |
| --- | --- |
| `title`, `width`, `height` | Title and initial size in SDL window coordinates. |
| `resizable`, `fullscreen` | Window flags. |

`default_window_desc(title, width, height)` returns a resizable window. The first `create_window` starts SDL's video and
gamepad subsystems; the last `destroy_window` stops them and frees the retained clipboard string.

## Poll one or several windows

`Window.poll()` returns false when the application should quit. For several windows, collect their addresses in a
`Window*[]` and call `platform::poll_windows` once per frame. The group borrows its windows and drains SDL's queue once.
Window-specific events reach only the matching native window; a global quit stops the loop. Calling `poll()` on each window
separately drains the shared queue before later windows see their events.

### Custom SDL loops

A loop that needs raw SDL events calls `sdl::pump_events()`, then `Window.begin_frame()` for each window, then passes each
native event to `platform::dispatch_event(windows, &event)`. That call connects and disconnects gamepads and folds the event
into every window. `Window.apply_event()` alone translates one event for one window and never opens or closes a pad. No
event callback exists.

## Keyboard and mouse

Keys are named by `platform::Scancode`, SDL's scancode names and numbers with the gaps kept. Mouse buttons are
`platform::MouseButton`: `LEFT`, `MIDDLE`, `RIGHT`, `X1`, `X2`, in SDL's numbering.

| Call or field | Meaning |
| --- | --- |
| `Input.key_down(key)`, `key_pressed(key)`, `key_released(key)` | Held, went down this frame, went up this frame. |
| `Input.button_down(button)`, `button_pressed(button)` | Same for mouse buttons. |
| `Input.mouse_position`, `mouse_delta` | Framebuffer pixels; the delta sums the frame's motion. |
| `Input.wheel` | Vertical wheel movement of the frame, as SDL reports it. |
| `Input.modifiers` | `Keymod` of the last key event: `shift`, `ctrl`, `alt`, `gui`, `caps`, `num`. |

The arrays behind these calls stay public and use the same indices. Keys held when a window gains focus count as held, not
pressed.

## Events

| `EventKind` | Fields set |
| --- | --- |
| `KEY_DOWN`, `KEY_UP` | `scancode`, `modifiers`, `repeat` |
| `TEXT_INPUT` | `text` (UTF-8) |
| `MOUSE_MOTION` | `position`, `delta` |
| `MOUSE_BUTTON_DOWN`, `MOUSE_BUTTON_UP` | `button`, `position` |
| `MOUSE_WHEEL` | `scroll` with the direction normalized, `position` |
| `FOCUS_GAINED`, `FOCUS_LOST`, `RESIZED`, `QUIT` | none |
| `GAMEPAD_CONNECTED`, `GAMEPAD_DISCONNECTED` | `gamepad_slot` |
| `GAMEPAD_BUTTON_DOWN`, `GAMEPAD_BUTTON_UP` | `gamepad_slot`, `gamepad_button` |
| `GAMEPAD_AXIS_MOTION` | `gamepad_slot`, `gamepad_axis`, normalized `axis_value` |

A window keeps `EVENT_CAPACITY` (256) events and `EVENT_TEXT_CAPACITY` (1,024) bytes of event text per frame. Anything
beyond is dropped and counted in `events_dropped`. `Event.text` borrows the arena until the next `poll` or `clear_events`.
Input state is updated before an event is listed, so a full list drops events, never state. Stick motion produces many axis
events and shares the list with mouse motion.

## Text input and clipboard

`TEXT_INPUT` events arrive only while `Window.set_text_input(true)` is active. GUI layers request it through
`Input.text_input_wanted_by_gui`, which `GuiRenderer.finish_frame` applies; an application without ImGui applies its UI's
want itself.

`platform::clipboard_text()` returns the clipboard as a string borrowed until the next call; it is empty when the clipboard
holds no text. `platform::set_clipboard_text` replaces it and faults `CLIPBOARD_FAILED` when SDL refuses.

## GUI capture flags

`mouse_captured_by_gui`, `keyboard_captured_by_gui` and `text_input_wanted_by_gui` tell application controls to stand down
while a GUI layer owns the device. ImGui's `new_frame` writes them each frame. Other GUI layers, such as the game UI add-on,
OR their own want into `text_input_wanted_by_gui`. A frame without ImGui calls `Input.clear_gui_flags()` before any GUI layer
writes, and `Input.begin_frame` leaves the flags alone. Action maps skip keys and mouse buttons while the matching flag is
set; see [Action maps](actions.md). The ImGui side is in [GUI overlay](gui.md).

## Resize and minimize

Pixel-size events update `width` and `height` and set `resized` only when the dimensions change. The flag stays set until
its consumer handles the resize and clears it; `platform::sync_window(&window, &renderer)` hands the size and the
`minimized` state to the renderer and clears the flag. A repeated notification for the acknowledged size does not set it
again. Logical-size events alone do not describe a framebuffer resize.

## Gamepads

Windows own SDL's gamepad subsystem. `create_window` faults `GAMEPAD_INIT_FAILED` when it does not start.

- Up to `GAMEPAD_COUNT` (4) pads hold a slot. A connected pad takes the lowest free slot and keeps it until it disconnects.
- A pad connected while every slot is taken stays unassigned until it reconnects. A freed slot does not adopt it.
- The slot table is shared by every window. A disconnect zeroes the slot in every window, so held buttons read released
  that frame.
- A window created while pads are connected starts with those slots `connected` and no `GAMEPAD_CONNECTED` event. Their
  buttons and axes read zero until the pad's next event.

`Input.gamepads[slot]` mirrors each slot. Read it through `gamepad_down`, `gamepad_pressed`, `gamepad_released`,
`gamepad_axis` and `gamepad_stick`, each taking the slot (default 0).

- Buttons are named by position (`GamepadButton.SOUTH`, `EAST`, `WEST`, `NORTH`, shoulders, sticks, d-pad, paddles) in SDL's
  numbering. `platform::gamepad_button_label(slot, button)` gives the connected pad's face label (`A`, `B`, `X`, `Y` or
  `CROSS`, `CIRCLE`, `SQUARE`, `TRIANGLE`; `UNKNOWN` when none) for prompts. `platform::gamepad_name(slot)` gives its name.
- Stick axes lie in [-1, 1] and keep SDL's sign, y down, in `gamepad_axis`. `gamepad_stick` reports y up. Triggers lie in
  [0, 1].
- Pressed and released last one frame, like keys.

## Teardown

Destroy the renderer and any GPU surface before `destroy_window()`. Renderer destruction waits for GPU and presentation
completion. An unexpected cleanup wait failure exits the process without running defers; confirmed device loss permits
teardown.

## Reference

| Constant | Value |
| --- | --- |
| `EVENT_CAPACITY` | 256 events per window per frame |
| `EVENT_TEXT_CAPACITY` | 1,024 bytes of event text per window per frame |
| `KEY_COUNT` | 512 scancodes |
| `MOUSE_BUTTON_COUNT` | 8 button slots |
| `GAMEPAD_COUNT` | 4 slots |
| `GAMEPAD_BUTTON_COUNT`, `GAMEPAD_AXIS_COUNT` | 26 buttons, 6 axes |

| Fault | Raised by |
| --- | --- |
| `VIDEO_INIT_FAILED` | `create_window` when SDL video does not start. |
| `GAMEPAD_INIT_FAILED` | `create_window` when the gamepad subsystem does not start. |
| `WINDOW_CREATION_FAILED` | `create_window` when SDL cannot create the window. |
| `CLIPBOARD_FAILED` | `set_clipboard_text` when SDL refuses. |
| `UNSUPPORTED` | `create_surface` and `create_window_renderer` for a video driver other than X11, Wayland or Windows. |

## Limits

- No event callbacks; read `Window.events()` after polling.
- Key and mouse bindings in action maps are gated by the GUI capture flags; pad bindings are not.
- A full event list drops events but never input state.

## See also

- [Action maps](actions.md) for named controls and rebinding.
- [GUI overlay](gui.md) for the ImGui adapter that consumes the event list.
- [Architecture](architecture.md) for where `c3d::platform` sits among the modules.
