# Window input and polling

Use `Window.poll()` for a single window. For multiple windows, collect their addresses in a `Window*[]` and call `platform::poll_windows` once per frame.

The group borrows its windows and drains SDL's global queue once. Window-specific events affect only the matching native window ID. Global quit stops the loop. Calling `poll()` separately on multiple windows would drain the shared queue before later windows receive their events.

Each window keeps the frame's translated events: `window.events()` is the list in arrival order (`KEY_DOWN`, `KEY_UP` with scancode, modifiers and repeat; `TEXT_INPUT` with UTF-8 text; `MOUSE_MOTION`, `MOUSE_BUTTON_DOWN`, `MOUSE_BUTTON_UP`, `MOUSE_WHEEL` in framebuffer pixels, wheel flipped back to normal direction; `FOCUS_GAINED`, `FOCUS_LOST`, `RESIZED`, `QUIT`). The list holds `EVENT_CAPACITY` events and the text arena `EVENT_TEXT_CAPACITY` bytes per frame; anything beyond is dropped and counted in `events_dropped`. `Event.text` borrows the arena until the next `poll` or `clear_events`. `Input` remains the state view for controls; the list is for ordered consumers such as text fields and the GUI adapter.

Text events arrive only while `Window.set_text_input(true)` is active; the GUI adapter toggles it as widgets need it. `platform::clipboard_text()` returns the clipboard as a string borrowed until the next call; `platform::set_clipboard_text` replaces it and faults `CLIPBOARD_FAILED` when SDL refuses.

Custom SDL loops call `sdl::pump_events()`, then `Window.begin_frame()` for each window, then feed native events through `Window.apply_event()`, which translates them into the list. No event callback exists; the `window` example shows the loop.

Keys are named by `platform::Scancode`, SDL's scancode names and numbers with the gaps kept; mouse buttons by `platform::MouseButton` (`LEFT`, `MIDDLE`, `RIGHT`, `X1`, `X2`, SDL's numbering). Read them through `Input.key_down`, `key_pressed`, `key_released`, `button_down` and `button_pressed`; the arrays behind them stay public and are indexed by the same values. `Input.modifiers` is the `Keymod` of the last key event (`shift`, `ctrl`, `alt`, `gui`, `caps`, `num`). An application needs no `import sdl` for any of this.

`width`, `height`, mouse position, and mouse delta use framebuffer pixels. Window creation enables high pixel density. Frame preparation refreshes density and rescales the stored mouse position; motion and button events are converted from SDL window coordinates. Mouse and keyboard GUI capture flags remain independent and application-controlled.

Pixel-size events update dimensions and set `resized` only when dimensions change. The flag stays set until its consumer handles the resize and clears it. A repeated notification for the acknowledged dimensions does not set it again. Logical-size events alone do not describe a framebuffer resize.

Destroy GPU surfaces and their dependents before `destroy_window()`. Renderer destruction waits for GPU and presentation completion. An unexpected cleanup wait failure exits the process without running defers; confirmed device loss permits teardown. Failed renderer construction uses the same cleanup policy. The `window` example uses SDL software presentation so its window becomes visible on Wayland; software presentation is confined to that example, and is not part of the GPU surface bridge.
