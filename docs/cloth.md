# Cloth

`c3d::physics::cloth`, in the physics add-on, simulates a triangle mesh with position-based
dynamics: unit-mass particles, one distance constraint per unique triangle edge, one bend
distance per edge shared by exactly two triangles, gravity, node `Wind` drag, damping, hard pins,
an optional ground plane and one-way particle contacts with every collider kind of listed
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
their binding metadata are copied (see [Collisions](#collisions)).

| Fault | Cause |
| --- | --- |
| `NO_MESH` | The node has no Mesh. |
| `CLOTH_EXISTS` | The node already carries a Cloth. |
| `c3d::INVALID_ID` | The Mesh geometry or a listed collider entity is dead. |
| `physics::SOURCE_UNAVAILABLE` | The source's CPU positions were released. |
| `physics::NO_BODY` | A listed collider node has no built RigidBody. |
| `c3d::UNSUPPORTED` | SkinBinding, morph weights or targets, joints, custom data, a bounds override, or a non-indexed or non-triangle topology. |
| `c3d::INVALID_ARGUMENT` | Zero substeps, iterations or contact capacities, non-positive or non-finite contact tolerance, a stiffness outside `[0, 1]`, negative or non-finite damping or thickness, non-finite gravity scale or ground height, a pin or index out of range, non-finite positions, a degenerate triangle, an edge shared by more than two triangles, or a collider listed twice. |
| `c3d::CAPACITY_EXCEEDED` | More than 32 listed collider owners, binding metadata exceeding `max_shapes`, a full geometry pool, state-size overflow, or a state block that cannot be allocated. |
| `cloth::CONTACT_PRECISION_EXCEEDED` | A captured native shape bound cannot be represented conservatively. |

Every fault leaves the Mesh, the component store and the asset counts as they were. Defaults: 4
substeps, 8 iterations, stretch stiffness 1, bend stiffness 0.5, damping 0.5 per second,
thickness 0.01 m, gravity scale 1, no pins, no ground, no colliders.
`default_cloth_desc()` also installs the [collision defaults](#collisions).

`Scene.remove_cloth` restores the source geometry and the previous `vertex_motion`, then removes
the component, whose hook removes the private geometry and frees runtime and authoring storage. Removing the
node runs the same hook. The state outlives `destroy_physics_world`; destroy the scene before the
asset store. While attached, do not replace or remove the Mesh, release the private geometry's CPU
streams, change its topology, remove the source asset, or write the library-owned `ClothState`.
To change pins, settings or the source, remove and attach again.

Use two-sided materials without tangent-space normal maps or vertex displacement; the copy
carries no tangents and recomputed normals follow the simulated surface. `Mesh.trace` is the
application's choice. A traced cloth takes a vertex-motion posed slot: each simulation revision copies
positions and normals into the slot and refits the trace data instead of rebuilding it, and the top level still
rebuilds every revision. See `docs/scene_trace.md`, "Vertex-motion slots".

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
world-space triangle constraints and native body readiness are validated during
preparation, after node world matrices are current. Preparation reserves the configured
contact buffers but has no `PhysicsWorld` argument. Actual compound leaves are resolved
and counted during the first update and again when bindings change; preparation success
does not guarantee that those leaves fit `max_shapes`.

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

`ClothDesc.colliders` lists up to `MAX_CLOTH_COLLIDERS` (32) entity identities. Their
`RigidBody` mirrors must exist before preparation. Contacts support SPHERE, CAPSULE,
BOX, HULL, MESH, HEIGHT_FIELD and COMPOUND. Boxes and hulls are closed solids;
mesh and heightfield triangles are two-sided surfaces, with heightfield holes empty.
A compound is the union of its transformed children. Ground remains the optional
plane at `ground_height`.

External contact samples cloth particles only, using `thickness` as the separation
offset. A small collider can pass through an unsampled part of a large cloth face
without touching a particle. Success does not guarantee full cloth-triangle/body
nonintersection. Contacts are discrete and one-way: fast motion can tunnel, and cloth
applies no impulse to bodies. Shapes follow final scene body poses, not rendered skin.

The private physics adapter checks entity, native world/body and cooked-snapshot
generations during each owner-thread update. Missing owners or bodies contribute
nothing; a reused entity slot never binds. Native replacement refreshes bounded
binding metadata. Snapshot data is borrowed only inside the update, and no raw native
pointer survives it. Meshes are enumerated through a containing native query, then filtered
against the local particle bounds before consuming candidate capacity. Heightfield queries
use conservatively expanded cell ranges. Neither path copies the whole cooked asset into
each cloth; compound children use their owning compound's accessors.

Shapes use rigid physics' baked dimensions and local transforms. Native getters supply
the actual baked hull geometry and mesh scale. The final scene body's translation and
rotation place them; body node scale is not applied again. The existing native shape
domain requires positive heightfield scale and nonzero mesh scale; mirrored mesh scale
is supported. Cloth adds no separate scaling convention.

Each solved substep interpolates from the body's last solved pose to its final scene
pose using shortest-path rotation. First observations and replaced or previously missing
bodies use the current pose on both sides. A zero-step update checks the publication
against current poses without advancing solved positions, velocities or body poses.
Pinned particles are never projected against bodies or ground. Their overlaps are
excluded from separation enforcement and reported in `pinned_overlaps`.

`ClothDesc.collisions` holds a `ClothCollisionDesc`. `default_cloth_collision_desc()`
and `default_cloth_desc()` provide these values:

| Field | Default | Meaning |
| --- | ---: | --- |
| `contact_tolerance` | 0.0001 m | Maximum accepted separation deficit after float publication. |
| `contact_iterations` | 8 | Final contact passes per substep or publication. |
| `max_shapes` | 128 | Flattened collider leaves across the listed owners. |
| `max_candidates` | 8192 | Candidate pairs retained in one pass. |
| `max_contacts` | 4096 | Active contact records retained in one pass. |

Tolerance must be finite and positive; iterations and capacities must be nonzero.
Preparation sizes staging and contact buffers with checked arithmetic. Updates allocate
nothing and never grow or truncate these buffers. Change settings or the owner list by
removing and attaching the cloth again. The default capacities are finite limits, not
a guarantee that arbitrary collider sets fit.

Each structural pass is followed by a contact pass. Up to `contact_iterations` final
passes then resolve ground and body contacts together and check the complete residual.
Successful publication leaves every participating free particle at separation at least
`thickness - contact_tolerance`. Unresolved competing constraints fail the cloth update.

## Arithmetic and update failures

Consumers using cloth must compile with `--fp-math=strict`, or `"fp-math": "strict"`
in their project settings. The update's owner thread must use round-to-nearest and
gradual underflow. Runtime checks detect unsupported arithmetic conditions but do not
prove the compiler's floating-point mode. Cloth never changes thread or process modes.

Every prepared cloth exposes its read-only last-attempt result as
`cloth.state.contact_result`. `failure` is zero on success; `stage` identifies failure
in ARITHMETIC, BINDINGS, CANDIDATES, CONTACTS, RESOLVE, PUBLICATION or REEXPRESSION,
and is NONE on success. `candidates` and `contacts` count observed work;
`peak_candidates` and `peak_contacts` report the largest retained sets. `max_residual`
and `unresolved` describe the last checked participating constraints, and
`pinned_overlaps` counts excluded pin overlaps. A failed attempt does not report
unvisited work as checked.

| Fault | Meaning |
| --- | --- |
| `c3d::CAPACITY_EXCEEDED` | Binding, candidate or contact storage is full; `stage` identifies the buffer. |
| `cloth::CONTACT_UNRESOLVED` | The bounded contact passes could not satisfy all participating constraints. |
| `cloth::CONTACT_PRECISION_EXCEEDED` | Arithmetic, correction or float publication cannot establish the configured tolerance. |

An update stages all performed substeps, velocities, pin/body observations and publication
before committing. On failure it keeps the last committed simulation and histories,
updates diagnostics and continues other cloths. It does not replay failed elapsed steps
through another accumulator; the next normal update retries current inputs from committed
cloth state.

With an unchanged cloth-node transform, failure preserves geometry bytes and revision.
After a node or parent moves, cloth re-expresses its committed world publication in the
new local frame only if the inverse and local float positions are finite and their world
round trip differs by at most `contact_tolerance`. The complete replacement geometry is
checked before publication; only a changed local representation advances its revision.

If re-expression is unsupported, the result is `CONTACT_PRECISION_EXCEEDED` at
REEXPRESSION. Committed world-space simulation and histories, old local geometry bytes
and revision remain unchanged. The application-owned transform is not rolled back, so
the old local geometry may render elsewhere. Restoring a supported transform lets later
updates retry. World-surface preservation is not guaranteed under an unrepresentable
transform.

With `C3D_PHYSICS_SERIAL`, the authoring codec stores these five collision fields along
with the existing cloth settings, requested pins and collider references. It writes
version 2. Version-1 JSONC receives the current collision defaults; version-1 binary
is `c3d::UNSUPPORTED`. Restored cloth remains pending. Runtime contacts, diagnostics,
native identities, buffers and histories are never serialized.

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
positions with pins at the current anchors (contact correction touches that publication only), so
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
passes over edges, bends, the ground with its thickness offset, and
the collider shapes, followed by bounded final contact resolution; velocities from the corrected
displacement. A stiffness `s` is applied per pass as
`1 - (1 - s)^(1 / iterations)`, which normalizes one isolated constraint, not a coupled mesh. A
pair that collapses onto one point separates along its rest direction. `Wind.lift` is unused.

Particles have unit mass, so the wind's effect falls as a mesh gets finer; scale `Wind.drag` with
vertex density (the example uses `2.5 * vertices / area`) to keep a response.

Publication converts world positions through the inverse current node matrix into the private
geometry, recomputes normals and bounds, and marks the position and normal streams dirty once when
any local position changed; unchanged output keeps the revision. Publication checks reconstructed
world positions and contact separation before writing any stream. Solve and publication allocate nothing
after preparation (the CPU triangle tree rebuilds only when a query asks for it).
`PhysicsWorld.cloth_stats` holds the last update's solve and publication seconds, particle count
and constraint count, pending owners skipped, failed cloth count, observed candidate/contact
counts and maximum reported residual.

Each revision uploads the position and normal streams only, 24 bytes per vertex: 26,136 bytes for the
33×33 benchmark flag (counted in `Stats.upload_bytes`; see [Publishing geometry
edits](post.md#publishing-geometry-edits)). A whole-block upload of the same flag is 47,264 bytes
(positions, normals, UV and 16-bit indices). Each temporal view additionally
writes 12 bytes per vertex of previous positions through the frame ring, 13,068 bytes for that
flag, counted in `Stats.vertex_history_bytes`.

## Example

```text
python scripts/build.py --example cloth
addons/c3d_physics.c3l/build/cloth.exe [--scene flag|cape|both|contacts] [--still] [--frames 300]
c3c build cloth --path addons/c3d_physics.c3l -O3
addons/c3d_physics.c3l/build/cloth.exe --benchmark --scene flag|cape|both|contacts [--still] [--ragdoll] [--publish whole|streams]
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
meshes without attaching cloth. The panel shows `Stats.upload_bytes`; its whole-upload switch and the
`U` key (`--publish whole` at start) mark each published cloth with `mark_geometry_dirty` on top of the
library's stream mark, so the renderer uploads the whole block. The picture is identical in both modes.

The `contacts` scene places six pinned 5x5 sheets over a transformed box, a non-box convex
hull, a sloped mesh, a heightfield ramp with a hole, and a compound with differently transformed
box and mesh children. It uses the default discrete contact settings. The panel reports candidate
and active-contact work, failed cloths and the maximum contact deficit.

The benchmark renders one scene (the flag at 32x32 cells) at the default 4x8 settings to a
1280x720 TAA and motion-blur view with 120 warm-up and 600 measured 60 Hz frames; `--ragdoll`
drops the character at the end of the warm-up in a cape scene. `--validation` enables Vulkan
validation. Timings printed by a validation run include its overhead. `--capture path.rgba`
saves the final 1280x720 RGBA8 frame. Measurements depend on the selected scene, compiler,
hardware and validation settings.

`--trace software|hardware` marks the scene cloths and contact-demo obstacles traceable, turns on ray-traced sun shadows and
prints, per frame as mean and maximum, `Stats.trace_build_ms`, the `TRACE_POSE` and
`ACCELERATION_BUILD` GPU pass times, `blas_builds`, `blas_updates`, `tlas_builds`,
`upload_bytes`, and the total trace work (`trace_work_ms`: CPU build plus the two GPU passes; its
maximum is the sum of the separate maxima). `hardware` creates the renderer with ray queries and
exits non-zero when the adapter lacks them. Without `--trace` the output is unchanged.

The manual Vulkan target exercises publication and per-view vertex motion through forward and
deferred views. On Windows, copy the pinned `shaderc_shared.dll` beside the target executable
when running the target directly:

```text
c3c test cloth_acceptance --path addons/c3d_physics.c3l/test/gpu
```

No self-collision, full cloth-feature/body-feature contact, collision against the rendered skin,
continuous collision, tearing, soft pins, dihedral bending, skinned base pose, tangents,
GPU or crowd simulation. Parallel solving waits for a measured
consumer need.
