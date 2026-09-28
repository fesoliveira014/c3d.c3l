# Physics inspector

The `c3d_physics_gui` add-on (`addons/c3d_physics_gui.c3l`) extends `c3d::gui` with a physics panel and
inspectors for the physics components. Select `c3d_physics_gui` with the physics package, ImGui and the
renderer's dependencies, and enable `C3D_PHYSICS_GUI`. `C3D_PHYSICS_GUI_CHARACTER` adds the character table,
block and inspector; a build that enables it also selects `c3d_character`. The package never imports `b3`,
and core, the physics package and the character package never import it.

```bash
python3 scripts/build.py --example physics_inspector
python3 scripts/build.py --example physics_inspector_character
```

## Frame loop

```c3
GuiPanelState selection;
PhysicsPanel panel = gui::create_physics_panel(mem, &physics, &scene, &selection);
defer gui::destroy_physics_panel(&panel);
gui::expose_physics_components();   // after register_physics and create_gui_renderer

// each frame, inside the frame's @pool(): labels, queries and contact lists use tmem
gui_renderer.new_frame();
gui::scene_panel(&scene, &selection);
gui::physics_panel(&panel);
time::Clock started = clock::now();
physics.update(panel.step_dt(dt));
panel.record_events((float)(long)started.to_now() / 1_000_000);
scene.flush_removals();
sink.clear();
panel.debug_draw(&sink);
gui_renderer.finish_frame();
```

The panel borrows the world, the scene and the scene panel's `GuiPanelState`; both panels select the same
node. `step_dt` returns 0 while paused (components still sync and poses hold) and one fixed step after Step.
`record_events` must run after the update and before `flush_removals`: it stores the entities of each event,
never node pointers.

## Sections

- **World**: tuning applied through `set_tuning`, Pause and Step, steps, alpha, dropped events and the mean
  update time.
- **Counters** and **Profile**: `PhysicsWorld.counters()` and the last fixed step's phase timings.
- **Draw**: every `PhysicsDebugOptions` flag. Contact forces, graph colours and anchors need Contacts.
  box3d's sleep and contact-feature drawing produce no lines and are not offered. The sink reading (segments
  used, capacity, dropped in red) is one frame old: it covers what the sink held when `debug_draw` finished.
- **Bodies** and **Characters**: tables; a click selects the node.
- **Selected**: one block per physics component of the selected node. Body: state, Enabled, Wake, Rebuild,
  velocity editors, Teleport to origin and the contact list. Joint: force, torque and separations. Ragdoll:
  per-bone mode and weight, the ragdoll weight and drive strength, and the last whole-body recovery. After a
  `recover_ragdoll` whose hips bone has no body, the reading is `FACE_UP` without a computed facing.
  Character: the desc applied through `set_character_desc`, and the live state.
- **Events**: the log, newest first.
- **Queries**: a sphere, capsule or box cast and a box overlap; Show draws them into the sink.
- **Recording**: Start, Stop, Open replay, Step, Restart, Seek and the divergence frame.

`PhysicsPanel.debug_draw` draws the selected node's frame and contacts first, then the query overlay, the
live world and the replay. A full sink therefore loses the replay first and the selection last.

## Where each component is edited

Component-level changes (a desc plus the component's change call) are edited in the scene panel's
inspectors: `PhysicsBody` (body desc and colliders, then `mark_changed`), `PhysicsJoint` (the fields of its
kind, then `mark_changed`), `Wind` and `Force`. Edits that need the world or the scene live in the physics
panel's Selected section: ragdoll modes, weights and drive strength (`set_bone_mode`), character descs
(`set_character_desc`), velocities, enable, wake and teleport. `RigidBody`, `Joint`, `Ragdoll` and `Character`
inspectors are read-only and say where the edit is.

## Recording and replay

Start captures the world's mutations and the tuning's friction and restitution mixes. box3d records calls,
not callbacks, so a replay is faithful only with the recorded world's mixes; the panel reopens replays with
the captured ones. "Replay with box3d's mixes" opens with box3d's instead, which shows a divergence whenever
the mixes decide a contact. The replay runs in its own box3d world with one worker and draws in magenta
over the live world. Hulls, boxes, spheres, capsules and the children of compounds draw as wires; mesh and
height-field shapes draw their bounds.

## Example

`physics_inspector --demo` throws 256 boxes, records a stretch, drops and recovers the figure, replays the
recording and selects a chain link, then prints the sink peak, the replay's divergence and the ragdoll
reading. `--draw-all` raises every draw flag, `--replay-default-mixes` opens replays with box3d's mixes,
`--frames N` closes after N frames. Keys: P pause, N step, R start or stop recording, L open the replay, G
drop the figure, H recover it; the character target moves the walker with the arrow keys.
