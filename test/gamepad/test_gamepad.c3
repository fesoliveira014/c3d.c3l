module c3d::test::gamepad;

import c3d::platform @public;
import sdl;

const uint VIRTUAL_BUTTON_MASK @local = (1u << 26) - 1;
const uint VIRTUAL_AXIS_MASK @local = (1u << 6) - 1;
const short AXIS_MIN @local = -32768;
const short AXIS_MAX @local = 32767;

fn sdl::JoystickID attach_pad() @local {
    sdl::VirtualJoystickDesc desc = {
        .version     = sdl::VirtualJoystickDesc::size,
        .type        = (ushort)sdl::JoystickType.GAMEPAD.ordinal,
        .naxes       = (ushort)platform::GAMEPAD_AXIS_COUNT,
        .nbuttons    = (ushort)platform::GAMEPAD_BUTTON_COUNT,
        .button_mask = VIRTUAL_BUTTON_MASK,
        .axis_mask   = VIRTUAL_AXIS_MASK,
        .name        = "virtual pad",
    };
    sdl::JoystickID id = sdl::attach_virtual_joystick(&desc);
    assert(id != (sdl::JoystickID)0);
    return id;
}

fn void detach_pad(sdl::JoystickID id) @local {
    assert(sdl::detach_virtual_joystick(id));
}

fn sdl::Joystick* joystick_of(sdl::JoystickID id) @local {
    sdl::Joystick* joystick = sdl::get_joystick_from_id(id);
    assert(joystick != null);
    return joystick;
}

fn void drain(Window*[] windows) @local {
    sdl::update_gamepads();
    sdl::pump_events();
    foreach (window : windows) {
        window.input.begin_frame();
        window.clear_events();
    }
    sdl::Event event;
    while (sdl::poll_event(&event)) platform::dispatch_event(windows, &event);
}

fn usz count_events(Window* window, EventKind kind) @local {
    usz count;
    foreach (event : window.events()) {
        if (event.kind == kind) count++;
    }
    return count;
}

fn void test_pads_take_the_lowest_free_slot_and_reuse_it() @test {
    platform::acquire_gamepads()!!;
    defer platform::release_gamepads();
    Window window;
    Window*[1] windows = { &window };

    sdl::JoystickID[platform::GAMEPAD_COUNT + 1] pads;
    foreach (&pad : pads) *pad = attach_pad();
    drain(windows[..]);

    for (usz slot = 0; slot < platform::GAMEPAD_COUNT; slot++) assert(window.input.gamepads[slot].connected);
    assert(count_events(&window, EventKind.GAMEPAD_CONNECTED) == platform::GAMEPAD_COUNT);

    detach_pad(pads[1]);
    drain(windows[..]);
    assert(!window.input.gamepads[1].connected);

    sdl::JoystickID replacement = attach_pad();
    drain(windows[..]);
    assert(window.input.gamepads[1].connected);
    assert(platform::gamepad_slot(replacement)!! == 1);

    detach_pad(replacement);
    foreach (usz index, pad : pads) {
        if (index != 1) detach_pad(pad);
    }
    drain(windows[..]);
}

fn void test_button_transitions_come_through_sdl() @test {
    platform::acquire_gamepads()!!;
    defer platform::release_gamepads();
    Window window;
    Window*[1] windows = { &window };
    sdl::JoystickID pad = attach_pad();
    drain(windows[..]);
    sdl::Joystick* joystick = joystick_of(pad);

    sdl::set_joystick_virtual_button(joystick, (int)GamepadButton.NORTH, true);
    drain(windows[..]);
    assert(window.input.gamepad_pressed(GamepadButton.NORTH));
    assert(window.input.gamepad_down(GamepadButton.NORTH));
    assert(count_events(&window, EventKind.GAMEPAD_BUTTON_DOWN) == 1);

    drain(windows[..]);
    assert(!window.input.gamepad_pressed(GamepadButton.NORTH));
    assert(window.input.gamepad_down(GamepadButton.NORTH));

    sdl::set_joystick_virtual_button(joystick, (int)GamepadButton.NORTH, false);
    drain(windows[..]);
    assert(window.input.gamepad_released(GamepadButton.NORTH));
    assert(!window.input.gamepad_down(GamepadButton.NORTH));

    detach_pad(pad);
    drain(windows[..]);
}

fn void test_axis_motion_is_normalized() @test {
    platform::acquire_gamepads()!!;
    defer platform::release_gamepads();
    Window window;
    Window*[1] windows = { &window };
    sdl::JoystickID pad = attach_pad();
    drain(windows[..]);
    sdl::Joystick* joystick = joystick_of(pad);

    sdl::set_joystick_virtual_axis(joystick, (int)GamepadAxis.LEFTY, AXIS_MIN);
    sdl::set_joystick_virtual_axis(joystick, (int)GamepadAxis.RIGHT_TRIGGER, AXIS_MAX);
    drain(windows[..]);

    assert(window.input.gamepad_axis(GamepadAxis.LEFTY) == -1);
    assert(window.input.gamepad_stick(GamepadStick.LEFT).y == 1);
    assert(window.input.gamepad_axis(GamepadAxis.RIGHT_TRIGGER) == 1);

    detach_pad(pad);
    drain(windows[..]);
}

fn void test_removal_zeroes_the_mirror_in_every_window() @test {
    platform::acquire_gamepads()!!;
    defer platform::release_gamepads();
    Window first;
    Window second;
    Window*[2] windows = { &first, &second };
    sdl::JoystickID pad = attach_pad();
    drain(windows[..]);
    sdl::set_joystick_virtual_button(joystick_of(pad), (int)GamepadButton.SOUTH, true);
    drain(windows[..]);
    assert(first.input.gamepad_down(GamepadButton.SOUTH) && second.input.gamepad_down(GamepadButton.SOUTH));

    detach_pad(pad);
    drain(windows[..]);

    foreach (window : windows) {
        assert(!window.input.gamepads[0].connected);
        assert(!window.input.gamepad_down(GamepadButton.SOUTH));
        assert(count_events(window, EventKind.GAMEPAD_DISCONNECTED) == 1);
    }
}

fn void test_seed_reports_pads_connected_before_the_window() @test {
    platform::acquire_gamepads()!!;
    defer platform::release_gamepads();
    Window first;
    Window*[1] windows = { &first };
    sdl::JoystickID pad = attach_pad();
    drain(windows[..]);

    Window later;
    platform::seed_gamepads(&later.input);

    assert(later.input.gamepads[0].connected);
    assert(!later.input.gamepad_down(GamepadButton.SOUTH));

    detach_pad(pad);
    drain(windows[..]);
}

fn void test_release_closes_every_pad_at_the_last_user() @test {
    platform::acquire_gamepads()!!;
    platform::acquire_gamepads()!!;
    Window window;
    Window*[1] windows = { &window };
    attach_pad();
    drain(windows[..]);

    platform::release_gamepads();
    assert(platform::gamepad_name(0).len() > 0);

    // The last release quits the subsystem, which removes the virtual pad; it stays attached on purpose.
    platform::release_gamepads();
    assert(platform::gamepad_name(0).len() == 0);
}
