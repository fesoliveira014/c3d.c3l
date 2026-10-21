# Cloth

`c3d::physics::cloth`, in the [physics add-on](physics.md), simulates a triangle mesh with position-based dynamics. A
cloth owns a private copy of the mesh geometry, simulates it in world space, collides it with the colliders of listed
rigid bodies and publishes the result back to the geometry every frame. It handles pins and soft attachments, distance
or dihedral bending, wind, self-contact, continuous contact, skinned and crowd meshes, tearing, and resting.

It imports the standard library, core and `c3d::physics`, and creates no GPU resources: it writes editable geometry
and [vertex motion history](post.md#edited-vertices), and the renderer uploads the changed ranges. Parameters, faults
and diagnostics are in the [cloth reference](cloth_reference.md).

## Quick start

A flag whose top row is pinned. Inside a fallible function, with the physics world and `register_physics` in place and
`pinned_vertices` a slice of source vertex indices:

```c3
ClothDesc desc = cloth::default_cloth_desc();
desc.pins = pinned_vertices;
scene.add_cloth(&assets, flag_node, desc)!;
scene.add(flag_node, (Wind){ .velocity = { 6, 0, 2 } });

while (running) {
    anim::update(&assets, &scene, delta);
    scene.update_world();
    world.update(delta);
    scene.update_world();
    world.update_cloths();
    render_views();
}
```

`flag_node` carries a `Mesh` and has a current, invertible world matrix. `anim::update`, `render_views` and the wind
velocity are the application's. The `cloth` example builds this scene; run it with
`python3 scripts/build.py --example cloth`.

## Concepts

- **Owned copy.** `Scene.add_cloth` copies the node's mesh into a private geometry asset (positions, indices, UV and
  color streams, computed normals and, with `tangent_frame`, tangents), points `Mesh.geometry` at the copy and enables
  `Mesh.vertex_motion`. The source geometry is never written, and two cloths on one source own separate copies.
- **Physical and render particles.** Without `render_particles`, each source vertex is one physical particle. With it,
  several render vertices (for example across a UV seam) map to one particle, and the simulation moves particles while
  the mesh keeps its render vertices.
- **Constraints.** One distance constraint per unique physical triangle edge, plus bending across interior edges.
  Hard pins and soft attachments hold particles to the node's pose. Particles are free and live in world space: moving
  the parent node does not drag them.
- **Areal mass.** A particle's mass comes from `ClothDesc.density` and the area of its adjacent triangles, so total
  mass does not depend on tessellation ([mass and wind](#mass-and-wind)).
- **Pending and prepared.** `scene.attach_cloth` stores authoring only. `Scene.add_cloth` attaches and prepares in
  one call. A prepared cloth has its private geometry and simulation state ([pending authoring](#pending-authoring)).
- **Fixed-step update.** `update_cloths` consumes the fixed steps of the physics update that just ran, as `substeps`
  substeps of `fixed_dt / substeps` each. Per substep the solver applies wind and gravity, damps and predicts, projects
  hard pins, then runs `iterations` passes over soft attachments, edges, bends, the ground and the colliders, then
  resolves final contacts. A stiffness `s` applies per pass as `1 - (1 - s)^(1 / iterations)`, which normalizes one
  isolated constraint and not a coupled mesh. For a given mesh, descriptor and update sequence the results are
  deterministic.
- **Arithmetic mode.** Cloth consumers compile with `--fp-math=strict` (or `"fp-math": "strict"` in project settings).
  The update's owner thread, and every thread that stages cloth through `set_parallel`, uses round-to-nearest and
  gradual underflow. Runtime checks detect unsupported conditions but cannot prove the compiler's mode; cloth never
  changes thread or process modes.

### Frame order

```text
animation -> scene.update_world -> physics.update
          -> final ragdoll/IK poses -> scene.update_world
          -> physics.update_cloths -> render every view
```

Call `PhysicsWorld.update_cloths` once after each `PhysicsWorld.update`; its contract checks that the update serial
advanced. Do not change the scene or assets between it and recording the frame's views. It reads `fixed_dt` and
`gravity` from the world tuning, so leave them unchanged between the two calls, and it replays the performed fixed steps
only (a dropped backlog is not replayed).

Pins follow the node's final world pose. Each pin keeps the world anchor of its last solved substep and moves to the
current anchor across the update's substeps, landing on it exactly on the last one. A zero-step update integrates
nothing and keeps the solved anchors; it publishes the solved positions with pins at the current anchors, so
attachment holds without inventing elapsed time.

## Attach and remove

`add_cloth` validates the description, builds the constraints from the current world positions and replaces the mesh
geometry with the copy. It copies pins, attachments, seams and collider ids. Every fault leaves the mesh, the component
store and the asset counts as they were ([attach faults](cloth_reference.md#attach-faults)). The source needs its CPU
positions. Morph targets, custom vertex data, a bounds override, membership of an LOD group and non-indexed or
non-triangle topology are `c3d::UNSUPPORTED`.

`Scene.remove_cloth(node)` restores the source geometry and the previous `vertex_motion`, then removes the component;
its hook removes the private geometry and frees the state. Removing the node runs the same hook. While a cloth is
attached, do not replace or remove the mesh, release the private geometry's CPU streams, change its topology, remove
the source asset or write the library-owned `ClothState`. To change pins, attachments, settings or the source, remove
the cloth and attach it again. The state outlives `destroy_physics_world`; destroy the scene before the asset store.

### Pending authoring

`scene.attach_cloth(&assets, node, desc)` validates and attaches authoring without creating geometry or state.
`Cloth.authoring` holds the source identity, the original `vertex_motion` flag, the complete descriptor and copies of
the requested pins, seams and collider ids. Until `Cloth.is_prepared()` is true, the mesh stays untouched and draws the
authored source. `cloth::prepare(&scene, &assets, node, &world)` prepares one cloth after node world matrices are
current; `cloth::prepare_subtree(&scene, &assets, root, &world)` prepares every pending `Cloth` and `CrowdCloth` under
`root` (the whole scene when `root` is omitted), returns the first fault and keeps the owners that succeeded. A failed
owner keeps its source mesh and authoring and releases staged state. Preparing a prepared cloth does nothing.

Skinned cloth and `CrowdCloth` need a non-null `PhysicsWorld*` with `world.scene == &scene` and
`world.assets == &assets`. For listed contact bodies, run an ordinary physics update first so their bodies exist;
preparation before that returns `physics::NO_BODY` and leaves the cloth pending. `update_cloths` skips pending cloth and
counts it in `ClothStats.pending`. The shared [owner readiness](owner_readiness.md) table records the preparation order
and pending draw behavior.

## Pins and attachments

`ClothDesc.pins` lists source vertex indices held at their node-relative position. They map through `render_particles`
to hard pins with zero inverse mass. For softer anchoring, `ClothDesc.attachments` lists
`ClothAttachment { particle, weight, compliance }` records on physical particles:

| Fields | Meaning |
| --- | --- |
| `weight` in [0, 1] | Zero ignores the entry. |
| `compliance == 0`, `weight > 0` | Hard pin. |
| `compliance > 0`, `weight > 0` | Soft XPBD attachment toward the interpolated anchor each substep, with effective compliance `compliance / weight`. The particle keeps its areal mass. |

Duplicate entries on one particle must agree on hard versus soft and on the effective compliance.

## Bending

`ClothBendMode.DISTANCE` (the default) keeps opposite vertices of interior edges near their rest distance, scaled by
`bend_stiffness`. It requires `bend_compliance == 0` and empty `rest_angles`. `ClothBendMode.DIHEDRAL` replaces it with
an analytic signed dihedral hinge constraint across each interior physical edge, projected each substep with XPBD
compliance `bend_compliance`. `ClothDesc.rest_angles` overrides the rest angle on canonical interior edges
(`first < second`, `angle` in `(-pi, pi]`). A substep turns a hinge at most 1.25 rad away from its tracked angle, so a
hinge far from rest recovers over several substeps without changing the compliant equilibrium. The solver checks each
substep against edge collapse, triangle degeneracy and a half turn or more, and fails with `cloth::BEND_UNRESOLVED`.

## Normals and tangents

Render vertices that share a physical particle and an authored unit normal (within `1e-6`) share a normal domain, so UV
seams stay smooth while hard creases stay split. Publication recomputes normals from the deformed triangles.

With `tangent_frame = true`, `tangent_uv_set` (0 for `uv0`, 1 for `uv1`) selects a populated finite UV stream. Preparation
generates tangent domains and handedness signs (`w = +-1`), and each publication recomputes angle-weighted orthonormal
tangents from the deformed triangles. Degenerate UV triangles fall back deterministically, and a frame that cannot
produce a finite unit vector fails with `cloth::FRAME_UNRESOLVED`. `render_particles` must have the source vertex
count, map onto the dense range `0..particle_count - 1` (`particle_count >= 3`) with every particle referenced by a
triangle, and map render vertices that share a particle to identical rest positions.

`Mesh.trace` is the application's choice. A traced cloth takes a vertex-motion posed slot: each simulation revision
copies positions and normals into the slot and refits the trace data, while the top level still rebuilds every revision.
See [scene trace](scene_trace.md).

## Collide with bodies

```c3
ClothDesc desc = cloth::default_cloth_desc();
desc.pins = cape_pins;
desc.colliders = bone_entities;
scene.add_cloth(&assets, cape_node, desc)!;
```

`ClothDesc.colliders` lists up to `MAX_CLOTH_COLLIDERS` (32) entities with a built `RigidBody`. Contacts support
`SPHERE`, `CAPSULE`, `BOX`, `HULL`, `MESH`, `HEIGHT_FIELD` and `COMPOUND` colliders. Boxes and hulls are closed solids;
mesh and height-field triangles are two-sided surfaces, with height-field holes empty. A compound is the union of its
transformed children. The optional ground is the plane at `ground_height` (`collide_ground`).

![Pinned cloth sheets over box, hull, mesh, heightfield and compound colliders](images/cloth_contacts.png)

- Contact samples cloth particles only, using `thickness` as the separation offset. A small collider can pass through an
  unsampled part of a large face without touching a particle, and success does not guarantee that no cloth triangle
  intersects a body.
- Contacts are one-way: cloth applies no impulse to bodies.
- Shapes follow final scene body poses, not rendered skin. They use the physics package's baked dimensions and local
  transforms; the body node's scale is not applied again.
- Each solved substep interpolates from the body's last solved pose to its final scene pose along the shortest
  rotation.
- Pinned particles are never projected against bodies or the ground. Their overlaps are excluded from separation
  enforcement and counted in `pinned_overlaps`.
- A missing owner or body contributes nothing, and a reused entity slot never binds. Compound leaves are counted at the
  first update and again when bindings change, so a successful preparation does not guarantee that the leaves fit
  `max_shapes`.
- Preparation sizes the contact buffers and updates allocate nothing. The default capacities
  ([collision settings](cloth_reference.md#collision-settings)) are finite limits, not a guarantee that any collider set
  fits. Change settings or the owner list by removing and attaching the cloth again.

After a structural pass, up to `contact_iterations` final passes resolve ground, body and enabled self contacts together
and check the complete residual. A successful publication leaves every free particle at an external separation of at
least `thickness - contact_tolerance`, except a particle still carrying a contact deeper than its push bound.
Unresolved competing constraints fail the cloth update.

### Bounded contact push

A particle's contact displacement is bounded to a quarter of the shortest rest edge incident to it, separately for a
substep's structural passes, its final contact passes and each publication, and accumulated as a net vector so opposing
contacts do not use it up. A contact deeper than the bound clears over several substeps: the simulated particle trails
the contact, the publication projects the output at most one bound further, and `unresolved` and `max_residual` report
the remaining depth while the update succeeds. A particle whose push reached its bound is carried, and the final and
publication checks skip its contacts. An unresolved contact on a particle with push available fails with
`cloth::CONTACT_UNRESOLVED`.

Contact is therefore soft against constraints that pull a particle back by more than the bound each substep: a taut
pinned cloth cut by a surface it cannot clear stays partly inside it. Skinned cloth and `CrowdCloth` publish during
preparation, so they first resolve a starting penetration in up to 64 rounds of fresh push bounds and then recompute
each hinge's tracked angle; a penetration that outlasts the rounds fails preparation with `CONTACT_UNRESOLVED`.
Ordinary cloth prepares without a world, publishes nothing at preparation and clears a starting penetration over its
first updates.

### Teleports

`PhysicsWorld.teleport` resets the affected body's observations in referencing cloths after writing the pose. After
moving a listed collider directly through scene transforms, call `cloth::reset_contact_history(&cloth)`. Reset and body
replacement use current poses on both sides of the discontinuity and endpoint contacts still apply; reset does not
move the fabric or change its velocity. Ordinary pose edits without reset remain continuous motion.

## Self-contact and seams

```c3
ClothSeam[2] seams = { { .first = 4, .second = 12 }, { .first = 5, .second = 13 } };
ClothDesc desc = cloth::default_cloth_desc();
desc.collisions.self_collision = true;
desc.seams = seams[..];
scene.add_cloth(&assets, node, desc)!;
```

`self_collision` checks vertices against source faces and disjoint source-edge pairs within one cloth. A successful
publication has an unsigned closest separation of at least `2 * thickness - contact_tolerance` for each eligible pair.
Different `Cloth` components do not collide with each other.

![Folded cloth with explicit seam pairs and self-contact enabled](images/cloth_self.png)

`ClothDesc.seams` copies pairs of source vertex indices. Preparation takes their transitive equivalence; duplicate and
identity pairs are harmless. A vertex-face pair is excluded when the vertex is equivalent to a face corner or shares a
source edge with one after the equivalence, and an edge pair is excluded when any endpoint pair is equivalent or shares
such an edge. Exclusion covers incidence and one edge ring, not a whole connected component. Coincident positions
never create equivalence, and seams add no mechanical constraint: they change collision exclusions only.

Self and external contacts share `max_candidates` and `max_contacts`, so dense folds can exceed those limits. Pins have
zero response weight and stay exact: a movable feature separates from fixed ones, and a conflicting fully pinned
eligible pair fails with `CONTACT_UNRESOLVED`. A collapsed feature with no usable axis fails with
`CONTACT_PRECISION_EXCEEDED`. Raising `contact_iterations` allows more work without promising convergence for every
fold.

## Continuous contact

```c3
ClothDesc desc = cloth::default_cloth_desc();
desc.collisions.continuous = true;
desc.collisions.self_collision = true;
scene.add_cloth(&assets, node, desc)!;
```

Discrete contact is the default. `continuous` sweeps each proposed movement against the contacts: velocity prediction
with pins, each edge and bend correction batch and every contact correction. Moving bodies use linear translation and
shortest-path rotation between the final scene poses of successive updates, which cannot recover motion omitted from
those poses.

![Cloth after the fast rotating-box crossing](images/cloth_continuous.png)

`max_ccd_iterations` (default 64) bounds the distance advances per candidate path. Exhaustion or a stalled advance
reports `cloth::CONTACT_NONCONVERGENT`; an unresolved initial overlap or competing constraints can report
`CONTACT_UNRESOLVED`; numerical uncertainty reports `CONTACT_PRECISION_EXCEEDED`. A failed path is never accepted as a
miss, and contact capacity also bounds composed responses. Neither convergence nor capacity is guaranteed for arbitrary
motion or topology. A zero-step update sweeps from the last published positions and body observations to the proposed
publication and leaves solved positions, velocities and anchors intact. An unsampled cloth face can still pass through
a small collider.

## Skinned and crowd cloth

A mesh node with a valid `SkinBinding` is a skinned cloth owner. While pending, it keeps both `Mesh` and `SkinBinding`.
Preparing it (`scene.add_cloth(&assets, node, desc, &world)` or `cloth::prepare`) moves the rendered mesh to an owned
unskinned child node carrying a transient `ClothOutput` marker, and leaves `SkinBinding` on the owner so skeletal
animation continues. The cloth reads the skinned reference positions each update.

`ClothDesc.transport` supplies an optional per-particle weight in [0, 1], indexed by physical particle. During each
fixed step, free particles receive `transport[p] * (current_ref[p] - solved_ref[p])` before gravity and constraint
projection, so skeletal motion carries the cloth without double counting on zero-step frames.

For an `AnimatedCrowd` owner, `scene.attach_crowd_cloth(&assets, crowd_node, part, desc)` attaches a `CrowdCloth` recipe
for a rigid or skinned crowd mesh part (its `sway` and `fade` must be disabled) and
`cloth::prepare_crowd_cloth(&world, &assets, crowd_node, part)` hides the part's `InstancedMesh` batch and creates one
unskinned `ClothOutput` child per placement slot. Active slots (`slot < crowd.count`) are simulated and published in
owner-local space with vertex colors equal to the source colors (or white) times `crowd.colors[slot]`. Inactive slots
are hidden, and a slot generation change reseeds the slot and advances `Mesh.vertex_history_token`.

Remove skinned and crowd cloth only with `Scene.remove_cloth` and `Scene.remove_crowd_cloth`. They restore the source
mesh or hidden batch, increment `Mesh.vertex_history_token` (which invalidates correspondence-based motion blur and
trace caches) and delete the generated `ClothOutput` children. `scene.remove_component` releases private state without
undoing the takeover, and `scene.remove(owner)` removes the children with the owner.

## Tear

`ClothDesc.cuts` lists authored `ClothCutPath { id, vertices, strain_trigger, strain_threshold }` chains over physical
particle ids: `id` is nonzero and unique across the cloth, `vertices.len >= 2`, and consecutive vertices are joined by
an interior physical edge. `ClothDesc.tears` (`ClothTearLimits`) sets `max_requests` (default 0, which means
`cuts.len`) and `opening_iterations` (default 32). Preparation reserves the split vertices and storage
for every path, so a runtime cut allocates nothing and never rewrites the triangle index buffer.

```c3
Cloth* flag_cloth = scene.get(flag_node, Cloth);
flag_cloth.request_cut(path_id)!;
ClothCutResult result = flag_cloth.cut_result(path_id)!;
```

`request_cut` queues a cut for the next performed substep; `crowd_cloth.request_cut(part, instance, id)` does the same for
one crowd placement. With `strain_trigger = true` and a positive `strain_threshold`, a path also triggers when an
intact interior edge along it satisfies `(length - rest_length) / rest_length >= strain_threshold`. Triggered and
requested paths run in ascending `id` order. The opening moves positions only: split particles keep their parent's
velocity, so a cut conserves momentum and adds no separation speed. Continuous self-contact between vertices of a torn
seam raises each movable vertex's response share to at least 0.25 so the coincident halves separate.

When `self_collision` is enabled, newly split seam pairs open through a centroid-conserving half-space solver, certified
over the affine `t in [0, 1]` trajectory (with a positive-thickness CCD resweep when `continuous` is enabled). Any
uncertified opening rolls back the whole cloth update with `cloth::OPENING_UNRESOLVED` and records
`ClothCutOutcome.REFUSED` in `cut_result`. A refused strain-triggered path latches so later updates do not retrigger it;
an explicit `request_cut` retries.

## Rest and hold

A cloth is `AWAKE`, `RESTING` or `HELD` (`ClothActivity`). `Cloth.activity()` reports it and
`CrowdCloth.slot_activity(slot)` reports a crowd slot, which rests when every prepared part of the slot rests.

**Resting.** `sleep_speed` (m/s, default 0, which never rests) and `sleep_steps` (default 30) set the rule. After each
update that performed steps, if no particle with a nonzero inverse mass moves at `sleep_speed` or faster, the update's
steps join a run; otherwise the run resets. The cloth rests when the run reaches `sleep_steps`; zero-step updates
neither count nor reset it. Resting zeroes the velocities and records the owner's `Wind`, the world gravity and the
pose of every listed collider. A resting cloth still samples its reference and colliders each update and wakes when:

- a particle's reference moved from its last solved position by more than `sleep_speed * fixed_dt` (rigid and skinned
  owners, pins, attachments and transport);
- a listed collider moved by more than that distance while its shape bounds overlap the cloth's bounds grown by
  `thickness + contact_tolerance` (a rotation counts as moving the shape's farthest bounding point);
- the owner's `Wind` appeared, was removed or changed its `velocity` or `max_speed`, or the world gravity changed;
- a listed body went live or dead, or had its contact history reset;
- a cut request is pending, or the application called `wake()`.

**Holding.** `Cloth.sleep()` and `CrowdCloth.sleep_slot(slot)` hold a cloth, awake or resting, from the next update and
zero its velocities. A held cloth ignores every trigger and keeps a cut request pending until `wake()` or
`wake_slot(slot)`. A hold set on a pending cloth applies when it prepares, and a hold on a crowd slot ends when the slot
gets a new instance. The library never holds a cloth on its own. A held cloth stays as published, so a held skinned
cloth stays frozen in its owner's frame while the skeleton animates: use holds for unseen cloth.

**Waking.** The first update after a wake carries the particles to where the reference went, zeroes velocities and sets
pin and attachment anchors to their targets. A cloth on a rigid owner moves rigidly by
`node.world * inverse(published_frame)`, which keeps every edge length under rotation. A skinned cloth and a crowd slot
move each particle by `current_reference - solved_reference`; a reference that rotated while held shears them. An
explicit `wake()` also resets the listed bodies' pose history, so a collider that moved while the cloth was held does
not sweep through it. A wake commits with the update that carried it: if that update fails, the cloth keeps its activity
and the request stays pending.

A resting or held cloth skips the solve and publication, so it marks no geometry dirty and the renderer sees no new
revision. A held cloth still mirrors the owner's layers, world matrix and visibility onto a skinned or crowd output
node. `ClothStats.resting` and `held` count them. Activity and holds are runtime state: a restored cloth is pending,
then awake.

## Update on a job pool

`PhysicsWorld.set_parallel(ParallelFor)` lets the application stage cloth on its own workers; the
[physics page](physics.md#update-on-a-worker-pool) shows the `c3d_job` adapter and the [job pool](jobs.md) describes
`ParallelFor`. A zero `ParallelFor` stages on the calling thread. `update_cloths` collects the prepared cloths and
active crowd slots serially in ECS order, stages each as one range item through `ParallelFor`, then commits serially in
that order: it copies the changed vertex ranges into the private geometry and marks them dirty, resets vertex histories,
writes output nodes, re-expresses a failed item's mesh and adds the item to `ClothStats`.

A staged item reads the scene, the asset store and the box3d shape data of its listed bodies, and writes only its own
`ClothState`. It allocates nothing and uses no temp allocator, so `run` may call `range` from any thread. While
`update_cloths` runs, the application must not mutate the scene, the asset store or the world, must not step the world
and must not call `set_parallel`. Worker threads use round-to-nearest and gradual underflow too; an item fails with
`CONTACT_PRECISION_EXCEEDED` when gradual underflow is off on its thread.

Positions, velocities and published geometry are bit-identical to the serial path for every worker count, and a failing
item does not stop the others. Parallelism is across cloths and crowd slots: one large cloth still solves on one thread.
`ClothStats.solve_seconds` sums the items' solve times (CPU time, which can exceed the frame), while `stage_seconds` and
`commit_seconds` are the wall times of the stage and commit phases. A crowd slot's state owns a joint palette scratch of
64 bytes per joint.

## Mass and wind

**Areal mass.** `ClothDesc.density` (kg/m², default 0.2) sets each particle's mass to
`density * (sum of the areas of its adjacent rest triangles) / 3`, measured on the world-scaled rest positions the edge
rest lengths use. The total mass is `density * area` at any tessellation, and a finer mesh has lighter particles. Hard
pins have zero inverse mass, and a vertex in no triangle keeps unit mass and moves under gravity alone. Soft
attachments and dihedral hinges are XPBD constraints in physical units, so their compliance acts against the real
particle mass: the same compliance reads stiffer on lighter particles, and a finer mesh has lighter particles. Scale a
tuned compliance by the change in inverse particle mass to keep its softness.

**Aerodynamics.** Cloth reads `Wind.velocity` and `Wind.max_speed` of the node's `Wind` component. `Wind.drag` and
`Wind.lift` apply to rigid bodies only; cloth uses `ClothDesc.drag_coefficient` (default 1.2) and `lift_coefficient`
(default 0.6), both dimensionless, and `cloth::AIR_DENSITY` (1.225 kg/m³). A node without a `Wind` gets no aerodynamic
force at all; a `Wind` with zero velocity gives still-air drag against the cloth's own motion. For each triangle with
area `A`, any unit normal `n`, relative velocity `v` (`Wind.velocity` minus the mean corner velocity, clamped to
`max_speed` when positive), `v_hat = v / |v|` and `s = dot(v_hat, n)`:

```text
F_drag = 0.5 * rho * C_d * A * |v|^2 * s * |s| * n
F_lift = rho * C_l * A * |v|^2 * s * (n - s * v_hat)
```

Both forms are unchanged when `n` flips to `-n`, so winding does not matter. With `alpha` the angle between the wind and
the plane, the lift has magnitude `0.5 * rho * C_l * A * |v|^2 * sin(2 * alpha)`: it vanishes along and across the wind
and acts toward the leeward side. Each corner takes a third of the force. A flat sheet in a wind that blows along its
plane feels no force: there is no skin friction. A triangle with zero relative speed gets no force.

**Tessellation.** Areal mass removes the mass and force part of the mismatch between tessellations only. Position-based
stiffness still depends on the resolution at a fixed iteration count, so a finer mesh sags a little more; more
iterations shrink the gap.

## Publication and failures

Publication converts world positions through the inverse current node matrix into the private geometry, recomputes
normals, optional tangents and bounds, and marks only the changed range of each stream dirty. Unchanged streams are not
marked and unchanged output keeps the geometry revision. Solve and publication allocate nothing after preparation. A
revision uploads only the changed vertex ranges (counted in `Stats.upload_bytes`; see
[publishing geometry edits](post.md#publishing-geometry-edits)): 24 bytes per vertex when every vertex changes, or 40
with `tangent_frame`. Each temporal view also writes 12 bytes per vertex of previous positions through the frame ring
(`Stats.vertex_history_bytes`).

An update stages all performed substeps, velocities, pin and body observations and publication before committing. On
failure it keeps the last committed simulation and histories, records the fault in `cloth.state.contact_result`
([diagnostics](cloth_reference.md#diagnostics)) and continues with the other cloths. It does not replay the failed
elapsed steps: the next normal update retries the current inputs from the committed state.

With an unchanged cloth-node transform, a failure preserves geometry bytes and revision. After a node or its parent
moves, cloth re-expresses its committed world publication in the new local frame only if the inverse and local float
positions are finite and their world round trip differs by at most `contact_tolerance`. Otherwise the result is
`CONTACT_PRECISION_EXCEEDED` at stage `REEXPRESSION`: committed simulation, old local geometry bytes and the revision
stay unchanged, but the application-owned transform is not rolled back, so the old local geometry may render elsewhere.
Restoring a supported transform lets later updates retry.

## Rebase the origin

Cloth state is world-space: `PhysicsWorld.shift_origin(&scene, offset)` subtracts the offset from every prepared cloth,
including its pins, anchors, collision shapes and body observations, and keeps activity and velocities. The cloth node
is an ordinary parent moved by `Scene.shift_origin`, so published vertices do not change. `ground_height` is a world
height and is not shifted. The full order is in [large worlds](large_world.md#origin-rebasing).

## Serialization

With `C3D_PHYSICS_SERIAL`, `Cloth` and `CrowdCloth` save their authoring (settings, pins, seams, collider references,
attachments, cuts and the rest) and restore pending, then awake. Runtime contacts, diagnostics, native identities,
velocities, buffers, cut state, histories, rest and hold state are not saved. Older payloads still load with the missing
fields at their defaults, and incompatible older binary layouts return `c3d::UNSUPPORTED` before anything is changed.
Stored fields and payload versions are in [serialization](serialization.md#cloth-adapter).

## Example

`python3 scripts/build.py --example cloth` runs `addons/c3d_physics.c3l/examples/cloth.c3`. Run it from
`addons/c3d_physics.c3l`: the character model path is relative to it. `--scene` selects one of:

| Scene | Shows |
| --- | --- |
| `flag` | A 24x16-cell flag with a pinned edge and gusting wind |
| `cape` | A cape parented to the walking character's spine, with compliant shoulder attachments, dihedral bending, tangent frames and the ragdoll's bone capsules as colliders |
| `both` | Flag and cape (default) |
| `contacts` | Pinned sheets over a box, hull, mesh, height field with a hole and compound |
| `fold` | A strip with two seam pairs and self-contact |
| `fast` | A thin box crossing a cloth patch in one step with continuous contact |
| `field` | Many small flags, some resting and some held (`--count`, `--hold`) |
| `crowd` | Walking characters wearing `CrowdCloth` capes (`--count`) |
| `densities` | The same flag at two tessellations, swinging together |

`--workers N` stages cloth on a `c3d_job` pool of N workers (the example selects `c3d_job`; the physics package does not),
`--still` keeps the meshes without attaching cloth, `--tear` cuts the flag or cape, and `--frames N` ends after N frames.
The panel shows the solver and upload statistics. An unknown or malformed flag prints the usage.

## Limits

- Cloth contacts are one-way and sample particles only; thin colliders can cross unsampled faces.
- Different `Cloth` components do not collide with each other.
- One cloth solves on one thread; parallel staging scales across cloths.
- Sources must be indexed triangle meshes without morph targets, custom vertex data or a bounds override, and outside
  LOD groups.
- A cloth needs `--fp-math=strict` and round-to-nearest, gradual-underflow arithmetic on every thread that updates it.
- A held skinned cloth does not follow its skeleton.

## See also

- [Cloth reference](cloth_reference.md)
- [Physics](physics.md), [ragdolls](ragdoll.md), [owner readiness](owner_readiness.md), [large worlds](large_world.md)
- [Serialization](serialization.md#cloth-adapter), [scene trace](scene_trace.md), [post](post.md#edited-vertices)
