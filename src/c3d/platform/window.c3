module c3d::platform;

import c3d;
import sdl;
import std::math;

// SDL writes Keymod as sixteen bits; a wider binding shifts these two fields.
$assert $reflect(sdl::KeyboardEvent.down).offset == 36;
$assert $reflect(sdl::KeyboardEvent.repeat).offset == 37;
$assert (usz)Scancode.COUNT == KEY_COUNT;
$assert (usz)sdl::Scancode.COUNT == KEY_COUNT;

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
    bool         focus_gained;
    bool         text_input_active;
    Input        input;
    Clock        clock;
    Event[EVENT_CAPACITY]     event_buffer;
    uint                      event_count;
    char[EVENT_TEXT_CAPACITY] event_text;
    uint                      event_text_used;
    uint                      events_dropped;
}

int video_users @private;
char* clipboard_retained @private;

<*
 Events of the current frame in arrival order; cleared by begin_frame.
*>
fn Event[] Window.events(&self) => self.event_buffer[:self.event_count];

<*
 Forget the frame's events and text; begin_frame calls it.
*>
fn void Window.clear_events(&self) {
    self.event_count = 0;
    self.event_text_used = 0;
}

<*
 Fold one event into the window's input and flags.
 @param [&inout] self : "Window receiving its own events."
 @param [&in] event : "Borrowed for the call."
 @return "False when the event asks the application to quit."
*>
fn bool Window.apply_event(&self, sdl::Event* event) {
    switch ((EventType)event.common.type) {
        case EventType.QUIT:
            push_event(self, { .kind = EventKind.QUIT });
            return false;
        case EventType.WINDOW_PIXEL_SIZE_CHANGED:
            if (event.window.window_id != self.window_id) break;
            uint width = (uint)event.window.data1;
            uint height = (uint)event.window.data2;
            if (width != self.width || height != self.height) {
                self.width = width;
                self.height = height;
                self.resized = true;
                push_event(self, { .kind = EventKind.RESIZED });
            }
        case EventType.WINDOW_MINIMIZED:
            if (event.window.window_id != self.window_id) break;
            self.minimized = true;
        case EventType.WINDOW_RESTORED:
            if (event.window.window_id != self.window_id) break;
            self.minimized = false;
        case EventType.WINDOW_FOCUS_GAINED:
            if (event.window.window_id != self.window_id) break;
            self.focus_gained = true;
            push_event(self, { .kind = EventKind.FOCUS_GAINED });
        case EventType.WINDOW_FOCUS_LOST:
            if (event.window.window_id != self.window_id) break;
            push_event(self, { .kind = EventKind.FOCUS_LOST });
        case EventType.KEY_DOWN:
        case EventType.KEY_UP:
            if (event.key.window_id != self.window_id) break;
            usz key = (usz)event.key.scancode;
            if (key >= KEY_COUNT) break;
            // The event type carries the state and a down for a held key is the repeat. Keys reported
            // held when focus arrives are state the window inherits, not presses made in it.
            bool down = (EventType)event.common.type == EventType.KEY_DOWN;
            bool repeat = down && self.input.keys[key];
            if (down && !self.input.keys[key] && !self.focus_gained) self.input.keys_pressed[key] = true;
            if (!down && self.input.keys[key]) self.input.keys_released[key] = true;
            self.input.keys[key] = down;
            self.input.modifiers = keymod_of(event.key.mod);
            push_event(self, {
                .kind      = down ? EventKind.KEY_DOWN : EventKind.KEY_UP,
                .scancode  = (Scancode)key,
                .modifiers = self.input.modifiers,
                .repeat    = repeat,
            });
        case EventType.TEXT_INPUT:
            if (event.text.window_id != self.window_id) break;
            String text;
            if (!copy_text(self, (ZString)event.text.text, &text)) break;
            push_event(self, { .kind = EventKind.TEXT_INPUT, .text = text });
        case EventType.MOUSE_BUTTON_DOWN:
        case EventType.MOUSE_BUTTON_UP:
            if (event.button.window_id != self.window_id) break;
            usz button = (usz)event.button.button;
            if (button >= MOUSE_BUTTON_COUNT) break;
            if (event.button.down && !self.input.mouse_buttons[button]) self.input.mouse_pressed[button] = true;
            self.input.mouse_buttons[button] = event.button.down;
            self.input.mouse_position = (Vec2){ event.button.x, event.button.y } * self.pixel_density;
            push_event(self, {
                .kind     = event.button.down ? EventKind.MOUSE_BUTTON_DOWN : EventKind.MOUSE_BUTTON_UP,
                .button   = (MouseButton)button,
                .position = self.input.mouse_position,
            });
        case EventType.MOUSE_MOTION:
            if (event.motion.window_id != self.window_id) break;
            Vec2 delta = (Vec2){ event.motion.xrel, event.motion.yrel } * self.pixel_density;
            self.input.mouse_position = (Vec2){ event.motion.x, event.motion.y } * self.pixel_density;
            self.input.mouse_delta += delta;
            push_event(self, {
                .kind     = EventKind.MOUSE_MOTION,
                .position = self.input.mouse_position,
                .delta    = delta,
            });
        case EventType.MOUSE_WHEEL:
            if (event.wheel.window_id != self.window_id) break;
            self.input.wheel += event.wheel.y;
            Vec2 scroll = { event.wheel.x, event.wheel.y };
            if (event.wheel.direction == sdl::MouseWheelDirection.FLIPPED) scroll = -scroll;
            push_event(self, {
                .kind     = EventKind.MOUSE_WHEEL,
                .position = self.input.mouse_position,
                .scroll   = scroll,
            });
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
    self.clear_events();
    self.focus_gained = false;
    float pixel_density = sdl::get_window_pixel_density(self.handle);
    self.input.mouse_position *= pixel_density / self.pixel_density;
    self.pixel_density = pixel_density;
    self.clock.advance(sdl::get_performance_counter(), sdl::get_performance_frequency());
}

<*
 Poll one window for the next frame.
 @param [&inout] self : "The only window receiving events through this drain."
 @return "False when the application should quit."
*>
fn bool Window.poll(&self) {
    Window*[1] windows = { self };
    return poll_windows(windows[..]);
}

<*
 Start or stop OS text input for this window.
 @require self.handle != null
*>
fn void Window.set_text_input(&self, bool enabled) {
    if (enabled == self.text_input_active) return;
    if (enabled) {
        sdl::start_text_input(self.handle);
    } else {
        sdl::stop_text_input(self.handle);
    }
    self.text_input_active = enabled;
}

<*
 Poll windows through one shared event drain.
 @param windows : "Borrowed live windows, each supplied once."
 @return "False when the application should quit."
*>
fn bool poll_windows(Window*[] windows) {
    sdl::pump_events();
    foreach (window : windows) window.begin_frame();
    bool running = true;
    sdl::Event event;
    while (sdl::poll_event(&event)) {
        if ((EventType)event.common.type == EventType.QUIT) running = false;
        foreach (window : windows) window.apply_event(&event);
    }
    return running;
}

<*
 Clipboard text, borrowed until the next call or the last destroy_window; empty when none.
*>
fn ZString clipboard_text() {
    if (clipboard_retained) sdl::stdinc::free(clipboard_retained);
    clipboard_retained = sdl::get_clipboard_text();
    return (ZString)clipboard_retained;
}

<*
 Replace the clipboard text.
 @return? CLIPBOARD_FAILED
*>
fn void? set_clipboard_text(String text) {
    @pool() {
        if (!sdl::set_clipboard_text((char*)text.zstr_tcopy())) return CLIPBOARD_FAILED~;
    };
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
    window.set_text_input(false);
    sdl::destroy_window(window.handle);
    video_users--;
    if (!video_users) {
        if (clipboard_retained) sdl::stdinc::free(clipboard_retained);
        clipboard_retained = null;
        sdl::quit_sub_system({ .video = true });
    }
    *window = {};
}

fn void push_event(Window* window, Event event) @local {
    if (window.event_count == EVENT_CAPACITY) {
        window.events_dropped++;
        return;
    }
    window.event_buffer[window.event_count] = event;
    window.event_count++;
}

fn bool copy_text(Window* window, ZString text, String* out) @local {
    usz length = (usz)text.len();
    if (window.event_text_used + length > EVENT_TEXT_CAPACITY) {
        window.events_dropped++;
        return false;
    }
    char[] slot = window.event_text[window.event_text_used:length];
    slot[..] = text[:length];
    window.event_text_used += (uint)length;
    *out = (String)slot;
    return true;
}

fn Keymod keymod_of(sdl::Keymod mod) @local {
    uint bits = (uint)mod;
    return {
        .shift = (bits & (uint)sdl::Keymod.KMOD_SHIFT) != 0,
        .ctrl  = (bits & (uint)sdl::Keymod.KMOD_CTRL) != 0,
        .alt   = (bits & (uint)sdl::Keymod.KMOD_ALT) != 0,
        .gui   = (bits & (uint)sdl::Keymod.KMOD_GUI) != 0,
        .caps  = (bits & (uint)sdl::Keymod.KMOD_CAPS) != 0,
        .num   = (bits & (uint)sdl::Keymod.KMOD_NUM) != 0,
    };
}
