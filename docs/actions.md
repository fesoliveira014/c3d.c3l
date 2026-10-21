# Action maps

`platform::ActionMap` in `c3d::platform` describes controls as named actions bound to keys, mouse buttons, gamepad buttons,
axes and sticks. The application reads actions instead of devices, so one binding set serves keyboard and pad and can change
at runtime. The map is a plain value with fixed capacity and allocates nothing. Device state comes from `Input`; see
[Windows and input](platform.md).

## Quick start

```c3
import c3d::platform;

ActionMap actions = platform::default_action_map();
ActionId jump = actions.add("jump", ActionKind.BUTTON)!;
ActionId move = actions.add("move", ActionKind.AXIS_2D)!;
ActionId sprint = actions.add("sprint", ActionKind.AXIS_1D)!;

actions.bind(jump, platform::key_binding(Scancode.SPACE))!;
actions.bind(jump, platform::gamepad_button_binding(GamepadButton.SOUTH))!;
actions.bind(move, platform::key_binding(Scancode.W, { 0, 1 }))!;
actions.bind(move, platform::gamepad_stick_binding(GamepadStick.LEFT))!;
actions.bind(sprint, platform::gamepad_axis_binding(GamepadAxis.RIGHT_TRIGGER))!;

while (window.poll()) {
    actions.update(&window.input);
    if (actions.pressed(jump)) hop();
    Vec2 direction = actions.vector(move);
    float run = actions.value(sprint);
}
```

## Concepts

| `ActionKind` | Value | Down while |
| --- | --- | --- |
| `BUTTON` | `value` is 0 or 1 | Any bound source is held. Two held sources give one press; releasing one of them gives no release. |
| `AXIS_1D` | `value` in [-1, 1] | The summed value is nonzero. |
| `AXIS_2D` | `vector` inside the unit disc | The summed vector is nonzero. |

- A binding reads one source on a pad slot (slot 0 by default). A key or button contributes its `scale` while held. An axis
  or stick contributes its value times `scale`, componentwise.
- `AXIS_1D` sums the `x` contributions and clamps to [-1, 1]. `AXIS_2D` sums both components and clamps to the unit disc.
  An axis action is down while its value is nonzero, so `pressed` works on a trigger.
- Sticks apply the map's radial `deadzone` (`DEFAULT_STICK_DEADZONE`, 0.15) and rescale to the full range. A single axis
  binding, including a trigger, applies none.
- Keys and mouse buttons contribute nothing while the GUI captures the keyboard or the mouse. Pad bindings are never gated. A
  binding on a slot that is not connected contributes nothing.
- `update` runs once per frame after polling and reads only `Input`. `pressed` and `released` compare with the previous
  update.
- Action names are borrowed and must outlive the map.

## Change bindings at runtime

`bind` adds a binding, `unbind(action)` removes every binding of an action, and `clear` removes every action and binding.
The change applies at the next `update`. `clear` invalidates every `ActionId`. To rebind, `unbind` the action and `bind` the
new sources.

## Resume a covered map

A zero-initialized `Input` releases every action: the first `update` with it reports `released` for held actions, and later
updates report nothing. A state stack uses this to cover a map while a menu is open.

`settle_edges(&input)` resumes such a map. Call it right after the resume frame's `update`, with the same `Input`:

- An action held from before that frame stays down and reports no `pressed`.
- An action whose every contributing source is a key, mouse button or pad button pressed this frame keeps its `pressed`.
  Axes and sticks have no transitions and count as held.
- `released` reads false, and values do not change. Later updates report edges normally.

Resume on a later frame than the press that uncovered the map. That press is still in `Input` on its own frame, so the
resumed map would report it again.

```c3
Input neutral;
bool was_open;
while (window.poll()) {
    if (menu_open) {
        world_actions.update(&neutral);
    } else {
        world_actions.update(&window.input);
        if (was_open) world_actions.settle_edges(&window.input);
    }
    was_open = menu_open;
    // menu input runs after this and may close the menu
}
```

## Reference

| Binding constructor | Source | Default `scale` |
| --- | --- | --- |
| `key_binding(key, scale)` | Keyboard key | `{ 1, 0 }` |
| `mouse_binding(button, scale)` | Mouse button | `{ 1, 0 }` |
| `gamepad_button_binding(button, scale, slot)` | Pad button | `{ 1, 0 }` |
| `gamepad_axis_binding(axis, scale, slot)` | One pad axis, SDL's sign | `{ 1, 0 }` |
| `gamepad_stick_binding(stick, scale, slot)` | A stick after the deadzone, y up | `{ 1, 1 }` |

| `ActionMap` call | Result |
| --- | --- |
| `add(name, kind)` | New `ActionId`. |
| `find(name)` | `ActionId` of the name. |
| `bind(action, binding)` | Adds a binding. |
| `unbind(action)`, `clear()` | Removes bindings, or everything. |
| `update(&input)` | Evaluates every action from the frame's input. |
| `settle_edges(&input)` | Resumes a covered map; see above. |
| `down(action)`, `pressed(action)`, `released(action)` | Held, went down at the last update, went up at the last update. |
| `value(action)`, `vector(action)` | One-dimensional value (a button gives 0 or 1), two-dimensional value. |

| Constant or field | Value |
| --- | --- |
| `ACTION_COUNT` | 64 actions per map |
| `BINDING_COUNT` | 256 bindings per map |
| `ActionMap.deadzone` | Radial stick deadzone; `default_action_map()` sets `DEFAULT_STICK_DEADZONE` |

| Fault | Raised by |
| --- | --- |
| `CAPACITY_EXCEEDED` | `add` past 64 actions; `bind` past 256 bindings. |
| `INVALID_ARGUMENT` | `add` with a name already in the map. |
| `NOT_FOUND` | `find` with an unknown name. |

An `ActionId` passed to `bind`, `unbind` or an accessor must belong to the map and must not predate a `clear`.

Run the example with `python3 scripts/build.py --example actions`. It binds each action to the keyboard and a pad at once.

## Limits

- Capacities are fixed: 64 actions and 256 bindings per map.
- A map reads one `Input`. It does not own a window or poll devices.
- Mouse motion and the wheel are not bindable sources; read them from `Input`.

## See also

- [Windows and input](platform.md) for `Input`, scancodes, gamepad slots and the GUI capture flags.
- [GUI overlay](gui.md) for the ImGui side of input capture.
