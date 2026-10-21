# Physics inspector

The `c3d_physics_gui` add-on (`addons/c3d_physics_gui.c3l`) extends `c3d::gui` with a physics panel and inspectors for
the physics components: world tuning, pause and step, counters, debug-draw flags, bodies, the selected node, events,
queries, and recording and replay. It needs the `C3D_PHYSICS_GUI` feature. `C3D_PHYSICS_GUI_CHARACTER` adds the
character table, block and inspector. The package never imports `b3`, and core, the physics package and the character
package never import it. See the package
[README](../addons/c3d_physics_gui.c3l/README.md) for the dependencies to select.

## Quick start

Build and run an example:

```bash
python3 scripts/build.py --example physics_inspector
python3 scripts/build.py --example physics_inspector_character
```

In an application, create the panel once and run it inside the GUI frame:

```c3
GuiPanelState selection;
PhysicsPanel panel = gui::create_physics_panel(mem, &physics, &scene, &selection);
defer gui::destroy_physics_panel(&panel);
gui::expose_physics_components();

// each frame
gui_renderer.new_frame();
gui::scene_panel(&scene, &selection);
gui::physics_panel(&panel);
time::Clock started = clock::now();
physics.update(panel.step_dt(delta));
panel.record_events((float)(long)started.to_now() / 1_000_000);
scene.flush_removals();
sink.clear();
panel.debug_draw(&sink);
gui_renderer.finish_frame();
renderer.render_view(&scene, camera_node, view, debug: &sink)!;
```

Call `expose_physics_components` after `register_physics` and `create_gui_renderer`. `sink` is the application's
[`DebugDraw`](debug_draw.md).

## Concepts

The panel borrows the world, the scene and the scene panel's `GuiPanelState`; both panels select the same node. Its
allocator must outlive it, because the event log, the recording bytes and the replays come from it. `physics_panel`
and `debug_draw` open their own temporary pools.

- `step_dt(dt)` returns 0 while paused (components still sync and poses hold) and one fixed step after Step.
- `record_events` runs after the update and before `flush_removals`. It stores the entities of each event, never node
  pointers.
- `PhysicsPanel.debug_draw` draws the selected node's frame and contacts first, then the query overlay, the live world
  and the replay, so a full sink loses the replay first and the selection last.

## Sections

- **World**: tuning applied through `set_tuning`, Pause and Step, steps, alpha, dropped events and the mean update time.
- **Counters** and **Profile**: `PhysicsWorld.counters()` and the last fixed step's phase timings.
- **Draw**: every `PhysicsDebugOptions` flag. "Replay queries" draws the queries the replayed frame re-issued (casts as
  segments, movers and cast shapes as capsules and spheres, overlaps as boxes). Contact forces, graph colors and anchors
  need Contacts. box3d's sleep and contact-feature drawing produce no lines and are not offered. The sink reading
  (segments used, capacity, dropped in red) is one frame old.
- **Bodies** and **Characters**: tables; a click selects the node.
- **Selected**: one block per physics component of the selected node.
  - Body: state, Enabled, Wake, Rebuild, velocity editors, Teleport to origin and the contact list.
  - Joint: force, torque and separations.
  - Ragdoll: per-bone mode and weight, ragdoll weight and drive strength, the last successful whole-body recovery, and
    the transient [recovery](ragdoll.md#physical-recovery) phase, active bone count, mapped-joint residuals, absolute body
    speeds and actuator force and torque. A missing required body returns `NO_BODY` and keeps the previous facing and
    recovery count. Mode edits cancel recovery for the selected bone, including a request for its existing mode; weight
    edits change the next update's target. `BLOCKED` is a diagnostic and does not disable contacts.
  - Character: the description applied through `set_character_desc` and the live state.
- **Events**: the log, newest first.
- **Queries**: a sphere, capsule or box cast and a box overlap; Show draws them into the sink.
- **Recording**: Start, Stop, Open replay, Step, Restart, Seek and the divergence frame.

## Edit components

Component-level changes (a description plus the component's change call) are edited in the scene panel's inspectors:
`PhysicsBody` (the body description except `disabled`, and the colliders, then `mark_changed`), `PhysicsJoint` (the fields
of its kind, then `mark_changed`), `Wind` and `Force`. Enabling goes through the panel's Enabled checkbox
(`set_enabled`), which keeps the body's motion.

Edits that need the world or the scene live in the physics panel's Selected section: ragdoll modes, weights and drive
strength (`set_bone_mode`), character descriptions (`set_character_desc`), velocities, enable, wake and teleport. The
`RigidBody`, `Joint`, `Ragdoll` and `Character` inspectors are read-only and say where the edit is.

## Record and replay

Start captures the world's mutations and the tuning's friction and restitution mixes. box3d records calls, not
callbacks, so a replay is faithful only with the recorded world's mixes; the panel reopens replays with the captured
ones. "Replay with box3d's mixes" opens with box3d's instead, which shows a divergence whenever the mixes decide a
contact. The replay runs in its own box3d world with one worker and draws in magenta over the live world. Hulls, boxes,
spheres, capsules and the children of compounds draw as wires; mesh and height-field shapes draw their bounds.

## Example

`physics_inspector` shows the panel over a level with thrown boxes, a short chain and a ragdoll figure. Keys: P pause, N step, R start or stop
recording, L open the replay, G drop the figure, H recover it. `--frames N` closes after N frames. The character target
moves a walker with the arrow keys.

## Limits

- The panel edits only through the world's and scene's public calls; it cannot change creation-time settings such as
  `worker_count` or `event_capacity`.
- A replay shows the box3d world only. It does not recreate scene components or events.
- Drive strength controls the ordinary animation springs and does not scale the recovery actuator.

## See also

- [Physics](physics.md), [ragdolls](ragdoll.md) and [GUI](gui.md)
- The package [README](../addons/c3d_physics_gui.c3l/README.md)
