# Cloth

`c3d::physics::cloth`, in the physics add-on, simulates a triangle mesh with position-based
dynamics: unit-mass particles, one distance constraint per unique triangle edge, one bend
distance per edge shared by exactly two triangles, gravity, node `Wind` drag, damping, hard pins
and an optional ground plane. It imports the standard library, core and `c3d::physics`; it never
creates GPU resources. Core supplies only editable geometry and
[vertex motion history](post.md#edited-vertices).

## Attaching

```c3
ClothDesc desc = cloth::default_cloth_desc();
desc.pins = pinned_vertices;
scene.add_cloth(&assets, flag_node, desc)!;
```

`Scene.add_cloth` copies the node's Mesh geometry into a private asset (positions, indices, UV and
color streams, computed normals, no tangents), builds the constraints from the current world
positions, and replaces `Mesh.geometry` with the copy and enables `Mesh.vertex_motion`. The
source geometry is never written; two cloths on one source own separate copies. The node needs a
current, invertible world matrix. Pins are copied, deduplicated and sorted.

| Fault | Cause |
| --- | --- |
| `NO_MESH` | The node has no Mesh. |
| `CLOTH_EXISTS` | The node already carries a Cloth. |
| `c3d::INVALID_ID` | The Mesh geometry is dead. |
| `physics::SOURCE_UNAVAILABLE` | The source's CPU positions were released. |
| `c3d::UNSUPPORTED` | SkinBinding, morph weights or targets, joints, custom data, a bounds override, or a non-indexed or non-triangle topology. |
| `c3d::INVALID_ARGUMENT` | Zero substeps or iterations, a stiffness outside `[0, 1]`, negative or non-finite damping or thickness, non-finite gravity scale or ground height, a pin or index out of range, non-finite positions, a degenerate triangle or an edge shared by more than two triangles. |
| `c3d::CAPACITY_EXCEEDED` | The geometry pool is full or the state block cannot be allocated. |

Every fault leaves the Mesh, the component store and the asset counts as they were. Defaults: 4
substeps, 8 iterations, stretch stiffness 1, bend stiffness 0.5, damping 0.5 per second,
thickness 0.01 m, gravity scale 1, no pins, no ground.

`Scene.remove_cloth` restores the source geometry and the previous `vertex_motion`, then removes
the component, whose hook removes the private geometry and frees the state block. Removing the
node runs the same hook. The state outlives `destroy_physics_world`; destroy the scene before the
asset store. While attached, do not replace or remove the Mesh, release the private geometry's CPU
streams, change its topology, remove the source asset, or write the library-owned `ClothState`.
To change pins, settings or the source, remove and attach again.

Use two-sided materials without tangent-space normal maps or vertex displacement; the copy
carries no tangents and recomputed normals follow the simulated surface. `Mesh.trace` is the
application's choice.

## Frame order

```text
animation -> scene.update_world -> physics.update
          -> final ragdoll/IK poses -> scene.update_world
          -> physics.update_cloths -> render every view
```

Call `PhysicsWorld.update_cloths` exactly once after each `PhysicsWorld.update`; its contract
checks `cloth_update_serial != update_serial`. Do not change the scene or assets between it and
recording the frame's views. It consumes `steps_last_update` performed fixed steps (dropped backlog
is not replayed) as `steps * substeps` substeps of `fixed_dt / substeps`, and reads `fixed_dt`
and `gravity` from the world tuning, so keep those unchanged between the two calls.

Pins follow the node's final world pose. Each pin keeps the world anchor of its last solved
substep and is interpolated to the current anchor across the update's substeps, landing on it
exactly on the last one. Free particles stay in world space: moving the parent does not drag
them. A zero-step update integrates nothing and keeps the solved anchors; it publishes the solved
positions with pins at the current anchors (ground projection touches that publication only), so
attachment holds without inventing elapsed time, and a later step interpolates from the last
solved anchors.

## Solver and publication

Per substep: wind accelerations from each triangle's area, unit normal and relative air velocity
(`Wind.velocity` minus the mean corner velocity, clamped to `max_speed` when it is positive), as
`drag * area * dot(relative, normal) * normal`, one third per corner; semi-implicit integration
of gravity and wind; damping `max(0, 1 - damping * dt)`; prediction; pins; then `iterations`
passes over edges, bends and the ground (free particles kept at `ground_height + thickness`);
velocities from the corrected displacement. A stiffness `s` is applied per pass as
`1 - (1 - s)^(1 / iterations)`, which normalizes one isolated constraint, not a coupled mesh. A
pair that collapses onto one point separates along its rest direction. `Wind.lift` is unused.

Particles have unit mass, so the wind's effect falls as a mesh gets finer; scale `Wind.drag` with
vertex density (the example uses `2.5 * vertices / area`) to keep a response.

Publication converts world positions through the inverse current node matrix into the private
geometry, recomputes normals and bounds, and calls `mark_geometry_dirty` once when any local
position changed; unchanged output keeps the revision. Solve and publication allocate nothing
after attachment (the CPU triangle tree rebuilds only when a query asks for it).
`PhysicsWorld.cloth_stats` holds the last update's solve and publication seconds, particle count
and constraint count.

Geometry uploads whole on each revision: 47,264 bytes for the 33×33 benchmark flag (positions,
normals, UV and indices). Each temporal view additionally carries 12 bytes per vertex of previous
positions, 13,068 bytes for that flag.

## Example and measurements

```text
python scripts/build.py --example cloth
addons/c3d_physics.c3l/build/cloth.exe --frames 300
c3c build cloth --path addons/c3d_physics.c3l -O3
addons/c3d_physics.c3l/build/cloth.exe --benchmark
```

The interactive flag is 24×16 cells with a pinned edge, gusting wind, and TAA and motion blur
toggles. The benchmark renders the 33×33-vertex flag (32×32 cells, 6,144 constraints) at the
default 4×8 settings to a 1280×720 TAA and motion-blur view, with 120 warm-up and 600 measured 60 Hz
frames and Vulkan validation on. On Windows, RTX 4090, C3 0.8.3 `-O3`, three runs: solve 1.34-1.53 ms
mean (p95 1.85-2.19 ms, frames that took two physics steps), publication 0.013-0.015 ms, GPU frame
0.165-0.167 ms median, 47,264 uploaded geometry bytes per frame.

No self-collision, tearing, soft pins, dihedral bending, skinned base pose, tangents, GPU or crowd
simulation, or simulation-origin rebasing. Parallel solving waits for a measured consumer need.
