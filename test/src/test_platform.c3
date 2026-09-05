module c3d::test::windowing;

import c3d::platform;
import sdl;
import std::math;

const float TOLERANCE @local = 0.0005f;

fn sdl::Event key_event(sdl::EventType type, sdl::Scancode scancode, bool repeat = false) @local {
    sdl::Event event;
    event.key.type = type;
    event.key.scancode = scancode;
    event.key.down = type == sdl::EventType.KEY_DOWN;
    event.key.repeat = repeat;
    return event;
}

fn sdl::Event window_event(sdl::EventType type) @local {
    sdl::Event event;
    event.window.type = type;
    return event;
}

fn void test_quit_event_stops_the_loop() @test {
    platform::Window window;
    assert(!window.apply_event(&&window_event(sdl::EventType.QUIT)));
    assert(window.apply_event(&&window_event(sdl::EventType.WINDOW_RESTORED)));
}

fn void test_resize_notifications_report_changed_pixels_once() @test {
    platform::Window window = { .width = 100, .height = 100 };
    sdl::Event event = window_event(sdl::EventType.WINDOW_RESIZED);
    event.window.data1 = 200;
    event.window.data2 = 150;
    window.apply_event(&event);
    assert(!window.resized && window.width == 100 && window.height == 100);

    event.window.type = sdl::EventType.WINDOW_PIXEL_SIZE_CHANGED;
    window.apply_event(&event);
    assert(window.resized);
    assert(window.width == 200 && window.height == 150);

    window.apply_event(&event);
    assert(window.resized, "an unhandled resize stays pending");
    window.resized = false;
    window.input.begin_frame();
    window.apply_event(&event);
    assert(!window.resized, "unchanged pixels must not trigger another resize");

    event.window.data1 = 300;
    window.apply_event(&event);
    assert(window.resized && window.width == 300);
}

fn void test_foreign_window_events_do_not_change_input() @test {
    platform::Window window = { .window_id = (sdl::WindowID)1, .pixel_density = 1 };
    sdl::Event event = key_event(sdl::EventType.KEY_DOWN, sdl::Scancode.A);
    event.key.window_id = (sdl::WindowID)2;
    window.apply_event(&event);
    assert(!window.input.keys[(usz)sdl::Scancode.A]);
    event.key.window_id = (sdl::WindowID)1;
    window.apply_event(&event);
    assert(window.input.keys_pressed[(usz)sdl::Scancode.A]);

    event = window_event(sdl::EventType.WINDOW_MINIMIZED);
    event.window.window_id = (sdl::WindowID)2;
    window.apply_event(&event);
    assert(!window.minimized);

    event.motion.type = sdl::EventType.MOUSE_MOTION;
    event.motion.window_id = (sdl::WindowID)2;
    event.motion.x = 40;
    event.motion.y = 25;
    event.motion.xrel = 4;
    event.motion.yrel = -3;
    window.apply_event(&event);
    assert(window.input.mouse_position.x == 0 && window.input.mouse_delta.x == 0);
}

fn void test_minimize_and_restore_track() @test {
    platform::Window window;
    window.apply_event(&&window_event(sdl::EventType.WINDOW_MINIMIZED));
    assert(window.minimized);
    window.apply_event(&&window_event(sdl::EventType.WINDOW_RESTORED));
    assert(!window.minimized);
}

fn void test_key_down_marks_pressed_for_one_frame() @test {
    platform::Window window;
    window.apply_event(&&key_event(sdl::EventType.KEY_DOWN, sdl::Scancode.A));

    assert(window.input.keys[(usz)sdl::Scancode.A]);
    assert(window.input.keys_pressed[(usz)sdl::Scancode.A]);

    window.input.begin_frame();
    assert(window.input.keys[(usz)sdl::Scancode.A], "a held key stays held across frames");
    assert(!window.input.keys_pressed[(usz)sdl::Scancode.A]);
}

fn void test_key_repeat_is_not_a_press() @test {
    platform::Window window;
    window.apply_event(&&key_event(sdl::EventType.KEY_DOWN, sdl::Scancode.A, true));

    assert(window.input.keys[(usz)sdl::Scancode.A]);
    assert(!window.input.keys_pressed[(usz)sdl::Scancode.A], "a repeat is not a fresh press");
}

fn void test_key_up_releases() @test {
    platform::Window window;
    window.apply_event(&&key_event(sdl::EventType.KEY_DOWN, sdl::Scancode.A));
    window.apply_event(&&key_event(sdl::EventType.KEY_UP, sdl::Scancode.A));

    assert(!window.input.keys[(usz)sdl::Scancode.A]);
}

fn void test_mouse_button_and_position_track() @test {
    platform::Window window = { .pixel_density = 1 };

    sdl::Event press;
    press.button.type = sdl::EventType.MOUSE_BUTTON_DOWN;
    press.button.button = 1;
    press.button.down = true;
    press.button.x = 40;
    press.button.y = 25;
    window.apply_event(&press);
    assert(window.input.mouse_buttons[1]);
    assert(window.input.mouse_position.x == 40 && window.input.mouse_position.y == 25);

    sdl::Event release = press;
    release.button.type = sdl::EventType.MOUSE_BUTTON_UP;
    release.button.down = false;
    window.apply_event(&release);
    assert(!window.input.mouse_buttons[1]);

    sdl::Event motion;
    motion.motion.type = sdl::EventType.MOUSE_MOTION;
    motion.motion.x = 40;
    motion.motion.y = 25;
    motion.motion.xrel = 4;
    motion.motion.yrel = -3;
    window.apply_event(&motion);

    assert(window.input.mouse_position.x == 40 && window.input.mouse_position.y == 25);
    assert(window.input.mouse_delta.x == 4 && window.input.mouse_delta.y == -3);
}

fn void test_mouse_delta_and_wheel_clear_each_frame() @test {
    platform::Window window = { .pixel_density = 1 };

    sdl::Event motion;
    motion.motion.type = sdl::EventType.MOUSE_MOTION;
    motion.motion.x = 10;
    motion.motion.y = 10;
    motion.motion.xrel = 2;
    motion.motion.yrel = 2;
    window.apply_event(&motion);
    window.apply_event(&motion);

    sdl::Event wheel;
    wheel.wheel.type = sdl::EventType.MOUSE_WHEEL;
    wheel.wheel.y = 1.5f;
    window.apply_event(&wheel);
    window.apply_event(&wheel);

    assert(window.input.mouse_delta.x == 4, "motion within a frame accumulates");
    assert(window.input.wheel == 3.0f);

    window.input.begin_frame();
    assert(window.input.mouse_delta.x == 0 && window.input.wheel == 0);
    assert(window.input.mouse_position.x == 10, "position is state, not a frame delta");
}

fn void test_clock_advance_computes_delta() @test {
    platform::Clock clock = { .counter = 1000 };

    clock.advance(1500, 1000);
    assert(math::abs(clock.delta - 0.5f) <= TOLERANCE);
    assert(math::abs((float)clock.total - 0.5f) <= TOLERANCE);
    assert(clock.frame == 1);

    clock.advance(2000, 1000);
    assert(math::abs(clock.delta - 0.5f) <= TOLERANCE);
    assert(math::abs((float)clock.total - 1.0f) <= TOLERANCE);
    assert(clock.frame == 2);
    assert(clock.counter == 2000);
}

fn void test_mouse_coordinates_use_framebuffer_pixels() @test {
    platform::Window window = { .pixel_density = 2 };
    sdl::Event motion;
    motion.motion.type = sdl::EventType.MOUSE_MOTION;
    motion.motion.x = 40;
    motion.motion.y = 25;
    motion.motion.xrel = 4;
    motion.motion.yrel = -3;
    window.apply_event(&motion);
    assert(window.input.mouse_position.x == 80 && window.input.mouse_position.y == 50);
    assert(window.input.mouse_delta.x == 8 && window.input.mouse_delta.y == -6);

    sdl::Event press;
    press.button.type = sdl::EventType.MOUSE_BUTTON_DOWN;
    press.button.button = 1;
    press.button.down = true;
    press.button.x = 50;
    press.button.y = 30;
    window.apply_event(&press);
    assert(window.input.mouse_position.x == 100 && window.input.mouse_position.y == 60);
}
