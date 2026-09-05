module c3d::platform;

import c3d;
import sdl;
import std::math;

<*
 Borrowed event callback invoked before input changes.
*>
alias EventFn = fn void (sdl::Event* event, void* user);

<*
 How a window is opened.
*>
struct WindowDesc {
    String title;
    uint   width;
    uint   height;
    bool   resizable;
    bool   fullscreen;
}

<*
 Native window with framebuffer input and timing.
*>
struct Window {
    sdl::Window* handle;
    sdl::WindowID window_id;
    uint         width;
    uint         height;
    float        pixel_density;
    bool         resized;
    bool         minimized;
    Input        input;
    Clock        clock;
}

int video_users @private;

<*
 Fold one event into the window's input and flags.
 @param [&inout] self : "Window receiving its own events."
 @param [&in] event : "Borrowed for the call."
 @return "False when the event asks the application to quit."
*>
fn bool Window.apply_event(&self, sdl::Event* event) {
    switch ((EventType)event.common.type) {
        case EventType.QUIT:
            return false;
        case EventType.WINDOW_PIXEL_SIZE_CHANGED:
            if (event.window.window_id != self.window_id) break;
            uint width = (uint)event.window.data1;
            uint height = (uint)event.window.data2;
            if (width != self.width || height != self.height) {
                self.width = width;
                self.height = height;
                self.resized = true;
            }
        case EventType.WINDOW_MINIMIZED:
            if (event.window.window_id != self.window_id) break;
            self.minimized = true;
        case EventType.WINDOW_RESTORED:
            if (event.window.window_id != self.window_id) break;
            self.minimized = false;
        case EventType.KEY_DOWN:
        case EventType.KEY_UP:
            if (event.key.window_id != self.window_id) break;
            usz key = (usz)event.key.scancode;
            if (key >= KEY_COUNT) break;
            self.input.keys[key] = event.key.down;
            if (event.key.down && !event.key.repeat) self.input.keys_pressed[key] = true;
        case EventType.MOUSE_BUTTON_DOWN:
        case EventType.MOUSE_BUTTON_UP:
            if (event.button.window_id != self.window_id) break;
            usz button = (usz)event.button.button;
            if (button >= MOUSE_BUTTON_COUNT) break;
            self.input.mouse_buttons[button] = event.button.down;
            self.input.mouse_position = (Vec2){ event.button.x, event.button.y } * self.pixel_density;
        case EventType.MOUSE_MOTION:
            if (event.motion.window_id != self.window_id) break;
            self.input.mouse_position = (Vec2){ event.motion.x, event.motion.y } * self.pixel_density;
            self.input.mouse_delta += (Vec2){ event.motion.xrel, event.motion.yrel } * self.pixel_density;
        case EventType.MOUSE_WHEEL:
            if (event.wheel.window_id != self.window_id) break;
            self.input.wheel += event.wheel.y;
        default:
            break;
    }
    return true;
}

<*
 Prepare input and timing for the next event drain.
 @param [&inout] self : "Live window after SDL has pumped events."
 @require self.handle != null
 @require self.pixel_density > 0
*>
fn void Window.begin_frame(&self) {
    self.input.begin_frame();
    float pixel_density = sdl::get_window_pixel_density(self.handle);
    self.input.mouse_position *= pixel_density / self.pixel_density;
    self.pixel_density = pixel_density;
    self.clock.advance(sdl::get_performance_counter(), sdl::get_performance_frequency());
}

<*
 Poll one window for the next frame.
 @param [&inout] self : "The only window receiving events through this drain."
 @param event_fn : "Optional callback borrowing each event before input changes."
 @param [inout] user : "Optional borrowed callback data."
 @return "False when the application should quit."
*>
fn bool Window.poll(&self, EventFn event_fn = null, void* user = null) {
    Window*[1] windows = { self };
    return poll_windows(windows[..], event_fn, user);
}

<*
 Poll windows through one shared event drain.
 @param windows : "Borrowed live windows, each supplied once."
 @param event_fn : "Optional callback borrowing each event before input changes."
 @param [inout] user : "Optional borrowed callback data."
 @return "False when the application should quit."
*>
fn bool poll_windows(Window*[] windows, EventFn event_fn = null, void* user = null) {
    sdl::pump_events();
    foreach (window : windows) window.begin_frame();
    bool running = true;
    sdl::Event event;
    while (sdl::poll_event(&event)) {
        if (event_fn) event_fn(&event, user);
        if ((EventType)event.common.type == EventType.QUIT) running = false;
        foreach (window : windows) window.apply_event(&event);
    }
    return running;
}

<*
 Describe a resizable window with the requested dimensions.
*>
fn WindowDesc default_window_desc(String title, uint width, uint height) {
    return {
        .title     = title,
        .width     = width,
        .height    = height,
        .resizable = true,
    };
}

<*
 Open a native window.
 @return? VIDEO_INIT_FAILED, WINDOW_CREATION_FAILED
*>
fn Window? create_window(WindowDesc desc) {
    if (!video_users && !sdl::init({ .video = true })) return VIDEO_INIT_FAILED~;
    video_users++;
    defer catch {
        video_users--;
        if (!video_users) sdl::quit_sub_system({ .video = true });
    }

    sdl::Window* handle;
    @pool() {
        handle = sdl::create_window(
            title: (char*)desc.title.zstr_tcopy(),
            w: (int)desc.width,
            h: (int)desc.height,
            flags: { .resizable = desc.resizable, .fullscreen = desc.fullscreen, .high_pixel_density = true },
        );
    };
    if (!handle) return WINDOW_CREATION_FAILED~;

    int width;
    int height;
    sdl::get_window_size_in_pixels(handle, &width, &height);

    return {
        .handle = handle,
        .window_id = sdl::get_window_id(handle),
        .width  = (uint)width,
        .height = (uint)height,
        .pixel_density = sdl::get_window_pixel_density(handle),
        .clock  = { .counter = sdl::get_performance_counter() },
    };
}

<*
 Release a native window.
 @param [&inout] window : "Left zeroed; destroy dependent GPU surfaces first."
*>
fn void destroy_window(Window* window) {
    sdl::destroy_window(window.handle);
    video_users--;
    if (!video_users) sdl::quit_sub_system({ .video = true });
    *window = {};
}
