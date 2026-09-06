module clear_example;

import c3d::platform;
import c3d::render;
import sdl;
import std::io;
import std::math;

const float TURN_RADIANS @local = (float)math::PI * 2.0f;
const float COLOR_PERIOD_SECONDS @local = 6.0f; // one full sweep, slow enough that a stall is visible
const float CHANNEL_PHASE @local = TURN_RADIANS / 3.0f; // channels evenly spaced around the sweep

fn Vec4 clear_color(double time) {
    float phase = (float)time * TURN_RADIANS / COLOR_PERIOD_SECONDS;
    return {
        0.5f + 0.5f * math::sin(phase),
        0.5f + 0.5f * math::sin(phase + CHANNEL_PHASE),
        0.5f + 0.5f * math::sin(phase + CHANNEL_PHASE * 2.0f),
        1.0f,
    };
}

fn int main() {
    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d clear", 1280, 720))!!;
    defer platform::destroy_window(&window);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        desc:      { .validation = true, .application_name = "c3d_clear" },
    )!!;
    defer render::destroy_renderer(&renderer);

    while (window.poll()) {
        if (window.input.keys_pressed[(usz)sdl::Scancode.ESCAPE]) break;

        platform::sync_window(&window, &renderer);
        renderer.begin_frame({ .time = window.clock.total, .delta = window.clock.delta })!!;
        renderer.clear(clear_color(window.clock.total))!!;
        renderer.end_frame()!!;
    }

    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
