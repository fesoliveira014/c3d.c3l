module c3d::platform;

import c3d;
import sdl;
import std::math;

<*
 Receives each SDL event before the window folds it into input state.
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
 Native window, its pixel size, and the input and clock it drives.
*>
struct Window {
    sdl::Window* handle;
    uint         width;
    uint         height;
    bool         resized;
    bool         minimized;
    Input        input;
    Clock        clock;
}

int video_users @private;

<*
 Fold one event into the window's input and flags.
 @param [&in] event : "Borrowed for the call."
 @return "False when the event asks the application to quit."
*>
fn bool Window.apply_event(&self, sdl::Event* event) {
    switch ((EventType)event.common.type) {
        case EventType.QUIT:
            return false;
        case EventType.WINDOW_RESIZED:
        case EventType.WINDOW_PIXEL_SIZE_CHANGED:
            self.resized = true;
        case EventType.WINDOW_MINIMIZED:
            self.minimized = true;
        case EventType.WINDOW_RESTORED:
            self.minimized = false;
        case EventType.KEY_DOWN:
        case EventType.KEY_UP:
            usz key = (usz)event.key.scancode;
            if (key >= KEY_COUNT) break;
            self.input.keys[key] = event.key.down;
            if (event.key.down && !event.key.repeat) self.input.keys_pressed[key] = true;
        case EventType.MOUSE_BUTTON_DOWN:
        case EventType.MOUSE_BUTTON_UP:
            usz button = (usz)event.button.button;
            if (button >= MOUSE_BUTTON_COUNT) break;
            self.input.mouse_buttons[button] = event.button.down;
        case EventType.MOUSE_MOTION:
            self.input.mouse_position = { event.motion.x, event.motion.y };
            self.input.mouse_delta += (Vec2){ event.motion.xrel, event.motion.yrel };
        case EventType.MOUSE_WHEEL:
            self.input.wheel += event.wheel.y;
        default:
            break;
    }
    return true;
}

<*
 Drain the event queue, refresh the pixel size on resize, and advance the clock.
 @param event_fn : "Receives each event before input state changes; may be null."
 @return "False when the application should quit."
*>
fn bool Window.poll(&self, EventFn event_fn = null, void* user = null) {
    self.input.begin_frame();

    bool running = true;
    sdl::Event event;
    while (sdl::poll_event(&event)) {
        if (event_fn) event_fn(&event, user);
        if (!self.apply_event(&event)) running = false;
    }

    // One read per drain, so a size change that arrives as two events is still one change.
    if (self.resized) {
        int width;
        int height;
        sdl::get_window_size_in_pixels(self.handle, &width, &height);
        self.width = (uint)width;
        self.height = (uint)height;
    }

    self.clock.advance(sdl::get_performance_counter(), sdl::get_performance_frequency());
    return running;
}

<*
 Window description with the documented defaults applied.
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
 Open a window and initialise the video subsystem.
 @return? VIDEO_INIT_FAILED, WINDOW_CREATION_FAILED
*>
fn Window? create_window(WindowDesc desc) {
    if (!video_users && !sdl::init({ .video = true })) return VIDEO_INIT_FAILED~;
    video_users++;

    ZString title = desc.title.zstr_tcopy();
    sdl::Window* handle = sdl::create_window(
        (char*)title,
        (int)desc.width,
        (int)desc.height,
        { .resizable = desc.resizable, .fullscreen = desc.fullscreen },
    );
    if (!handle) {
        video_users--;
        if (!video_users) sdl::quit_sub_system({ .video = true });
        return WINDOW_CREATION_FAILED~;
    }

    int width;
    int height;
    sdl::get_window_size_in_pixels(handle, &width, &height);

    return {
        .handle = handle,
        .width  = (uint)width,
        .height = (uint)height,
        .clock  = { .counter = sdl::get_performance_counter() },
    };
}

<*
 Close the window and release the video subsystem when it is the last one.
 @param [&inout] window : "Left zeroed; must outlive any gpu surface made from it."
*>
fn void destroy_window(Window* window) {
    sdl::destroy_window(window.handle);
    video_users--;
    if (!video_users) sdl::quit_sub_system({ .video = true });
    *window = {};
}
