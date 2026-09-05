module window_example;

import c3d::platform;
import sdl;
import std::io;

fn int main() {
    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d window", 1280, 720))!!;
    defer platform::destroy_window(&window);

    io::printfn("opened %dx%d, escape or close to quit", window.width, window.height);

    bool[platform::MOUSE_BUTTON_COUNT] previous_buttons;
    while (window.poll()) {
        if (window.input.keys_pressed[(usz)sdl::Scancode.ESCAPE]) break;

        if (window.resized) {
            io::printfn("resized to %dx%d", window.width, window.height);
            window.resized = false;
        }

        foreach (scancode, pressed : window.input.keys_pressed) {
            if (pressed) io::printfn("key %d pressed", scancode);
        }

        foreach (button, down : window.input.mouse_buttons) {
            if (down == previous_buttons[button]) continue;
            io::printfn("mouse button %d %s at %s", button, down ? "down" : "up",
                window.input.mouse_position);
        }
        previous_buttons = window.input.mouse_buttons;

        if (window.input.wheel != 0) io::printfn("wheel %s", window.input.wheel);
    }

    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
