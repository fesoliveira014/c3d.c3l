# Cloth

`c3d::physics::cloth`, in the physics add-on, simulates a triangle mesh with position-based
dynamics: unit-mass particles, one distance constraint per unique triangle edge, one bend
distance per edge shared by exactly two triangles, gravity, node `Wind` drag, damping, hard pins,
an optional ground plane and one-way contacts with the sphere and capsule colliders of listed
rigid bodies. It imports the standard library, core and `c3d::physics`; it never
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
current, invertible world matrix. Pins are copied, deduplicated and sorted; collider ids and
their shapes are copied (see [Collisions](#collisions)).

| Fault | Cause |
| --- | --- |
| `NO_MESH` | The node has no Mesh. |
| `CLOTH_EXISTS` | The node already carries a Cloth. |
| `c3d::INVALID_ID` | The Mesh geometry or a listed collider entity is dead. |
| `physics::SOURCE_UNAVAILABLE` | The source's CPU positions were released. |
| `physics::NO_BODY` | A listed collider node has no built RigidBody. |
| `c3d::UNSUPPORTED` | SkinBinding, morph weights or targets, joints, custom data, a bounds override, or a non-indexed or non-triangle topology. |
| `c3d::INVALID_ARGUMENT` | Zero substeps or iterations, a stiffness outside `[0, 1]`, negative or non-finite damping or thickness, non-finite gravity scale or ground height, a pin or index out of range, non-finite positions, a degenerate triangle, an edge shared by more than two triangles, or a collider listed twice. |
| `c3d::CAPACITY_EXCEEDED` | More than 32 listed colliders or captured shapes, a full geometry pool, or a state block that cannot be allocated. |

Every fault leaves the Mesh, the component store and the asset counts as they were. Defaults: 4
substeps, 8 iterations, stretch stiffness 1, bend stiffness 0.5, damping 0.5 per second,
thickness 0.01 m, gravity scale 1, no pins, no ground, no colliders.

`Scene.remove_cloth` restores the source geometry and the previous `vertex_motion`, then removes
the component, whose hook removes the private geometry and frees runtime and authoring storage. Removing the
node runs the same hook. The state outlives `destroy_physics_world`; destroy the scene before the
asset store. While attached, do not replace or remove the Mesh, release the private geometry's CPU
streams, change its topology, remove the source asset, or write the library-owned `ClothState`.
To change pins, settings or the source, remove and attach again.

Use two-sided materials without tangent-space normal maps or vertex displacement; the copy
carries no tangents and recomputed normals follow the simulated surface. `Mesh.trace` is the
application's choice.

## Pending authoring and preparation

The shared [owner readiness table](owner_readiness.md) records preparation order
and pending draw behavior.

`scene.attach_cloth(&assets, node, desc)` validates and attaches authoring without
creating a private geometry asset or simulation state. `Cloth.authoring` owns the
source geometry identity, original `vertex_motion` flag, complete descriptor and
copies of the requested pins and collider identities. Its arrays are read-only.
Requested pin order and duplicates are retained; preparation builds the separate
sorted, deduplicated simulation pin list.

`Cloth.is_prepared()` is false until `cloth::prepare(&scene, &assets, node)`
installs the complete runtime and switches the Mesh to its private geometry.
Until then the existing Mesh remains unchanged and draws the authored source.
Attachment validates retained source streams and pin/contact identities;
world-space triangle constraints and native contact shapes are validated during
preparation, after node world matrices are current.

For listed contact owners, run the ordinary physics update first so their
`PhysicsBody` authoring acquires `RigidBody` mirrors. Preparation before that
returns `physics::NO_BODY` and leaves cloth pending. A cloth with no listed
contact bodies has no native-world preparation dependency.

`cloth::prepare_subtree(&scene, &assets, root)` attempts every pending cloth
under a root, including the root. Omit root or pass null for the whole scene.
It returns the first fault and retains successful owners. Every failed owner
keeps its source Mesh and authoring and releases staged private geometry/state.
Repeated preparation of a prepared owner is a no-op.

`PhysicsWorld.update_cloths` skips pending owners without changing their source
Mesh or authoring, and reports their count in `cloth_stats.pending`. Normal
prepared-cloth timing and update order are unchanged. `Scene.add_cloth` remains
the combined attachment-and-preparation entry; its failure removes the partial
authoring too. `Scene.remove_cloth` also removes pending authoring and restores the captured
source geometry and original vertex-motion setting.

## Collisions

```c3
ClothDesc desc = cloth::default_cloth_desc();
desc.pins = cape_pins;
desc.colliders = bone_entities;
scene.add_cloth(&assets, cape_node, desc)!;
```

`ClothDesc.colliders` lists up to `MAX_CLOTH_COLLIDERS` (32) entities whose RigidBody is already
built. At attachment the cloth copies the ids and captures each body's SPHERE and CAPSULE
colliders from `RigidBody.colliders` as body-local segments and radii (a sphere is a zero-length
capsule; a capsule runs along its local Y over `±half_height`); other kinds are skipped. At most 32
shapes are captured in total, so a body with several shapes takes several slots. The cloth keeps
no pointer into physics storage. To change the list or a body's shapes, remove the cloth and
attach again; rebuilding a body with the same primitives keeps working.

Each update reads every listed body's final published node pose (translation and rotation; sphere
and capsule dimensions already ignore node scale) and interpolates from the pose of its last
solved substep with shortest-path rotation, so a capsule keeps its length while it turns. A first
observation, or one after the body was missing, uses the current pose on both sides. A dead
entity or a node without a RigidBody contributes nothing; a new entity in the same slot is never
bound. In each pass, after the constraints, free particles are pushed outside every shape expanded
by `thickness`; a particle on a segment's centreline leaves along a fixed perpendicular, one at a
sphere's centre along +Y. A zero-step update projects the publication against the current poses
and keeps the solved positions, velocities and body poses. Pins are never projected.

Contacts are one-way: cloth applies no impulse to bodies. Projection is discrete, so a fast
collider can tunnel through the sheet, and conflicting shapes or the ground can leave residual
penetration. Shapes follow the published bodies, not the rendered skin: a partially blended
ragdoll, IK or a skin wider than its capsules can show the mesh through the cloth; the example
raises the cape's thickness for that.

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

## Rebasing the origin

Cloth state is world-space, so `PhysicsWorld.shift_origin(&scene, offset)` subtracts the
offset from `positions`, `predicted`, `published`, the pin anchors and targets, the
collision shape endpoints and the sampled body poses. Velocities are unchanged.
Publication is node-local through the inverse of the node's world matrix, and the cloth
node is an ordinary parent node moved by `Scene.shift_origin`, so the published vertices
do not change. `ground_height` is a world height and is not shifted.

## Solver and publication

Per substep: wind accelerations from each triangle's area, unit normal and relative air velocity
(`Wind.velocity` minus the mean corner velocity, clamped to `max_speed` when it is positive), as
`drag * area * dot(relative, normal) * normal`, one third per corner; semi-implicit integration
of gravity and wind; damping `max(0, 1 - damping * dt)`; prediction; pins; then `iterations`
passes over edges, bends, the ground (free particles kept at `ground_height + thickness`) and
the collider shapes; velocities from the corrected displacement. A stiffness `s` is applied per pass as
`1 - (1 - s)^(1 / iterations)`, which normalizes one isolated constraint, not a coupled mesh. A
pair that collapses onto one point separates along its rest direction. `Wind.lift` is unused.

Particles have unit mass, so the wind's effect falls as a mesh gets finer; scale `Wind.drag` with
vertex density (the example uses `2.5 * vertices / area`) to keep a response.

Publication converts world positions through the inverse current node matrix into the private
geometry, recomputes normals and bounds, and calls `mark_geometry_dirty` once when any local
position changed; unchanged output keeps the revision. Solve and publication allocate nothing
after attachment (the CPU triangle tree rebuilds only when a query asks for it).
`PhysicsWorld.cloth_stats` holds the last update's solve and publication seconds, particle count
and constraint count, plus the number of pending owners skipped.

Geometry uploads whole on each revision: 47,264 bytes for the 33×33 benchmark flag (positions,
normals, UV and 16-bit indices, counted in `Stats.upload_bytes`). Each temporal view additionally
writes 12 bytes per vertex of previous positions through the frame ring, 13,068 bytes for that
flag, counted in `Stats.vertex_history_bytes`.

## Example and measurements

```text
python scripts/build.py --example cloth
addons/c3d_physics.c3l/build/cloth.exe [--scene flag|cape|both] [--still] [--frames 300]
c3c build cloth --path addons/c3d_physics.c3l -O3
addons/c3d_physics.c3l/build/cloth.exe --benchmark --scene flag|cape|both [--still] [--ragdoll]
addons/c3d_physics.c3l/build/cloth.exe --benchmark --trace software|hardware [--validation]
```

Run from `addons/c3d_physics.c3l`: the character model path is relative to it, and from `build/` the
cape scenes (`cape`, `both`) fault `ASSET_IO_ERROR`. The interactive scenes are a
24×16-cell flag with a pinned edge and gusting wind, a 12×22-cell cape (0.5 × 0.95 m, top row
pinned) parented to the `DEF-spine.003` joint of the walking quaternius character with all twelve
ragdoll bone capsules listed as colliders and the ground on, or both. The panel toggles the
ragdoll (bones go limp; turning it off freezes the pose and blends back to the walk over 0.8 s),
collider guides drawn at the published body poses, TAA and motion blur. The cape uses
`thickness` 0.02 m so the skin outside the bone capsules stays under it. `--still` keeps the same
meshes without attaching cloth.

The benchmark renders one scene (the flag at 32×32 cells) at the default 4×8 settings to a
1280×720 TAA and motion-blur view with 120 warm-up and 600 measured 60 Hz frames; `--ragdoll`
drops the character at the end of the warm-up. Vulkan validation is off unless `--validation` is
given; it inflates timings, so measure without it. The table below ran with validation on.
Windows, RTX 4090, C3 0.8.3 `-O3`, three runs each:

| Scene | Particles / constraints | Solve mean (p95), ms | Publication mean, ms | Geometry + history bytes per frame |
| --- | --- | --- | --- | --- |
| Flag 33×33 | 1,089 / 6,144 | 1.27-1.43 (1.47-2.17) | 0.012-0.013 | 47,264 + 13,068 |
| Cape 13×23, 12 capsules | 299 / 1,584 | 0.58-0.59 (0.76-0.82) | 0.011-0.012 | 12,880 + 3,588 |
| Both | 1,388 / 7,728 | 1.81-1.82 (2.05-2.15) | 0.022-0.023 | 60,144 + 16,656 |
| Cape during ragdoll, one run | 299 / 1,584 | 0.57 (0.76) | 0.011 | 12,880 + 3,588 |

The p95 frames took two physics steps. GPU frame medians, cloth on and `--still` interleaved per
scene, fall into two clusters set by the adapter's clock state, not by the cloth: 0.16-0.19 ms and
0.30-0.38 ms (flag on 0.169, 0.170, 0.336; off 0.161, 0.300, 0.319; cape on 0.186, 0.348, 0.378; off
0.335-0.349; both on 0.347-0.369; off 0.174, 0.315, 0.326). Within the lower cluster the flag
costs under 0.01 ms; the on/off difference is below the run-to-run variability. Serial solving
of both cloths stays under 2.2 ms per frame, so no parallel executor is proposed.

`--trace software|hardware` marks the flag and cape traceable, turns on ray-traced sun shadows and
prints, per frame as mean and maximum, `Stats.trace_build_ms`, the `TRACE_POSE` and
`ACCELERATION_BUILD` GPU pass times, `blas_builds`, `blas_updates`, `tlas_builds`,
`upload_bytes`, and the total trace work (`trace_work_ms`: CPU build plus the two GPU passes; its
maximum is the sum of the separate maxima). `hardware` creates the renderer with ray queries and
exits non-zero when the adapter lacks them. Without `--trace` the output is unchanged.

The manual Vulkan acceptance renders real cloth through the TAA velocity debug output, on forward
and deferred views: deformation velocity of a free-falling sheet under a still node matches the
CPU projection within 2e-3 UV; fully pinned sheets move with their node in the same frame while
free particles keep zero velocity and stay drawn; two views of different cadence each measure
motion since their own last rendering; a re-attached cloth and the rendering after an aborted
frame carry zero motion. On Windows, copy `SDL3.dll` and `shaderc_shared.dll` from
`examples/build` into `build/cloth_acceptance` first:

```text
c3c test cloth_acceptance --path addons/c3d_physics.c3l/test/gpu
```

The secondary WSL llvmpipe correctness run is unrun for this change.

No self-collision, collision against the rendered skin, box, hull, mesh, height-field or compound
contacts, continuous collision, tearing, soft pins, dihedral bending, skinned base pose, tangents,
GPU or crowd simulation, or simulation-origin rebasing. Parallel solving waits for a measured
consumer need.
