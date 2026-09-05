module c3d::platform;

import std::math;

const usz KEY_COUNT = 512;   // mirrors sdl::Scancode.COUNT
const usz MOUSE_BUTTON_COUNT = 8;

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
    bool[MOUSE_BUTTON_COUNT] mouse_buttons;
    Vec2                     mouse_position;
    Vec2                     mouse_delta;
    float                    wheel;
    bool                     mouse_captured_by_gui;
    bool                     keyboard_captured_by_gui;
}

<*
 Clear the state that lasts a single frame.
*>
fn void Input.begin_frame(&self) {
    self.keys_pressed = {};
    self.mouse_delta = { 0, 0 };
    self.wheel = 0;
}

<*
 Advance to a new performance counter sample.
 @require frequency > 0
*>
fn void Clock.advance(&self, ulong counter, ulong frequency) {
    self.delta = (float)((double)(counter - self.counter) / (double)frequency);
    self.total += self.delta;
    self.frame++;
    self.counter = counter;
}
