module c3d::platform;

import c3d;
import std::math;

<*
 Dense index of an action in its map; valid until the map is cleared.
*>
typedef ActionId = uint;

<*
 Actions one map holds.
*>
const usz ACTION_COUNT = 64; // a game's control scheme; 64 * 32 B = 2 KiB
<*
 Bindings one map holds.
*>
const usz BINDING_COUNT = 256; // four sources per action; 28 B per binding across both arrays, 7 KiB
<*
 Stick deadzone of a default map.
*>
const float DEFAULT_STICK_DEADZONE = 0.15f; // radial; typical stick drift stays under it

<*
 Value shape an action reports.
*>
enum ActionKind {
    BUTTON,
    AXIS_1D,
    AXIS_2D,
}

<*
 Device input a binding reads.
*>
enum BindingSource {
    KEY,
    MOUSE_BUTTON,
    GAMEPAD_BUTTON,
    GAMEPAD_AXIS,
    GAMEPAD_STICK,
}

<*
 One device input feeding one action; contributes scale while held, or value times scale.
*>
struct Binding {
    BindingSource source;
    union {
        Scancode      key;
        MouseButton   mouse_button;
        GamepadButton gamepad_button;
        GamepadAxis   gamepad_axis;
        GamepadStick  gamepad_stick;
    }
    Vec2 scale;
    usz  gamepad_slot;
}

<*
 Named control and its state after the last update.
*>
struct ActionState {
    String     name;
    ActionKind kind;
    bool       down;
    bool       was_down;
    Vec2       value;
}

<*
 Fixed-capacity set of actions and their bindings.
*>
struct ActionMap {
    ActionState[ACTION_COUNT] actions;
    uint                      action_count;
    Binding[BINDING_COUNT]    bindings;
    ActionId[BINDING_COUNT]   binding_actions;
    uint                      binding_count;
    float                     deadzone;
}

<*
 Add a named action.
 @param name : "Borrowed; must outlive the map."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn ActionId? ActionMap.add(&self, String name, ActionKind kind) {
    if (try self.find(name)) return c3d::INVALID_ARGUMENT~;
    if (self.action_count == ACTION_COUNT) return c3d::CAPACITY_EXCEEDED~;
    self.actions[self.action_count] = { .name = name, .kind = kind };
    self.action_count++;
    return (ActionId)(self.action_count - 1);
}

<*
 Action with the name.
 @return? NOT_FOUND
*>
fn ActionId? ActionMap.find(&self, String name) {
    for (uint index = 0; index < self.action_count; index++) {
        if (self.actions[index].name == name) return (ActionId)index;
    }
    return NOT_FOUND~;
}

<*
 Feed the action from one more device input.
 @return? c3d::CAPACITY_EXCEEDED
 @require (uint)action < self.action_count
*>
fn void? ActionMap.bind(&self, ActionId action, Binding binding) {
    if (self.binding_count == BINDING_COUNT) return c3d::CAPACITY_EXCEEDED~;
    self.bindings[self.binding_count] = binding;
    self.binding_actions[self.binding_count] = action;
    self.binding_count++;
}

<*
 Remove every binding of the action.
 @require (uint)action < self.action_count
*>
fn void ActionMap.unbind(&self, ActionId action) {
    uint kept;
    for (uint index = 0; index < self.binding_count; index++) {
        if (self.binding_actions[index] == action) continue;
        self.bindings[kept] = self.bindings[index];
        self.binding_actions[kept] = self.binding_actions[index];
        kept++;
    }
    self.binding_count = kept;
}

<*
 Remove every action and binding; invalidates every ActionId.
*>
fn void ActionMap.clear(&self) {
    self.action_count = 0;
    self.binding_count = 0;
}

<*
 Evaluate every action from the frame's input.
 @param [&in] input : "Polled this frame."
*>
fn void ActionMap.update(&self, Input* input) {
    for (uint index = 0; index < self.action_count; index++) {
        ActionState* action = &self.actions[index];
        action.was_down = action.down;
        action.down = false;
        action.value = { 0, 0 };
    }

    for (uint index = 0; index < self.binding_count; index++) {
        ActionState* action = &self.actions[(usz)self.binding_actions[index]];
        Vec2 contribution = contribution_of(&self.bindings[index], input, self.deadzone);
        switch (action.kind) {
            case BUTTON: action.down = action.down || contribution != { 0, 0 };
            case AXIS_1D: action.value.x += contribution.x;
            case AXIS_2D: action.value += contribution;
        }
    }

    for (uint index = 0; index < self.action_count; index++) {
        ActionState* action = &self.actions[index];
        switch (action.kind) {
            case BUTTON:
                action.value = { action.down ? 1 : 0, 0 };
            case AXIS_1D:
                action.value.x = math::clamp(action.value.x, -1.0f, 1.0f);
                action.down = action.value.x != 0;
            case AXIS_2D:
                float length = action.value.length();
                if (length > 1) action.value /= length;
                action.down = length != 0;
        }
    }
}

<*
 Drop every edge except this frame's presses; held actions stay down.
 A resume in the frame of the uncovering press repeats that press.
 @param [&in] input : "Input of the update just run."
*>
fn void ActionMap.settle_edges(&self, Input* input) {
    bool[ACTION_COUNT] held_before;
    for (uint index = 0; index < self.binding_count; index++) {
        Binding* binding = &self.bindings[index];
        if (pressed_this_frame(binding, input)) continue;
        if (contribution_of(binding, input, self.deadzone) == { 0, 0 }) continue;
        held_before[(usz)self.binding_actions[index]] = true;
    }

    for (uint index = 0; index < self.action_count; index++) {
        ActionState* action = &self.actions[index];
        action.was_down = action.down && held_before[index];
    }
}

<*
 Whether the action is held.
 @require (uint)action < self.action_count
*>
fn bool ActionMap.down(&self, ActionId action) => self.actions[(usz)action].down;

<*
 Whether the action went down this update.
 @require (uint)action < self.action_count
*>
fn bool ActionMap.pressed(&self, ActionId action) {
    ActionState* state = &self.actions[(usz)action];
    return state.down && !state.was_down;
}

<*
 Whether the action went up this update.
 @require (uint)action < self.action_count
*>
fn bool ActionMap.released(&self, ActionId action) {
    ActionState* state = &self.actions[(usz)action];
    return !state.down && state.was_down;
}

<*
 One-dimensional value; a button gives 0 or 1.
 @require (uint)action < self.action_count
*>
fn float ActionMap.value(&self, ActionId action) => self.actions[(usz)action].value.x;

<*
 Two-dimensional value inside the unit disc.
 @require (uint)action < self.action_count
*>
fn Vec2 ActionMap.vector(&self, ActionId action) => self.actions[(usz)action].value;

<*
 Empty map with the default stick deadzone.
*>
fn ActionMap default_action_map() {
    return { .deadzone = DEFAULT_STICK_DEADZONE };
}

<*
 Binding of a keyboard key.
*>
fn Binding key_binding(Scancode key, Vec2 scale = { 1, 0 }) {
    return { .source = BindingSource.KEY, .key = key, .scale = scale };
}

<*
 Binding of a mouse button.
*>
fn Binding mouse_binding(MouseButton button, Vec2 scale = { 1, 0 }) {
    return { .source = BindingSource.MOUSE_BUTTON, .mouse_button = button, .scale = scale };
}

<*
 Binding of a gamepad button.
 @require slot < GAMEPAD_COUNT
*>
fn Binding gamepad_button_binding(GamepadButton button, Vec2 scale = { 1, 0 }, usz slot = 0) {
    return {
        .source         = BindingSource.GAMEPAD_BUTTON,
        .gamepad_button = button,
        .scale          = scale,
        .gamepad_slot   = slot,
    };
}

<*
 Binding of one gamepad axis; the axis keeps SDL's sign.
 @require slot < GAMEPAD_COUNT
*>
fn Binding gamepad_axis_binding(GamepadAxis axis, Vec2 scale = { 1, 0 }, usz slot = 0) {
    return {
        .source       = BindingSource.GAMEPAD_AXIS,
        .gamepad_axis = axis,
        .scale        = scale,
        .gamepad_slot = slot,
    };
}

<*
 Binding of a stick, y up, after the map's deadzone.
 @require slot < GAMEPAD_COUNT
*>
fn Binding gamepad_stick_binding(GamepadStick stick, Vec2 scale = { 1, 1 }, usz slot = 0) {
    return {
        .source        = BindingSource.GAMEPAD_STICK,
        .gamepad_stick = stick,
        .scale         = scale,
        .gamepad_slot  = slot,
    };
}

fn Vec2 contribution_of(Binding* binding, Input* input, float deadzone) @local {
    switch (binding.source) {
        case KEY:
            if (input.keyboard_captured_by_gui || !input.key_down(binding.key)) return { 0, 0 };
            return binding.scale;
        case MOUSE_BUTTON:
            if (input.mouse_captured_by_gui || !input.button_down(binding.mouse_button)) return { 0, 0 };
            return binding.scale;
        case GAMEPAD_BUTTON:
            if (!input.gamepads[binding.gamepad_slot].connected) return { 0, 0 };
            if (!input.gamepad_down(binding.gamepad_button, binding.gamepad_slot)) return { 0, 0 };
            return binding.scale;
        case GAMEPAD_AXIS:
            if (!input.gamepads[binding.gamepad_slot].connected) return { 0, 0 };
            return binding.scale * input.gamepad_axis(binding.gamepad_axis, binding.gamepad_slot);
        case GAMEPAD_STICK:
            if (!input.gamepads[binding.gamepad_slot].connected) return { 0, 0 };
            Vec2 stick = input.gamepad_stick(binding.gamepad_stick, binding.gamepad_slot);
            return apply_deadzone(stick, deadzone) * binding.scale;
    }
}

fn bool pressed_this_frame(Binding* binding, Input* input) @local {
    switch (binding.source) {
        case KEY: return input.key_pressed(binding.key);
        case MOUSE_BUTTON: return input.button_pressed(binding.mouse_button);
        case GAMEPAD_BUTTON: return input.gamepad_pressed(binding.gamepad_button, binding.gamepad_slot);
        case GAMEPAD_AXIS:
        case GAMEPAD_STICK: return false; // no transitions; a moved axis counts as held
    }
}

fn Vec2 apply_deadzone(Vec2 stick, float deadzone) @local {
    float length = stick.length();
    if (length <= deadzone) return { 0, 0 };
    float rescaled = math::min((length - deadzone) / (1 - deadzone), 1.0f);
    return stick / length * rescaled;
}
