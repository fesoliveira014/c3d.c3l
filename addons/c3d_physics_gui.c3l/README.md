# c3d_physics_gui

The physics inspector for c3d: a Dear ImGui panel over a `PhysicsWorld` and inspectors for the physics components. It
extends the `c3d::gui` module of core. The package is `c3d_physics_gui`; every module in it exists only under its
feature. See the [physics inspector guide](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/physics_inspector.md)
for the panel sections, editing rules and recording.

## Features

| Feature | Adds |
| --- | --- |
| `C3D_PHYSICS_GUI` | `create_physics_panel`, `physics_panel`, `PhysicsPanel.debug_draw`, and with `expose_physics_components` the inspectors of `PhysicsBody`, `PhysicsJoint`, `RigidBody`, `Joint`, `Ragdoll`, `Wind` and `Force` |
| `C3D_PHYSICS_GUI_CHARACTER` | The characters table, the character block and the `Character` inspector. Needs `C3D_PHYSICS_GUI` |

## Select the package

The manifest names no dependency. List `c3d_physics_gui`, `c3d_physics`, `b3` and ImGui (`c3imgui`) with c3d's own
dependencies, and enable `C3D_PHYSICS_GUI` in the target's features. With `C3D_PHYSICS_GUI_CHARACTER`, also list
`c3d_character`
([release](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/release.md#using-a-release)).

## Quick start

```c3
GuiPanelState selection;
PhysicsPanel panel = gui::create_physics_panel(
    allocator: mem,
    physics:   &physics,
    scene:     &scene,
    selection: &selection,
);
defer gui::destroy_physics_panel(&panel);
gui::expose_physics_components();

// each frame, between gui_renderer.new_frame() and finish_frame()
gui::scene_panel(&scene, &selection);
gui::physics_panel(&panel);
physics.update(panel.step_dt(delta));
panel.record_events(update_milliseconds);
scene.flush_removals();
sink.clear();
panel.debug_draw(&sink);
```

`expose_physics_components` runs after `register_physics` and `create_gui_renderer`. `sink` is the application's
`DebugDraw`; `update_milliseconds` is the measured duration of `physics.update`.

## Boundaries

- Imports the standard library, core (`c3d`), `c3d::physics` and `imgui`. It never imports `b3`, `gpu` or `sdl`.
- Under `C3D_PHYSICS_GUI_CHARACTER`, `src/character/` alone imports `c3d::character`.
- Core, the physics package and the character package never import it, and it creates no GPU object.

## Targets

| Target | Kind |
| --- | --- |
| `physics_panel_off`, `physics_panel`, `physics_panel_character` | CPU tests without and with each feature, run by `python3 scripts/build.py --test` |
| `physics_inspector`, `physics_inspector_character` | Examples; `python3 scripts/build.py --example physics_inspector` |

```bash
c3c test physics_panel --path addons/c3d_physics_gui.c3l
```
