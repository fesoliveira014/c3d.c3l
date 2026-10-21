# Cloth reference

Descriptor fields, defaults, faults and diagnostics of `c3d::physics::cloth`. The model, frame order and how-to
sections are in [cloth](cloth.md).

## Entry points

| Call | Purpose |
| --- | --- |
| `Scene.add_cloth(assets, node, desc, world = null)` | Attach and prepare. A fault removes the partial authoring. |
| `Scene.attach_cloth(assets, node, desc)` | Attach authoring only. |
| `cloth::prepare(scene, assets, node, world = null)` | Prepare one pending cloth. |
| `cloth::prepare_subtree(scene, assets, root = null, world = null)` | Prepare every pending `Cloth` and `CrowdCloth` under `root`. |
| `Scene.remove_cloth(node)` | Restore the source mesh and remove the component. |
| `Scene.attach_crowd_cloth(assets, owner, part, desc = default_cloth_desc())` | Attach crowd cloth to one logical part. |
| `cloth::prepare_crowd_cloth(world, assets, owner, part = uint::max)` | Prepare one part, or every pending part. |
| `Scene.remove_crowd_cloth(owner, part = uint::max)` | Restore the part batches. |
| `PhysicsWorld.update_cloths()` | Solve and publish every prepared cloth once per physics update. |
| `Cloth.is_prepared()`, `CrowdCloth.is_prepared()` | Whether private geometry and state exist. |
| `Cloth.request_cut(path)`, `Cloth.cut_result(path)` | Queue a cut; read its last result. |
| `CrowdCloth.request_cut(part, instance, path)`, `CrowdCloth.cut_result(part, instance, path)` | The same for one crowd placement; `instance` is a `CrowdInstanceId`. |
| `Cloth.sleep()`, `Cloth.wake()`, `Cloth.activity()` | Hold, wake and read the activity. |
| `CrowdCloth.sleep_slot(slot)`, `wake_slot(slot)`, `slot_activity(slot)` | The same for one crowd slot. |
| `cloth::reset_contact_history(&cloth)` | Reset collider observations after a direct collider teleport. |
| `cloth::pins_from_colors(allocator, &geometry, threshold = 0.5)` | Pin the vertices whose red channel is at least `threshold`; the caller frees the result. |

## ClothDesc

`default_cloth_desc()` fills the defaults. Every numeric field must be finite.

| Field | Default | Meaning and constraints |
| --- | --- | --- |
| `substeps` | 4 | Substeps per performed physics step. Nonzero. Solve cost grows linearly. |
| `iterations` | 8 | Constraint passes per substep. Nonzero. |
| `stretch_stiffness` | 1 | Edge stiffness in [0, 1]. Lower values let the fabric stretch. |
| `bend_stiffness` | 0.5 | Distance-bend stiffness in [0, 1]. |
| `damping` | 0.5 | Per second, at least 0. Velocity is scaled by `max(0, 1 - damping * dt)`. |
| `thickness` | 0.01 m | Contact offset of free particles, at least 0. |
| `gravity_scale` | 1 | Scales the world gravity. |
| `density` | 0.2 kg/m² | Areal mass, above 0. |
| `drag_coefficient` | 1.2 | Dimensionless wind normal-force coefficient, at least 0. |
| `lift_coefficient` | 0.6 | Dimensionless wind lift coefficient, at least 0. |
| `pins` | empty | Source vertex indices held as hard pins. |
| `collide_ground`, `ground_height` | false, 0 | Ground plane at a world height. |
| `colliders` | empty | Up to `MAX_CLOTH_COLLIDERS` (32) entities with built bodies; no duplicates. |
| `collisions` | see below | `ClothCollisionDesc`. |
| `seams` | empty | `ClothSeam { first, second }` source vertex pairs for self-contact exclusion. |
| `render_particles` | empty | Per source vertex, its physical particle. |
| `tangent_frame`, `tangent_uv_set` | false, 0 | Deformed tangents from `uv0` (0) or `uv1` (1). |
| `attachments` | empty | `ClothAttachment { particle, weight, compliance }`. |
| `bend_mode` | `DISTANCE` | `ClothBendMode`: `DISTANCE` or `DIHEDRAL`. |
| `bend_compliance` | 0 | XPBD compliance of dihedral hinges. |
| `rest_angles` | empty | `ClothRestAngle { first, second, angle }` overrides on interior edges. |
| `transport` | empty | Per physical particle weight in [0, 1] for skeletal reference motion. |
| `cuts` | empty | `ClothCutPath { id, vertices, strain_trigger, strain_threshold }`. |
| `tears` | `default_cloth_tear_limits()` | `ClothTearLimits { max_requests = 0, opening_iterations = 32 }`. |
| `sleep_speed` | 0 | m/s; 0 never rests. |
| `sleep_steps` | 30 | Consecutive slow steps before resting. |

Aerodynamics reads `cloth::AIR_DENSITY` (1.225 kg/m³).

### Collision settings

`ClothDesc.collisions` is a `ClothCollisionDesc`. `default_cloth_collision_desc()` and `default_cloth_desc()` provide:

| Field | Default | Meaning |
| --- | ---: | --- |
| `contact_tolerance` | 0.0001 m | Maximum accepted separation deficit after float publication. Finite, above 0. |
| `contact_iterations` | 8 | Final contact passes per substep or publication. Nonzero. |
| `max_shapes` | 128 | Flattened collider leaves across the listed owners. Nonzero. |
| `max_candidates` | 8192 | Candidate pairs retained in one pass. Nonzero. |
| `max_contacts` | 4096 | Active contact records and composed impact responses. Nonzero. |
| `self_collision` | false | Vertex-face and edge-edge contact within this cloth. |
| `continuous` | false | Sweep external contact and enabled self-contact. |
| `max_ccd_iterations` | 64 | Distance advances per candidate path. Nonzero. |

Preparation sizes the staging and contact buffers from these values with checked arithmetic. Updates never grow or
truncate them.

## Attach faults

Every fault leaves the mesh, the component store and the asset counts as they were.

| Fault | Cause |
| --- | --- |
| `cloth::NO_MESH` | The node has no `Mesh` (or a crowd owner has no `AnimatedCrowd`). |
| `cloth::CLOTH_EXISTS` | The node, or that crowd part, already carries cloth. |
| `c3d::INVALID_ID` | The mesh geometry, a listed collider entity, a skeleton, a joint node or a crowd model is dead. |
| `physics::SOURCE_UNAVAILABLE` | The source's CPU positions were released. |
| `physics::NO_BODY` | A listed collider node has no built `RigidBody`. |
| `c3d::UNSUPPORTED` | Morph targets or weights, vertex channels or custom data, a bounds override, membership of an LOD group, a custom material with vertex stages, a non-indexed or non-triangle topology, joint streams on a node without `SkinBinding`, or a `SkinBinding` mesh without joint streams. |
| `c3d::INVALID_ARGUMENT` | Zero substeps, iterations or contact capacities; non-positive or non-finite contact tolerance or density; a stiffness outside [0, 1]; negative or non-finite damping, thickness, drag, lift, bend compliance or `sleep_speed`; non-finite gravity scale or ground height; `tangent_uv_set` above 1; invalid `render_particles`, `attachments`, `rest_angles`, `transport` or `cuts`; a non-manifold or inconsistently wound interior hinge; a pin, seam endpoint or index out of range; non-finite positions; a degenerate triangle; an edge shared by more than two triangles; a collider listed twice; missing or invalid UVs with `tangent_frame`; an invalid skin binding; a node that carries a `ClothOutput` marker; a `world` that does not match the scene and store. |
| `c3d::CAPACITY_EXCEEDED` | More than 32 listed colliders, binding metadata past `max_shapes`, a full geometry pool, state-size overflow or a state block that cannot be allocated. |
| `cloth::CONTACT_PRECISION_EXCEEDED` | A captured native shape bound cannot be represented conservatively. |

Preparation can also return the update faults below when a starting penetration, bend or frame cannot be resolved.
`prepare_subtree` and `prepare_crowd_cloth` additionally return `cloth::REFERENCE_UNAVAILABLE` and
`cloth::OWNERSHIP_CHANGED`.

## Update faults

An update records its fault in `cloth.state.contact_result.failure` (zero on success) and counts it in
`ClothStats.failed`.

| Fault | Meaning |
| --- | --- |
| `c3d::CAPACITY_EXCEEDED` | Binding, candidate or contact storage is full; `stage` identifies the buffer. |
| `cloth::CONTACT_UNRESOLVED` | A contact within its push bound stayed unresolved after the final passes, or a starting penetration outlasted its rounds. |
| `cloth::CONTACT_NONCONVERGENT` | A CCD advance stalled or exhausted its iteration bound. |
| `cloth::CONTACT_PRECISION_EXCEEDED` | Arithmetic, correction or float publication cannot establish the configured tolerance, or an arithmetic mode is unsupported on the staging thread. |
| `cloth::BEND_UNRESOLVED` | A dihedral hinge collapsed, became non-finite, or turned half a revolution within one substep. |
| `cloth::FRAME_UNRESOLVED` | A deformed normal or tangent frame could not produce a finite unit frame. |
| `cloth::OPENING_UNRESOLVED` | A requested or strain-triggered cut could not be opened and certified within its reserves and tolerances. |
| `cloth::REFERENCE_UNAVAILABLE` | A skinned or crowd reference cannot be sampled: the source asset, skeleton or joint nodes changed or were released, or the owner moved into an LOD group. |
| `cloth::OWNERSHIP_CHANGED` | The mesh or generated output node no longer matches what preparation installed. The output node is hidden. |

## Diagnostics

`cloth.state.contact_result` (`ClothContactResult`) is the read-only result of the last attempt. A failed attempt does not
report unvisited work as checked.

| Field | Meaning |
| --- | --- |
| `failure` | The fault, or zero. |
| `stage` | `ClothContactStage` of the failure: `ARITHMETIC`, `BINDINGS`, `CANDIDATES`, `CONTACTS`, `RESOLVE`, `PUBLICATION`, `REEXPRESSION`, `MATERIAL`, `ATTACHMENT`, `BEND`, `REFERENCE` or `OPENING`; `NONE` on success. |
| `candidates`, `contacts` | Observed work. |
| `peak_candidates`, `peak_contacts` | Largest retained sets. |
| `max_residual`, `unresolved` | Description of the last checked participating constraints. |
| `pinned_overlaps` | Pin overlaps excluded from response. |
| `sweeps`, `ccd_iterations`, `impacts`, `resweeps` | Continuous work. |
| `vertex_face_impacts`, `edge_edge_impacts` | Self-contact events. |

`ClothCutResult` (from `cut_result`) holds `path_id`, `attempts`, `outcome` (`ClothCutOutcome`: `NONE`, `APPLIED`,
`ALREADY_CUT`, `REFUSED`), `is_cut`, `failure` and `stage`.

`PhysicsWorld.cloth_stats` (`ClothStats`) holds the last `update_cloths` totals:

| Field | Meaning |
| --- | --- |
| `solve_seconds`, `publish_seconds` | Summed over cloths, so CPU time under parallel staging. |
| `stage_seconds`, `commit_seconds` | Wall time of the staging and commit phases. |
| `particles`, `constraints` | Of the cloths that simulated. |
| `pending`, `resting`, `held` | Cloths skipped for that reason. |
| `failed` | Cloths whose update failed. |
| `candidates`, `contacts`, `ccd_iterations`, `impacts` | Observed contact work. |
| `max_residual` | Largest reported residual. |

`ClothActivity` is `AWAKE`, `RESTING` or `HELD`.

## See also

- [Cloth](cloth.md), [physics](physics.md)
- [Serialization](serialization.md#cloth-adapter) for stored fields and payload versions
