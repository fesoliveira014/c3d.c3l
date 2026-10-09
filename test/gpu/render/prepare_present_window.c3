module c3d::platform;

import c3d;
import sdl;

fn void? resize_preparation_present_window(Window* window, uint width, uint height) @private {
    if (!sdl::set_window_size(window.handle, (int)width, (int)height)) return c3d::UNSUPPORTED~;
    if (!sdl::sync_window(window.handle)) return c3d::UNSUPPORTED~;
    if (!window.poll()) return c3d::UNSUPPORTED~;
}
