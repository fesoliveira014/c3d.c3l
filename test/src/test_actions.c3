module c3d::test::actions;

import c3d;
import c3d::platform @public;
import std::math;

const float TOLERANCE @local = 1e-5f;

fn void hold_key(Input* input, Scancode key, bool down) @local {
    input.keys[(usz)key] = down;
}

fn void hold_pad_button(Input* input, GamepadButton button, bool down, usz slot = 0) @local {
    input.gamepads[slot].connected = true;
    input.gamepads[slot].buttons[(usz)button] = down;
}

fn void set_pad_axis(Input* input, GamepadAxis axis, float value, usz slot = 0) @local {
    input.gamepads[slot].connected = true;
    input.gamepads[slot].axes[(usz)axis] = value;
}

fn bool near(float a, float b) @local => math::abs(a - b) < TOLERANCE;

fn void test_two_held_sources_give_one_press_and_no_early_release() @test {
    ActionMap actions = platform::default_action_map();
    ActionId jump = actions.add("jump", ActionKind.BUTTON)!!;
    actions.bind(jump, platform::key_binding(Scancode.SPACE))!!;
    actions.bind(jump, platform::gamepad_button_binding(GamepadButton.NORTH))!!;
    Input input;

    hold_key(&input, Scancode.SPACE, true);
    hold_pad_button(&input, GamepadButton.NORTH, true);
    actions.update(&input);
    assert(actions.pressed(jump) && actions.down(jump));

    hold_key(&input, Scancode.SPACE, false);
    actions.update(&input);
    assert(actions.down(jump) && !actions.pressed(jump) && !actions.released(jump));

    hold_pad_button(&input, GamepadButton.NORTH, false);
    actions.update(&input);
    assert(actions.released(jump) && !actions.down(jump));
}

fn void test_axis_1d_sums_and_clamps() @test {
    ActionMap actions = platform::default_action_map();
    ActionId sprint = actions.add("sprint", ActionKind.AXIS_1D)!!;
    actions.bind(sprint, platform::key_binding(Scancode.LSHIFT))!!;
    actions.bind(sprint, platform::gamepad_axis_binding(GamepadAxis.RIGHT_TRIGGER))!!;
    Input input;

    hold_key(&input, Scancode.LSHIFT, true);
    set_pad_axis(&input, GamepadAxis.RIGHT_TRIGGER, 0.7f);
    actions.update(&input);
    assert(near(actions.value(sprint), 1));

    hold_key(&input, Scancode.LSHIFT, false);
    set_pad_axis(&input, GamepadAxis.RIGHT_TRIGGER, 0.4f);
    actions.update(&input);
    assert(near(actions.value(sprint), 0.4f));
    assert(actions.down(sprint));
}

fn void test_axis_2d_clamps_to_the_unit_disc() @test {
    ActionMap actions = platform::default_action_map();
    ActionId move = actions.add("move", ActionKind.AXIS_2D)!!;
    actions.bind(move, platform::key_binding(Scancode.W, { 0, 1 }))!!;
    actions.bind(move, platform::key_binding(Scancode.D, { 1, 0 }))!!;
    Input input;

    hold_key(&input, Scancode.W, true);
    hold_key(&input, Scancode.D, true);
    actions.update(&input);
    Vec2 both = actions.vector(move);
    assert(near(both.length(), 1));
    assert(near(both.x, 0.70710678f) && near(both.y, 0.70710678f));

    hold_key(&input, Scancode.D, false);
    actions.update(&input);
    Vec2 forward = actions.vector(move);
    assert(near(forward.x, 0) && near(forward.y, 1));
}

fn void test_stick_deadzone_zeroes_inside_and_rescales_outside() @test {
    ActionMap actions = platform::default_action_map();
    ActionId look = actions.add("look", ActionKind.AXIS_2D)!!;
    actions.bind(look, platform::gamepad_stick_binding(GamepadStick.LEFT))!!;
    Input input;

    set_pad_axis(&input, GamepadAxis.LEFTX, 0.1f);
    actions.update(&input);
    assert(near(actions.vector(look).x, 0) && !actions.down(look));

    set_pad_axis(&input, GamepadAxis.LEFTX, 0.575f);
    actions.update(&input);
    assert(near(actions.vector(look).x, 0.5f));

    set_pad_axis(&input, GamepadAxis.LEFTX, 1);
    actions.update(&input);
    assert(near(actions.vector(look).x, 1));
}

fn void test_stick_binding_reads_y_up() @test {
    ActionMap actions = platform::default_action_map();
    ActionId move = actions.add("move", ActionKind.AXIS_2D)!!;
    actions.bind(move, platform::gamepad_stick_binding(GamepadStick.LEFT))!!;
    Input input;

    set_pad_axis(&input, GamepadAxis.LEFTY, -1);
    actions.update(&input);
    assert(near(actions.vector(move).y, 1));
    assert(near(input.gamepad_stick(GamepadStick.LEFT).y, 1));
}

fn void test_gui_capture_gates_keys_and_mouse_but_not_gamepad() @test {
    ActionMap actions = platform::default_action_map();
    ActionId key_action = actions.add("key", ActionKind.BUTTON)!!;
    ActionId mouse_action = actions.add("mouse", ActionKind.BUTTON)!!;
    ActionId pad_action = actions.add("pad", ActionKind.BUTTON)!!;
    actions.bind(key_action, platform::key_binding(Scancode.E))!!;
    actions.bind(mouse_action, platform::mouse_binding(MouseButton.LEFT))!!;
    actions.bind(pad_action, platform::gamepad_button_binding(GamepadButton.SOUTH))!!;
    Input input = { .keyboard_captured_by_gui = true, .mouse_captured_by_gui = true };
    hold_key(&input, Scancode.E, true);
    input.mouse_buttons[(usz)MouseButton.LEFT] = true;
    hold_pad_button(&input, GamepadButton.SOUTH, true);

    actions.update(&input);

    assert(!actions.down(key_action));
    assert(!actions.down(mouse_action));
    assert(actions.down(pad_action));
}

fn void test_disconnected_slot_contributes_nothing() @test {
    ActionMap actions = platform::default_action_map();
    ActionId jump = actions.add("jump", ActionKind.BUTTON)!!;
    actions.bind(jump, platform::gamepad_button_binding(GamepadButton.SOUTH, slot: 1))!!;
    Input input;
    input.gamepads[1].buttons[(usz)GamepadButton.SOUTH] = true;

    actions.update(&input);

    assert(!actions.down(jump));
}

fn void test_unbind_removes_only_that_actions_bindings() @test {
    ActionMap actions = platform::default_action_map();
    ActionId first = actions.add("first", ActionKind.BUTTON)!!;
    ActionId second = actions.add("second", ActionKind.BUTTON)!!;
    actions.bind(first, platform::key_binding(Scancode.A))!!;
    actions.bind(second, platform::key_binding(Scancode.B))!!;
    actions.bind(first, platform::key_binding(Scancode.C))!!;
    Input input;
    hold_key(&input, Scancode.A, true);
    hold_key(&input, Scancode.B, true);
    hold_key(&input, Scancode.C, true);

    actions.unbind(first);
    actions.update(&input);

    assert(actions.binding_count == 1);
    assert(!actions.down(first));
    assert(actions.down(second));
}

fn void test_add_faults_on_duplicate_name_and_full_map() @test {
    ActionMap actions = platform::default_action_map();
    ActionId jump = actions.add("jump", ActionKind.BUTTON)!!;
    if (catch excuse = actions.add("jump", ActionKind.AXIS_1D)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    assert(actions.find("jump")!! == jump);
    if (catch excuse = actions.find("dive")) {
        assert(excuse == NOT_FOUND);
    } else {
        assert(false);
    }

    String[platform::ACTION_COUNT] names;
    for (usz index = 1; index < platform::ACTION_COUNT; index++) {
        names[index] = string::tformat("action%d", index);
        actions.add(names[index], ActionKind.BUTTON)!!;
    }
    if (catch excuse = actions.add("overflow", ActionKind.BUTTON)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }
}

fn void test_bind_faults_when_the_map_is_full() @test {
    ActionMap actions = platform::default_action_map();
    ActionId jump = actions.add("jump", ActionKind.BUTTON)!!;
    for (usz index = 0; index < platform::BINDING_COUNT; index++) {
        actions.bind(jump, platform::key_binding(Scancode.SPACE))!!;
    }
    if (catch excuse = actions.bind(jump, platform::key_binding(Scancode.SPACE))) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }
}

fn void test_axis_normalization_keeps_sign_and_trigger_range() @test {
    assert(platform::normalize_axis(GamepadAxis.LEFTX, -32768) == -1);
    assert(platform::normalize_axis(GamepadAxis.LEFTX, 32767) == 1);
    assert(platform::normalize_axis(GamepadAxis.LEFTY, 0) == 0);
    assert(platform::normalize_axis(GamepadAxis.RIGHT_TRIGGER, 32767) == 1);
    assert(platform::normalize_axis(GamepadAxis.LEFT_TRIGGER, 0) == 0);
}

fn void test_begin_frame_clears_gamepad_transitions() @test {
    Input input;
    input.gamepads[2].pressed[(usz)GamepadButton.EAST] = true;
    input.gamepads[2].released[(usz)GamepadButton.WEST] = true;
    input.gamepads[2].buttons[(usz)GamepadButton.EAST] = true;

    input.begin_frame();

    assert(!input.gamepad_pressed(GamepadButton.EAST, 2));
    assert(!input.gamepad_released(GamepadButton.WEST, 2));
    assert(input.gamepad_down(GamepadButton.EAST, 2));
}
