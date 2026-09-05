# Window input and polling

Use `Window.poll()` for a single window. For multiple windows, collect their addresses in a `Window*[]` and call `platform::poll_windows` once per frame.

The group borrows its windows and drains SDL's global queue once. Each event reaches the optional callback once before any window applies it. Window-specific events affect only the matching native window ID. Global quit stops the loop. Calling `poll()` separately on multiple windows would drain the shared queue before later windows receive their events.

Custom SDL loops call `sdl::pump_events()`, then `Window.begin_frame()` for each window, then feed events through `Window.apply_event()`. Forward events to GUI callbacks before applying them. Callback event pointers and user data are borrowed; an event pointer must not escape the callback.

`width`, `height`, mouse position, and mouse delta use framebuffer pixels. Window creation enables high pixel density. Frame preparation refreshes density and rescales the stored mouse position; motion and button events are converted from SDL window coordinates. Mouse and keyboard GUI capture flags remain independent and application-controlled.

Pixel-size events update dimensions and set `resized` only when dimensions change. The flag stays set until its consumer handles the resize and clears it. A repeated notification for the acknowledged dimensions does not set it again. Logical-size events alone do not describe a framebuffer resize.

Destroy GPU surfaces and their dependents before `destroy_window()`. The `window` example uses SDL software presentation so its window becomes visible on Wayland; software presentation is confined to that example, and is not part of the GPU surface bridge.
