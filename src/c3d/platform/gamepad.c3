module c3d::platform;

import sdl;
import std::math;

<*
 Gamepad slots the platform tracks.
*>
const usz GAMEPAD_COUNT = 4; // four-player local play; a fifth pad stays unassigned
<*
 Buttons one gamepad reports.
*>
const usz GAMEPAD_BUTTON_COUNT = 26; // mirrors sdl::GamepadButton.COUNT
<*
 Axes one gamepad reports.
*>
const usz GAMEPAD_AXIS_COUNT = 6; // mirrors sdl::GamepadAxis.COUNT
const float AXIS_RANGE @local = 32767.0f;

<*
 Gamepad button by position, numbered as SDL numbers them.
*>
constdef GamepadButton : char {
    SOUTH          = 0,
    EAST           = 1,
    WEST           = 2,
    NORTH          = 3,
    BACK           = 4,
    GUIDE          = 5,
    START          = 6,
    LEFT_STICK     = 7,
    RIGHT_STICK    = 8,
    LEFT_SHOULDER  = 9,
    RIGHT_SHOULDER = 10,
    DPAD_UP        = 11,
    DPAD_DOWN      = 12,
    DPAD_LEFT      = 13,
    DPAD_RIGHT     = 14,
    MISC1          = 15,
    RIGHT_PADDLE1  = 16,
    LEFT_PADDLE1   = 17,
    RIGHT_PADDLE2  = 18,
    LEFT_PADDLE2   = 19,
    TOUCHPAD       = 20,
    MISC2          = 21,
    MISC3          = 22,
    MISC4          = 23,
    MISC5          = 24,
    MISC6          = 25,
    COUNT          = 26,
}

<*
 Gamepad axis, numbered as SDL numbers them.
*>
constdef GamepadAxis : char {
    LEFTX         = 0,
    LEFTY         = 1,
    RIGHTX        = 2,
    RIGHTY        = 3,
    LEFT_TRIGGER  = 4,
    RIGHT_TRIGGER = 5,
    COUNT         = 6,
}

<*
 One of the two analog sticks.
*>
enum GamepadStick {
    LEFT,
    RIGHT,
}

<*
 Face label printed on a connected pad's button.
*>
enum GamepadLabel {
    UNKNOWN,
    A,
    B,
    X,
    Y,
    CROSS,
    CIRCLE,
    SQUARE,
    TRIANGLE,
}

<*
 State of one gamepad slot for the current frame.
 Stick axes keep SDL's sign, y down; triggers lie in [0, 1].
*>
struct Gamepad {
    bool                       connected;
    bool[GAMEPAD_BUTTON_COUNT] buttons;
    bool[GAMEPAD_BUTTON_COUNT] pressed;
    bool[GAMEPAD_BUTTON_COUNT] released;
    float[GAMEPAD_AXIS_COUNT]  axes;
}

struct GamepadDevice @private {
    sdl::JoystickID id;
    sdl::Gamepad*   handle;
}

GamepadDevice[GAMEPAD_COUNT] gamepad_devices @private;
int gamepad_users @private;

<*
 Name of the pad in the slot; empty when none is connected.
 Borrowed until the pad disconnects.
 @require slot < GAMEPAD_COUNT
*>
fn ZString gamepad_name(usz slot) {
    sdl::Gamepad* handle = gamepad_devices[slot].handle;
    if (!handle) return "";
    ZString name = (ZString)sdl::get_gamepad_name(handle);
    return name ? name : "";
}

<*
 Face label of the button on the pad in the slot; UNKNOWN when none is connected.
 @require slot < GAMEPAD_COUNT
*>
fn GamepadLabel gamepad_button_label(usz slot, GamepadButton button) {
    sdl::Gamepad* handle = gamepad_devices[slot].handle;
    if (!handle) return GamepadLabel.UNKNOWN;
    switch (sdl::get_gamepad_button_label(handle, (sdl::GamepadButton)(int)button)) {
        case UNKNOWN: return GamepadLabel.UNKNOWN;
        case A: return GamepadLabel.A;
        case B: return GamepadLabel.B;
        case X: return GamepadLabel.X;
        case Y: return GamepadLabel.Y;
        case CROSS: return GamepadLabel.CROSS;
        case CIRCLE: return GamepadLabel.CIRCLE;
        case SQUARE: return GamepadLabel.SQUARE;
        case TRIANGLE: return GamepadLabel.TRIANGLE;
    }
}

fn void? acquire_gamepads() @private {
    if (!gamepad_users && !sdl::init({ .gamepad = true })) return GAMEPAD_INIT_FAILED~;
    gamepad_users++;
}

fn void release_gamepads() @private {
    gamepad_users--;
    if (gamepad_users) return;
    foreach (&device : gamepad_devices) {
        if (device.handle) sdl::close_gamepad(device.handle);
        *device = {};
    }
    sdl::quit_sub_system({ .gamepad = true });
}

fn usz? gamepad_slot(sdl::JoystickID id) @private {
    foreach (usz slot, device : gamepad_devices) {
        if (device.handle && device.id == id) return slot;
    }
    return NOT_FOUND~;
}

fn void open_gamepad_slot(sdl::JoystickID id) @private {
    if (try gamepad_slot(id)) return;
    foreach (&device : gamepad_devices) {
        if (device.handle) continue;
        sdl::Gamepad* handle = sdl::open_gamepad(id);
        if (handle) *device = { .id = id, .handle = handle };
        return;
    }
}

fn void close_gamepad_slot(sdl::JoystickID id) @private {
    usz? slot = gamepad_slot(id);
    if (catch slot) return;
    sdl::close_gamepad(gamepad_devices[slot].handle);
    gamepad_devices[slot] = {};
}

fn float normalize_axis(GamepadAxis axis, short value) @private {
    float scaled = (float)value / AXIS_RANGE;
    if (axis == GamepadAxis.LEFT_TRIGGER || axis == GamepadAxis.RIGHT_TRIGGER) return math::clamp(scaled, 0.0f, 1.0f);
    return math::clamp(scaled, -1.0f, 1.0f);
}

fn void seed_gamepads(Input* input) @private {
    foreach (usz slot, device : gamepad_devices) input.gamepads[slot].connected = device.handle != null;
}
