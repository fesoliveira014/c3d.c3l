module c3d::platform;

import std::math;

<*
 Number of addressable keyboard scancodes.
*>
const usz KEY_COUNT = 512; // mirrors sdl::Scancode.COUNT
<*
 Number of addressable mouse button slots.
*>
const usz MOUSE_BUTTON_COUNT = 8;

<*
 Mouse button, numbered as SDL numbers buttons.
*>
constdef MouseButton : char {
    LEFT   = 1,
    MIDDLE = 2,
    RIGHT  = 3,
    X1     = 4,
    X2     = 5,
}

<*
 Modifier state carried by a key event.
*>
bitstruct Keymod : ushort {
    bool shift : 0;
    bool ctrl  : 1;
    bool alt   : 2;
    bool gui   : 3;
    bool caps  : 4;
    bool num   : 5;
}

<*
 Wall clock advanced once per poll.
*>
struct Clock {
    double total;
    float  delta;
    ulong  frame;
    ulong  counter;
}

<*
 Keyboard and mouse state for the current frame.
*>
struct Input {
    bool[KEY_COUNT]          keys;
    bool[KEY_COUNT]          keys_pressed;
    bool[KEY_COUNT]          keys_released;
    bool[MOUSE_BUTTON_COUNT] mouse_buttons;
    bool[MOUSE_BUTTON_COUNT] mouse_pressed;
    Vec2                     mouse_position;
    Vec2                     mouse_delta;
    float                    wheel;
    bool                     mouse_captured_by_gui;
    bool                     keyboard_captured_by_gui;
    Keymod                   modifiers;
}

<*
 Whether the key is held.
 @require (usz)key < KEY_COUNT
*>
fn bool Input.key_down(&self, Scancode key) => self.keys[(usz)key];

<*
 Whether the key went down this frame.
 @require (usz)key < KEY_COUNT
*>
fn bool Input.key_pressed(&self, Scancode key) => self.keys_pressed[(usz)key];

<*
 Whether the key went up this frame.
 @require (usz)key < KEY_COUNT
*>
fn bool Input.key_released(&self, Scancode key) => self.keys_released[(usz)key];

<*
 Whether the button is held.
*>
fn bool Input.button_down(&self, MouseButton button) => self.mouse_buttons[(usz)button];

<*
 Whether the button went down this frame.
*>
fn bool Input.button_pressed(&self, MouseButton button) => self.mouse_pressed[(usz)button];

<*
 Clear the state that lasts a single frame.
 @param [&inout] self : "Input whose transient state is cleared."
*>
fn void Input.begin_frame(&self) {
    self.keys_pressed = {};
    self.keys_released = {};
    self.mouse_pressed = {};
    self.mouse_delta = { 0, 0 };
    self.wheel = 0;
}

<*
 Advance to a new performance counter sample.
 @param [&inout] self : "Clock holding the previous sample."
 @require frequency > 0
*>
fn void Clock.advance(&self, ulong counter, ulong frequency) {
    self.delta = (float)((double)(counter - self.counter) / (double)frequency);
    self.total += self.delta;
    self.frame++;
    self.counter = counter;
}
