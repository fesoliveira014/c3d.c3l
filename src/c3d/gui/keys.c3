module c3d::gui;

import c3d::platform;
import imgui;

<*
 ImGui key of a physical key; KEY_NONE when ImGui has no name for it.
*>
fn imgui::Key imgui_key_of(Scancode key) {
    switch (key) {
        case Scancode.A: return imgui::KEY_A;
        case Scancode.B: return imgui::KEY_B;
        case Scancode.C: return imgui::KEY_C;
        case Scancode.D: return imgui::KEY_D;
        case Scancode.E: return imgui::KEY_E;
        case Scancode.F: return imgui::KEY_F;
        case Scancode.G: return imgui::KEY_G;
        case Scancode.H: return imgui::KEY_H;
        case Scancode.I: return imgui::KEY_I;
        case Scancode.J: return imgui::KEY_J;
        case Scancode.K: return imgui::KEY_K;
        case Scancode.L: return imgui::KEY_L;
        case Scancode.M: return imgui::KEY_M;
        case Scancode.N: return imgui::KEY_N;
        case Scancode.O: return imgui::KEY_O;
        case Scancode.P: return imgui::KEY_P;
        case Scancode.Q: return imgui::KEY_Q;
        case Scancode.R: return imgui::KEY_R;
        case Scancode.S: return imgui::KEY_S;
        case Scancode.T: return imgui::KEY_T;
        case Scancode.U: return imgui::KEY_U;
        case Scancode.V: return imgui::KEY_V;
        case Scancode.W: return imgui::KEY_W;
        case Scancode.X: return imgui::KEY_X;
        case Scancode.Y: return imgui::KEY_Y;
        case Scancode.Z: return imgui::KEY_Z;
        case Scancode.CODE_1: return imgui::KEY_1;
        case Scancode.CODE_2: return imgui::KEY_2;
        case Scancode.CODE_3: return imgui::KEY_3;
        case Scancode.CODE_4: return imgui::KEY_4;
        case Scancode.CODE_5: return imgui::KEY_5;
        case Scancode.CODE_6: return imgui::KEY_6;
        case Scancode.CODE_7: return imgui::KEY_7;
        case Scancode.CODE_8: return imgui::KEY_8;
        case Scancode.CODE_9: return imgui::KEY_9;
        case Scancode.CODE_0: return imgui::KEY_0;
        case Scancode.RETURN: return imgui::KEY_ENTER;
        case Scancode.ESCAPE: return imgui::KEY_ESCAPE;
        case Scancode.BACKSPACE: return imgui::KEY_BACKSPACE;
        case Scancode.TAB: return imgui::KEY_TAB;
        case Scancode.SPACE: return imgui::KEY_SPACE;
        case Scancode.MINUS: return imgui::KEY_MINUS;
        case Scancode.EQUALS: return imgui::KEY_EQUAL;
        case Scancode.LEFTBRACKET: return imgui::KEY_LEFT_BRACKET;
        case Scancode.RIGHTBRACKET: return imgui::KEY_RIGHT_BRACKET;
        case Scancode.BACKSLASH: return imgui::KEY_BACKSLASH;
        case Scancode.SEMICOLON: return imgui::KEY_SEMICOLON;
        case Scancode.APOSTROPHE: return imgui::KEY_APOSTROPHE;
        case Scancode.GRAVE: return imgui::KEY_GRAVE_ACCENT;
        case Scancode.COMMA: return imgui::KEY_COMMA;
        case Scancode.PERIOD: return imgui::KEY_PERIOD;
        case Scancode.SLASH: return imgui::KEY_SLASH;
        case Scancode.CAPSLOCK: return imgui::KEY_CAPS_LOCK;
        case Scancode.F1: return imgui::KEY_F1;
        case Scancode.F2: return imgui::KEY_F2;
        case Scancode.F3: return imgui::KEY_F3;
        case Scancode.F4: return imgui::KEY_F4;
        case Scancode.F5: return imgui::KEY_F5;
        case Scancode.F6: return imgui::KEY_F6;
        case Scancode.F7: return imgui::KEY_F7;
        case Scancode.F8: return imgui::KEY_F8;
        case Scancode.F9: return imgui::KEY_F9;
        case Scancode.F10: return imgui::KEY_F10;
        case Scancode.F11: return imgui::KEY_F11;
        case Scancode.F12: return imgui::KEY_F12;
        case Scancode.F13: return imgui::KEY_F13;
        case Scancode.F14: return imgui::KEY_F14;
        case Scancode.F15: return imgui::KEY_F15;
        case Scancode.F16: return imgui::KEY_F16;
        case Scancode.F17: return imgui::KEY_F17;
        case Scancode.F18: return imgui::KEY_F18;
        case Scancode.F19: return imgui::KEY_F19;
        case Scancode.F20: return imgui::KEY_F20;
        case Scancode.F21: return imgui::KEY_F21;
        case Scancode.F22: return imgui::KEY_F22;
        case Scancode.F23: return imgui::KEY_F23;
        case Scancode.F24: return imgui::KEY_F24;
        case Scancode.PRINTSCREEN: return imgui::KEY_PRINT_SCREEN;
        case Scancode.SCROLLLOCK: return imgui::KEY_SCROLL_LOCK;
        case Scancode.PAUSE: return imgui::KEY_PAUSE;
        case Scancode.INSERT: return imgui::KEY_INSERT;
        case Scancode.HOME: return imgui::KEY_HOME;
        case Scancode.PAGEUP: return imgui::KEY_PAGE_UP;
        case Scancode.DELETE: return imgui::KEY_DELETE;
        case Scancode.END: return imgui::KEY_END;
        case Scancode.PAGEDOWN: return imgui::KEY_PAGE_DOWN;
        case Scancode.RIGHT: return imgui::KEY_RIGHT_ARROW;
        case Scancode.LEFT: return imgui::KEY_LEFT_ARROW;
        case Scancode.DOWN: return imgui::KEY_DOWN_ARROW;
        case Scancode.UP: return imgui::KEY_UP_ARROW;
        case Scancode.NUMLOCKCLEAR: return imgui::KEY_NUM_LOCK;
        case Scancode.KP_DIVIDE: return imgui::KEY_KEYPAD_DIVIDE;
        case Scancode.KP_MULTIPLY: return imgui::KEY_KEYPAD_MULTIPLY;
        case Scancode.KP_MINUS: return imgui::KEY_KEYPAD_SUBTRACT;
        case Scancode.KP_PLUS: return imgui::KEY_KEYPAD_ADD;
        case Scancode.KP_ENTER: return imgui::KEY_KEYPAD_ENTER;
        case Scancode.KP_1: return imgui::KEY_KEYPAD1;
        case Scancode.KP_2: return imgui::KEY_KEYPAD2;
        case Scancode.KP_3: return imgui::KEY_KEYPAD3;
        case Scancode.KP_4: return imgui::KEY_KEYPAD4;
        case Scancode.KP_5: return imgui::KEY_KEYPAD5;
        case Scancode.KP_6: return imgui::KEY_KEYPAD6;
        case Scancode.KP_7: return imgui::KEY_KEYPAD7;
        case Scancode.KP_8: return imgui::KEY_KEYPAD8;
        case Scancode.KP_9: return imgui::KEY_KEYPAD9;
        case Scancode.KP_0: return imgui::KEY_KEYPAD0;
        case Scancode.KP_PERIOD: return imgui::KEY_KEYPAD_DECIMAL;
        case Scancode.NONUSBACKSLASH: return imgui::KEY_OEM102;
        case Scancode.APPLICATION: return imgui::KEY_MENU;
        case Scancode.KP_EQUALS: return imgui::KEY_KEYPAD_EQUAL;
        case Scancode.LCTRL: return imgui::KEY_LEFT_CTRL;
        case Scancode.LSHIFT: return imgui::KEY_LEFT_SHIFT;
        case Scancode.LALT: return imgui::KEY_LEFT_ALT;
        case Scancode.LGUI: return imgui::KEY_LEFT_SUPER;
        case Scancode.RCTRL: return imgui::KEY_RIGHT_CTRL;
        case Scancode.RSHIFT: return imgui::KEY_RIGHT_SHIFT;
        case Scancode.RALT: return imgui::KEY_RIGHT_ALT;
        case Scancode.RGUI: return imgui::KEY_RIGHT_SUPER;
        case Scancode.AC_BACK: return imgui::KEY_APP_BACK;
        case Scancode.AC_FORWARD: return imgui::KEY_APP_FORWARD;
        default: return imgui::KEY_NONE;
    }
}

<*
 Whether ImGui names the mouse button, and its index when it does.
 @param [&out] index : "Untouched when ImGui has no button for it."
*>
fn bool imgui_button_of(platform::MouseButton button, int* index) {
    switch (button) {
        case platform::MouseButton.LEFT: *index = 0;
        case platform::MouseButton.RIGHT: *index = 1;
        case platform::MouseButton.MIDDLE: *index = 2;
        case platform::MouseButton.X1: *index = 3;
        case platform::MouseButton.X2: *index = 4;
        default: return false;
    }
    return true;
}
