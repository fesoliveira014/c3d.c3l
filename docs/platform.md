# Window input and polling

Use `Window.poll()` for a single window. For multiple windows, collect their addresses in a `Window*[]` and call `platform::poll_windows` once per frame.

The group borrows its windows and drains SDL's global queue once. Window-specific events affect only the matching native window ID. Global quit stops the loop. Calling `poll()` separately on multiple windows would drain the shared queue before later windows receive their events.

Each window keeps the frame's translated events: `window.events()` is the list in arrival order (`KEY_DOWN`, `KEY_UP` with scancode, modifiers and repeat; `TEXT_INPUT` with UTF-8 text; `MOUSE_MOTION`, `MOUSE_BUTTON_DOWN`, `MOUSE_BUTTON_UP`, `MOUSE_WHEEL` in framebuffer pixels, wheel flipped back to normal direction; `FOCUS_GAINED`, `FOCUS_LOST`, `RESIZED`, `QUIT`). The list holds `EVENT_CAPACITY` events and the text arena `EVENT_TEXT_CAPACITY` bytes per frame; anything beyond is dropped and counted in `events_dropped`. `Event.text` borrows the arena until the next `poll` or `clear_events`. `Input` remains the state view for controls; the list is for ordered consumers such as text fields and the GUI adapter.

Text events arrive only while `Window.set_text_input(true)` is active. GUI layers request it through `Input.text_input_wanted_by_gui`, which `GuiRenderer.finish_frame` applies; an application without ImGui applies its UI's want itself. The capture flags and `text_input_wanted_by_gui` are written each frame by ImGui's `new_frame`; a frame without ImGui calls `Input.clear_gui_flags()` before any GUI layer ORs into them, and `Input.begin_frame` leaves them alone. `platform::clipboard_text()` returns the clipboard as a string borrowed until the next call; `platform::set_clipboard_text` replaces it and faults `CLIPBOARD_FAILED` when SDL refuses.

Custom SDL loops call `sdl::pump_events()`, then `Window.begin_frame()` for each window, then feed each native event through `platform::dispatch_event(windows, &event)`, which connects and disconnects gamepads and folds the event into every window. `Window.apply_event()` alone translates one event for one window and never opens or closes a pad. No event callback exists.

Keys are named by `platform::Scancode`, SDL's scancode names and numbers with the gaps kept; mouse buttons by `platform::MouseButton` (`LEFT`, `MIDDLE`, `RIGHT`, `X1`, `X2`, SDL's numbering). Read them through `Input.key_down`, `key_pressed`, `key_released`, `button_down` and `button_pressed`; the arrays behind them stay public and are indexed by the same values. `Input.modifiers` is the `Keymod` of the last key event (`shift`, `ctrl`, `alt`, `gui`, `caps`, `num`). An application needs no `import sdl` for any of this.

`width`, `height`, mouse position, and mouse delta use framebuffer pixels. Window creation enables high pixel density. Frame preparation refreshes density and rescales the stored mouse position; motion and button events are converted from SDL window coordinates. Mouse and keyboard GUI capture flags remain independent and application-controlled.

Pixel-size events update dimensions and set `resized` only when dimensions change. The flag stays set until its consumer handles the resize and clears it. A repeated notification for the acknowledged dimensions does not set it again. Logical-size events alone do not describe a framebuffer resize.

Destroy GPU surfaces and their dependents before `destroy_window()`. Renderer destruction waits for GPU and presentation completion. An unexpected cleanup wait failure exits the process without running defers; confirmed device loss permits teardown. Failed renderer construction uses the same cleanup policy. The `window` example uses SDL software presentation so its window becomes visible on Wayland; software presentation is confined to that example, and is not part of the GPU surface bridge.

## Gamepads

Windows own SDL's gamepad subsystem: the first `create_window` starts it together with video and the last `destroy_window` closes every pad and stops it. `create_window` faults `GAMEPAD_INIT_FAILED` when the subsystem does not start.

Up to `GAMEPAD_COUNT` (4) pads hold a slot. A connected pad takes the lowest free slot and keeps it until it disconnects. A pad connected while every slot is taken stays unassigned until it reconnects; a freed slot does not adopt it. The slot table is shared by every window: a disconnect zeroes the slot's mirror in every window, so held buttons read released that frame. A window created while pads are connected starts with those slots `connected` and no `GAMEPAD_CONNECTED` event; their buttons and axes read zero until the pad's next event.

`Input.gamepads[slot]` mirrors each slot. Read it through `gamepad_down`, `gamepad_pressed`, `gamepad_released`, `gamepad_axis` and `gamepad_stick`, each taking the slot (default 0). Buttons are named by position (`GamepadButton.SOUTH`, `EAST`, `WEST`, `NORTH`, shoulders, sticks, d-pad, paddles), with SDL's numbering; `platform::gamepad_button_label(slot, button)` gives the connected pad's face label (`A`/`B`/`X`/`Y` or `CROSS`/`CIRCLE`/`SQUARE`/`TRIANGLE`) for prompts, and `platform::gamepad_name(slot)` its name.

Stick axes lie in [-1, 1] and keep SDL's sign, y down, in `gamepad_axis` and in axis bindings. `gamepad_stick` and stick bindings report y up. Triggers lie in [0, 1]. Pressed and released last one frame, like keys.

The event list carries `GAMEPAD_CONNECTED`, `GAMEPAD_DISCONNECTED`, `GAMEPAD_BUTTON_DOWN`, `GAMEPAD_BUTTON_UP` and `GAMEPAD_AXIS_MOTION` with `Event.gamepad_slot`, `gamepad_button`, `gamepad_axis` and the normalized `axis_value`. Stick motion produces many axis events and shares `EVENT_CAPACITY` with mouse motion. Input state is updated before an event is listed, so a full list drops events, never state.

## Actions

`platform::ActionMap` describes controls as named actions bound to devices. An action is a `BUTTON`, an `AXIS_1D` or an `AXIS_2D`:

```c3
ActionMap actions = platform::default_action_map();
ActionId jump = actions.add("jump", ActionKind.BUTTON)!;
ActionId move = actions.add("move", ActionKind.AXIS_2D)!;
ActionId sprint = actions.add("sprint", ActionKind.AXIS_1D)!;

actions.bind(jump, platform::key_binding(Scancode.SPACE))!;
actions.bind(jump, platform::gamepad_button_binding(GamepadButton.SOUTH))!;
actions.bind(move, platform::key_binding(Scancode.W, { 0, 1 }))!;
actions.bind(move, platform::gamepad_stick_binding(GamepadStick.LEFT))!;
actions.bind(sprint, platform::gamepad_axis_binding(GamepadAxis.RIGHT_TRIGGER))!;

while (window.poll()) {
    actions.update(&window.input);
    if (actions.pressed(jump)) hop();
    Vec2 direction = actions.vector(move);
    float run = actions.value(sprint);
}
```

- A binding reads a key, a mouse button, a pad button, a pad axis or a stick, on a pad slot. A key or button contributes its `scale` while held; an axis or stick contributes its value times `scale`, componentwise.
- `update` runs once per frame after polling and reads only `Input`. A `BUTTON` is down while any source is held; two held sources give one press, and releasing one of them gives no release. `AXIS_1D` sums its contributions and clamps to [-1, 1]; `AXIS_2D` sums and clamps to the unit disc. An axis action is down while its value is nonzero, so `pressed` works on a trigger.
- Sticks apply the map's radial `deadzone` (`DEFAULT_STICK_DEADZONE`, 0.15) and rescale to the full range; triggers apply none.
- Keys and mouse buttons contribute nothing while the GUI captures the keyboard or the mouse; pad bindings are never gated. A binding on a slot that is not connected contributes nothing.
- `bind`, `unbind(action)` and `clear` change the map at runtime; the change applies at the next `update`. `clear` invalidates every `ActionId`.
- Capacities are fixed: `ACTION_COUNT` (64) actions and `BINDING_COUNT` (256) bindings; `add` and `bind` fault `CAPACITY_EXCEEDED` past them, `add` faults `INVALID_ARGUMENT` for a taken name, and `find` faults `NOT_FOUND`. Action names are borrowed and must outlive the map. The map allocates nothing.

The `actions` example moves a box with `move`, hops on `jump` and runs with `sprint`, each bound to the keyboard and a pad at once, and lists every action, its bindings and the connected pads.
