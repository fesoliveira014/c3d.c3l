# Debug lines

`debug::DebugDraw` in `c3d::debug` is the line list an application fills each frame and hands to a view. It draws bounds,
frusta, light and probe volumes, skeletons and IK chains as world-space segments, with no GPU object of its own. The
renderer uploads what the sink holds when it records the view.

## Quick start

```c3
import c3d::debug;

DebugDraw sink = debug::create_debug_draw(mem);
defer debug::destroy_debug_draw(&sink);

// each frame
sink.clear();
sink.mesh_bounds(&scene, &assets, debug::COLOR_GREEN);
sink.node_axes(selected_node, 1.0f);

renderer.render_view(
    scene:       &scene,
    camera_node: camera_node,
    view:        renderer.default_view,
    debug:       &sink,
)!;
```

Fill the sink after `Scene.update_world`, so the helpers read current world matrices.

## Concepts

- **Per-frame sink.** `render_view(..., debug: &sink)` draws the sink's segments into that view and never clears it. Call
  `clear()` before filling it again. One sink may go to several views.
- **Color.** A color is a packed `uint` with red in the low byte, as `unpackUnorm4x8` reads it. `debug::rgba(red, green,
  blue, alpha = 1)` packs one from floats in [0, 1]. `COLOR_RED`, `COLOR_GREEN`, `COLOR_BLUE`, `COLOR_WHITE` and
  `COLOR_YELLOW` are predefined.
- **Depth.** Lines are drawn after transparent geometry. A segment in front of the depth buffer draws at full opacity; one
  behind geometry draws at a quarter of it, so it stays readable without hiding the scene.
- **Positions.** Segments are in world space. The renderer subtracts the frame origin when it uploads them.
- **Full sink.** A full sink refuses further segments and counts them in `DebugDraw.dropped`. What is drawn first survives, so
  draw what matters most first.

## Helpers

Every helper writes through `DebugDraw.line`, one segment at a time.

| Helper | Draws |
| --- | --- |
| `line(from, to, rgba)` | One segment. |
| `aabb(bounds, rgba)` | The twelve edges of an axis-aligned box. |
| `box(world, local, rgba)` | A local box under a world matrix. |
| `frustum(inv_view_proj, rgba)` | A reverse-Z view frustum; pass `CameraMatrices.inv_view_proj`. |
| `circle(center, normal, radius, rgba)` | A circle of 32 segments around a normal. |
| `capsule(center, axis, half_height, radius, rgba)` | A capsule outline; `axis` has unit length. |
| `axes(world, size)` | Red, green and blue axes of a world matrix, unscaled. |
| `node_axes(node, size)` | The axes of one node's world matrix. |
| `mesh_bounds(scene, assets, rgba)` | The world box of every visible mesh. |
| `light_volumes(scene, rgba)` | An arrow per directional light, range circles per point light, a cone per spot light. |
| `probe_volumes(scene, rgba)` | The box and a cross per probe of every volume on a visible node. |
| `reflection_probes(scene, rgba)` | Each visible reflection probe's oriented box and a cross at its capture point. |
| `joints(scene, rgba)` | Bone segments and joint axes of every skin binding. |
| `ik(scene, rgba)` | IK chains, foot hits and look-at lines. |
| `Renderer.draw_shadow_frusta(sink, rgba)` | The shadow cameras of the last recorded frame as frusta. |

The physics, character and navigation packages add `debug_draw` methods that take a sink: `PhysicsWorld.debug_draw`,
`CharacterSystem.debug_draw`, `NavMesh.debug_draw` and `Crowd.debug_draw`. See the
[physics](../addons/c3d_physics.c3l/README.md), [character](../addons/c3d_character.c3l/README.md) and
[navigation](../addons/c3d_nav.c3l/README.md) package READMEs.

## Capacity and sizing

`create_debug_draw(allocator, capacity = DEBUG_LINE_CAPACITY)` allocates the sink once. The capacity is in segments; each
segment is two 16-byte vertices, so the default 16,384 segments take 512 KiB. The renderer uploads whatever the sink holds
through the frame's upload ring and has no cap of its own.

`Stats.debug_lines` counts the segments each view drew. `Stats.debug_dropped` is the largest `dropped` count of a sink drawn
this frame. The [GUI stats panel](gui_panels.md#stats-panel) prints both.

To size a sink, run the heaviest frame the application reaches with every flag it offers, read `vertices.len() / 2 + dropped`
(the segments it asked for), and add a margin.

## Limits

- The sink has fixed capacity and drops segments past it.
- Lines draw into the view's scene image, so a view with post processing grades them with the scene.
- Helpers read the scene as left by the last `update_world`; they do not update it.

## See also

- [Views](views.md) for `render_view` and its parameters.
- [GUI panels](gui_panels.md) for the stats panel.
- [Probe volumes](probe_volumes.md) and [reflection probes](reflection_probes.md) for the volumes the helpers outline.
