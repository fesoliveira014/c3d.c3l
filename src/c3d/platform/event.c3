module c3d::platform;

import std::math;

<*
 Events one window keeps per frame.
*>
const uint EVENT_CAPACITY = 256; // 17 KiB per window; more than a frame of typing and motion; a full list drops and counts

<*
 UTF-8 bytes of text input one window keeps per frame.
*>
const uint EVENT_TEXT_CAPACITY = 1024; // a full arena drops that text event and counts it

<*
 What one translated event describes.
*>
enum EventKind {
    KEY_DOWN,
    KEY_UP,
    TEXT_INPUT,
    MOUSE_MOTION,
    MOUSE_BUTTON_DOWN,
    MOUSE_BUTTON_UP,
    MOUSE_WHEEL,
    FOCUS_GAINED,
    FOCUS_LOST,
    RESIZED,
    QUIT,
}

<*
 One event of the current frame; text borrows the window's frame arena.
*>
struct Event {
    EventKind   kind;
    Scancode    scancode;
    Keymod      modifiers;
    bool        repeat;
    MouseButton button;
    Vec2        position;
    Vec2        delta;
    Vec2        scroll;
    String      text;
}
