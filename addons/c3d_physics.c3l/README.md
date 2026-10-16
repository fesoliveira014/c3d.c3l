# Physics add-on

`c3d::physics` owns scene-bound rigid bodies, collision queries, joints, ragdolls,
fluid forces and pre-fractured breakables. Applications select `c3d_physics` and
its native dependencies; core does not import the package. Register physics on
the scene, create its world, and destroy the world before the scene/assets.

## Cloth

`c3d::physics::cloth` simulates a mesh over an owned geometry copy with pinned vertices, node
`Wind` drag, an optional ground and one-way particle contacts with sphere, capsule, box,
hull, mesh, heightfield and compound colliders of the bodies listed in `ClothDesc.colliders`.
Contacts are discrete; an unsampled cloth face can pass through a small collider.
Attach with `scene.add_cloth(&assets, node, desc)` and
call `physics.update_cloths()` once after `physics.update`, after final ragdoll/IK poses and
`scene.update_world()`, before rendering. See [Cloth](../../docs/cloth.md) for the contract,
faults, frame order and usage; the `cloth` example includes flag, cape and external-contact
scenes (`--scene flag|cape|both|contacts`). The manual Vulkan acceptance runs with
`c3c test cloth_acceptance --path addons/c3d_physics.c3l/test/gpu`.

`ClothDesc.collisions` sets contact tolerance, iteration count and prepared shape,
candidate and contact capacities. Native body/snapshot bindings are checked during updates;
compound leaves are resolved and counted there because preparation has no world argument.
Shapes use rigid physics' baked geometry and final scene body poses. Pinned body/ground
overlaps are excluded from response and counted. A failed cloth retains committed simulation
and histories while other cloths continue; inspect `ClothState.contact_result` and
`PhysicsWorld.cloth_stats`. Moved-node publication is preserved only when its local float
re-expression meets the configured tolerance. Otherwise REEXPRESSION reports
`CONTACT_PRECISION_EXCEEDED`, keeps the old local bytes/revision, and the application-owned
transform may place that geometry elsewhere.

Cloth consumers require `fp-math=strict`, owner-thread round-to-nearest and gradual underflow.
The library checks supported runtime conditions without changing arithmetic modes; runtime
checks do not establish the consumer's compiler mode. Serialization stores collision authoring
settings and restores pending cloth; runtime buffers, contact results and histories are excluded.

## Replaced assets

A body keeps the collision snapshot it cooked when `replace_geometry` or `replace_texture` replaces its
source. Bodies created afterwards, and world rebuilds, cook the current revision. The geometry copy a cloth
owns is private to the cloth: do not replace or edit it.

## Breakables

A `Breakable` owns physical pieces, welds and optional static support anchors
below a root. Existing constructors derive welds from hull distances; an explicit
recipe supplies its complete graph. An edge breaks when an enabled strength
limit is reached. Its native joint is removed and a `BreakEvent` identifies the
edge and criterion. Breaking one edge need not disconnect a piece.

```c3
physics::register_physics(&scene)!;
PhysicsWorld world = physics::create_physics_world(
    allocator: mem,
    assets: &assets,
    scene: &scene,
    desc: physics::default_physics_desc(),
)!;
defer physics::destroy_physics_world(&world);

scene.update_world();
world.add_breakable(root, physics::default_breakable_desc())!;
```

The legacy `add_breakable` root must be a live non-scene-root node without a Mesh.
At least two Mesh nodes must occur below it. Each is an independent convex,
volume-spanning piece with positive unit scale and no skin/morph deformation.
Root and piece world matrices must be current, finite and rigid. Bake scale
into the asset. The initial ASSEMBLY form requires PARENT paths below its root;
the root itself may use either transform space.

For multiple render primitives or collision hulls per piece, use
`add_breakable_pieces(root, pieces, desc)`. Each `BreakablePieceDesc` holds a body
node's `Entity` and ordered piece-local `GeometryId` hulls. At least two distinct
live descendants are required; no piece may be an ancestor of another. Each
piece has at least one live hull, and may have any number of render children.
Material boundaries do not create physical pieces. The legacy convenience
still treats each Mesh descendant as one piece with one hull.

These entry points share graph construction, body creation, wake and rollback.
PIECES uses one dynamic body per piece with one HULL collider per supplied hull;
ASSEMBLY uses one root body with a collider-to-piece map covering every hull.
Removing a render-only child keeps its body. All hulls contribute to body mass
and center of mass. Hull geometry must remain available for world rebuild.

A glTF primitive becomes a Mesh node. Use explicit body parents to group several
primitives into one piece; collision hulls are independent geometry. The supplied
`examples/assets/fractured_wall.gltf` uses the legacy one-primitive form with
64 separate mesh placements and narrow seams.

Distance at or below `contact_distance` connects two pieces. The smallest
qualifying hull-pair distance selects the weld anchor; exact ties keep the first
pair in caller hull order (first piece's hulls, then second piece's hulls).
Each unordered piece pair has at most one weld, in caller piece-pair order.
Edge/corner contacts also count; the rule does not measure shared face area. Overlap is accepted. The
example uses 0.5 m cubes on a 0.508 m pitch: face gaps are below the default
0.01 m threshold, diagonal gaps are above it, producing 112 welds.

## Explicit recipes and strengths

`BreakableRecipeDesc` contains ordered `BreakablePieceView` values, internal
`BreakableWeldDesc` values, `BreakableAnchorDesc` values, physical settings,
default strength and an evaluation mode. Begin with
`default_breakable_recipe_desc()`. Each piece supplies its Entity, ordered hull
IDs and root-relative `rest_frame`. The weld and anchor lists are authoritative;
an empty list creates no edges. The library copies all inputs on attachment.

An internal weld names two distinct piece indices, a rigid frame in each piece,
and a unit `moment_axis` in frame A. For an anchor, frame A is local to the piece
body's origin and frame B to the target body's origin, rather than their centres
of mass. Its complete target Entity must have a live ordinary STATIC body when
prepared. Entity values are scoped to the receiving Scene: pass IDs obtained from
that Scene. IDs contain no Scene token, so an identical value obtained elsewhere
cannot be distinguished by origin. Native-world membership is checked when binding.
The application retains the target and its independent bodies/joints; the
Breakable owns only its anchor weld. Place a support outside the Breakable
subtree, such as a sibling under a shared scene parent. Existing restrictions
on independent body, joint, ragdoll and nested Breakable roles still apply.

`BreakableStrength` has three finite nonnegative limits:

| Field | Quantity | Unit |
| --- | --- | --- |
| `force` | Reaction-force magnitude | N |
| `twist` | Absolute torque component along the world-space moment axis | N·m |
| `bending` | Magnitude of the remaining torque | N·m |

Zero enables a criterion at zero load; `float::max` disables it.
`default_breakable_strength()` sets 2,000 N and disables both moment limits.
A piece's `has_strength` selects its copied value; otherwise it inherits the
recipe default. An anchor's `has_target_strength` does the same for its target.
Take the componentwise minimum of the two endpoints, then replace all three
limits when `has_strength_override` is set. An override may strengthen or disable
a criterion. Contact `SurfaceMaterialDesc` values remain independent.

`NATIVE_FORCE` is the default and preserves native force-threshold behavior.
Enabled moment limits require `SAMPLED_REACTION`. That mode reads each live
weld's reaction immediately after every fixed step, using the current native
frame A for its moment axis. It compares each magnitude with `>=` and selects
force, then twist, then bending if several limits match. The native getters
represent stored post-step impulses divided by the native substep duration.
They are neither substep peaks nor outer-frame averages; a transient earlier
in the step can be missed. Zero fixed steps produce no new sample.

## Fracture generation

Fracture generation is maintained in the standalone
[c3d_fracture.c3l](https://github.com/fesoliveira014/c3d_fracture.c3l) project under
the `fracture` namespace, with c3d as a dependency. This package accepts
authored hulls through `add_breakable_pieces` and retains captured recipes,
preparation, welds and break events. See [Fracture generation](../../docs/fracture.md)
for the project boundary.

## Pending fracture preparation

`scene.attach_breakable_pieces(&assets, root, pieces, desc)` captures an automatic
recipe. `scene.attach_breakable_recipe(&assets, root, recipe)` copies an explicit
graph, rest frames, strengths and anchors. Both work without a PhysicsWorld,
cooked hulls or native objects. Caller arrays may be released afterward;
attachment leaves node poses and independent authoring unchanged.
`Breakable.is_prepared()` is false until runtime preparation succeeds.

`world.prepare_breakable(root)` cooks the retained hulls and creates the requested
initial representation. It derives an automatic graph or preserves the explicit
one, and checks required static targets before native construction.
It publishes a new state only after all preparation succeeds. The old state and
its borrowed arrays are invalidated on success. A prepared call is unchanged.
Failure leaves the pending recipe, nodes and earlier prepared owners unchanged;
staged native objects and hull holds are released. Correct a failed asset or
capacity condition and retry preparation.

`world.prepare_breakable_subtree(root)` attempts every owner under the selected
root and returns the first failure after completing the other owners. Omitting
`root` selects the whole scene. Normal physics updates leave unprepared owners
pending, including after world replacement. BodyStatus.PENDING still describes
native rebinding for owners that already completed preparation; it is separate
from `is_prepared()`.

The captured piece identity must still be live at preparation. Deletion and slot
reuse do not replace it. Captured hull order and rest frames remain unchanged.
Automatic preparation derives candidate welds while temporarily holding cooked
hulls. Both recipe kinds check current relative piece poses before staging
bodies or native welds.
Position tolerance is the larger of 0.0001 metres and one millionth of the largest
absolute coordinate among the pair's current world positions and captured rest
positions. This covers accumulated float transform rounding at large world
coordinates. Angle tolerance is 0.0001 radians. A rigid motion of the whole piece
set is accepted. A displaced connected piece returns
`INVALID_ARGUMENT` and remains pending. Restoring its placement permits retry.
Bodies begin at their current piece-node poses; the assembly retains the matching
current collision frames separately from the immutable captured recipe.

`breakable.preparation_mismatch()` returns a read-only borrowed
`BreakableMismatch*`, or null when no mismatch exists. Its `piece_a` and `piece_b`
indices refer to the copied piece order. The borrow expires at the next
preparation or removal. Details clear before each preparation attempt and after
success. Callers identify the root from the node passed to preparation (or the
entity owning the component) and can report its path alongside the pair.

Attachment rejects dead piece/hull identities with `INVALID_ID`; empty hull
lists, duplicate/non-descendant pieces and fewer than two pieces with
`INVALID_ARGUMENT`; incompatible ownership with `BREAKABLE_EXISTS` or
`BODY_EXISTS`; and failed recipe allocation with `CAPACITY_EXCEEDED`.
Invalid captured piece rest frames return `UNSUPPORTED` or `INVALID_ARGUMENT`.
Malformed explicit weld or anchor frames return `INVALID_ARGUMENT`.
Every attachment failure adds nothing. Pending owners show their ordinary
authored piece nodes but have no
native bodies or welds. `PhysicsWorld.prepare_breakable_subtree` requires a physics
world, live piece/hull sources and piece poses matching the recipe relations.
The eager `add_breakable`, `add_breakable_pieces` and `add_breakable_recipe`
constructors attach and prepare in one call, removing their attempted pending
authoring on failure. The existing automatic constructors retain their
validation differences: the legacy mesh-tree constructor supports nested
mesh pieces, while the explicit-piece constructor rejects ancestor-related
pieces. Captured views support recipes produced by either constructor.

## Forms, ownership and faults

`default_breakable_desc()` selects ASSEMBLY: one enabled kinematic root body
with every piece hull. Pieces remain parent-relative and follow the root. A
qualifying dynamic-body hit changes it to PIECES: one dynamic body per
surviving piece, with its node committed to WORLD. Setting `sleep_until_hit`
false creates PIECES directly. `wake_breakable(root)` performs the transition
explicitly; a live PIECES call is a no-op.

`break_force` is finite nonnegative newtons, `contact_distance` finite
nonnegative meters, and density finite positive kg/m³. Surface coefficients
are finite/nonnegative and tangent velocity finite. The descriptor, geometry
identities and fracture layout are captured. Recreate to change them. Read
state through `scene.get(root, Breakable).state`; retain the root ID and
reacquire the component after structural changes. The state and its arrays are
library-owned. The component is 8 bytes on x64; its state/arrays are allocated
only for real breakables in one scene-allocator block.

`state.piece_view(index)` exposes the captured Entity, ordered hull IDs,
root-relative rest frame and optional strength. `state.weld_view(index)` exposes
the two piece indices, local frames, moment axis, effective strength and override.
`state.anchor_count()` and `state.anchor_view(index)` expose copied anchor
authoring and effective strength. These views contain no native IDs or damage.
Indices stay stable for the captured runtime even after removal; callers check
Entity liveness. Reacquire state and borrowed hull arrays after preparation or
removal. Re-authoring the same automatic inputs derives the same ordered graph.

Creation rejects overlapping breakables, existing bodies or conflicting
joint/ragdoll roles in the subtree, invalid geometry and unsupported transforms.
`BREAKABLE_EXISTS`, `BODY_EXISTS`, `INVALID_ARGUMENT`, `INVALID_ID` and
`UNSUPPORTED` identify those cases. Missing uncached hull source reports
`SOURCE_UNAVAILABLE`; snapshot exhaustion reports `CAPACITY_EXCEEDED`; native
constructor/hull faults propagate. No component-store capacity fault is invented.

Creation and wake are transactional for surviving pieces. Explicit wake first
prunes externally removed pieces; that cleanup remains even if transition
construction fails. Failed wake retains the remaining assembly and
visitor velocity, releases staged objects/holds and permits another request.
Automatic failures enter `build_failures()`. A failed or pending representation
cannot be explicitly awakened and reports `NO_BODY` until ready. On a new
world, pending piece bodies remain disabled until all surviving unbroken
edges can bind; terminal binding failure is recorded as FAILED. Source failures
follow the existing revision retry policy. Other failures require an explicit
reset with ready inputs or recreation.

Remove pieces through normal scene removal. The next physics update prunes
incident edges without a break report and removes their assembly collision
shapes and authored collider entries. World replacement cannot resurrect them.
Removing all pieces leaves an empty valid component. Use
`world.remove_breakable(root)` to remove owned bodies/welds while keeping nodes
and meshes; WORLD piece transforms stay WORLD. Removing only the raw component
releases graph state/welds but leaves authored bodies for application takeover.
Removing the root subtree releases everything through normal hooks.

## Static anchors and reset

Anchors constrain dynamic PIECES after wake. ASSEMBLY remains one kinematic
root body and has no live anchor welds. Wake stages all piece bodies and their
internal/anchor welds before replacing the assembly.

An unbroken anchor rebinds when the same target Entity acquires a replacement
STATIC body. An unavailable or non-static target makes it inactive and reports
a binding failure; this is not a strength break. It can bind again when the
same target becomes usable. Deleting the target permanently prunes its captured
anchor, even if the Entity slot is reused. Broken edges stay broken through
body/world replacement until an explicit reset repairs them.

`world.reset_breakable(root, form, root_pose)` selects ASSEMBLY or PIECES.
The optional `maths::Transform* root_pose` is a rigid world-space pose; null uses
the root's current pose. For example, to repair released pieces at the current
root placement:

```c3
world.reset_breakable(root, PIECES)!;
```

Reset returns surviving pieces to their captured rest frames, repairs surviving
internal edges and non-pruned anchors, and clears velocities and interpolation
history. It does not recreate
deleted nodes, regenerate geometry, or move support bodies. Existing collision
snapshot and source-revision rules still apply.
Zero survivors remain valid with no native body; one survivor creates the
selected form's single body without internal welds.

Reset also supports pending or failed captured recipes once required inputs are
ready. The requested placement must agree with every surviving fixed anchor,
including broken anchors that reset would repair. Disagreement returns
`INVALID_ARGUMENT`. Replaced foreign bodies or foreign joints attached to an
owned body are rejected; unrelated joints on retained support bodies are allowed.

Call reset on the owner thread outside native stepping and event-stream
consumption. A returned validation, capacity or construction fault preserves the
live representation, poses, velocities, handles and damage state while releasing
staged objects. Cleanup of already-deleted Entities is retained. A prepared reset
retains captured authoring storage and indices but replaces owned native handles;
reacquire body/joint handles afterward. Preparing a pending recipe still
invalidates its old authoring borrows. The backend's process-fatal native
allocation failure cannot be rolled back.

## Update and event order

```c3
scene.update_world();
world.update(dt);
foreach (event : world.breaks()) {
    handle_break(event.root, event.piece_a, event.piece_b, event.point);
}
scene.flush_removals();
scene.update_world();
```

`handle_break` is application code in this function-body example. Consume node
borrows before removals. Reports reset once per update and accumulate across
its fixed steps. Capacity overflow increments the shared `dropped_events`
counter; a full or zero-capacity report buffer still allows wake and fracture.
The point is the authored weld anchor through the current physics pose,
not a guaranteed impact point or seam centre. A single edge reports once per
break/reset cycle. `edge_kind` and `edge_index` identify the captured internal
weld or anchor; `endpoint_a`/`endpoint_b` retain Entity identities, with endpoint B
the borrowed target for an anchor. Node pointers remain frame borrows.

`phase` distinguishes `NATIVE_THRESHOLD` from `POST_FIXED_STEP`.
`loads_available` is false for native-threshold reports because the actual trigger
load is unavailable. Sampled reports retain all three `loads` and effective
`limits`, even when only one `criterion` triggers. Within each Breakable/fixed
step, sampled reports follow internal-weld index order, then anchor index order.
Native-force reports retain native event order.

Intact wake uses `mass * approach_speed >= break_force * fixed_dt`, plus the
world's hit-speed threshold. This is a wake heuristic, separate from the selected
weld evaluation mode. Native event streams are consumed before
structural mutation, and only one qualifying hit is replayed per assembly/step.
Automatic wake uses the native assembly pose; manual wake uses its current
authored root pose. Fragments inherit assembly linear/angular motion. Staged
bodies are enabled before their captured velocities are restored, since the
native backend drops velocity writes on disabled bodies.

The visitor's relative normal point speed is restored after successful wake;
tangential and angular motion remain. This approximates first contact one step
later. It is not an exact collision-history reconstruction and imposes no
universal fracture latency. An unanchored remainder may tip under a strong impact.
Native record/replay includes the body/joint mutations, but does not recreate scene
components or re-dispatch BreakEvent values.

## Rebasing the origin

After `Scene.shift_origin(offset)` and `scene.update_world()`, call
`physics.shift_origin(&scene, offset)` with the same offset (`offset.y == 0`). It
subtracts the offset from every body's pose through `set_transform`, including static
bodies, then rebuilds the static tree once. Velocities, sleep state, joints, welds and
contacts are kept, so a resting stack stays asleep. Cloth positions, pin anchors and
targets, collision shapes and the sampled body poses move with it; nothing allocates.
Call it between `end_frame` and the next `physics.update`. A recording captures the
shift as `set_transform` calls of every body, and replay reproduces it. The
`FluidSurfaceFn` of buoyancy belongs to the application and must follow the shift.
See `docs/large_world.md` for the full order.

## Example and checks

```powershell
python scripts/build.py --example breakable
addons/c3d_physics.c3l/build/breakable.exe --pieces
addons/c3d_physics.c3l/build/breakable.exe --model addons/c3d_physics.c3l/examples/assets/fractured_wall.gltf
addons/c3d_physics.c3l/build/breakable.exe --frames=120 --acceptance --capture=fracture.rgba
addons/c3d_physics.c3l/build/breakable.exe --anchors --sampled --acceptance --frames=480 --reset-at=420
c3c build breakable --path addons/c3d_physics.c3l -O3
addons/c3d_physics.c3l/build/breakable.exe --benchmark
```

Left click launches a box; right drag orbits and the wheel zooms. The panel
selects bottom-row anchors, native or sampled evaluation, force/twist/bending
limits and the initial form. Rebuild applies those settings and clears
projectiles. The two reset buttons restore the captured recipe as ASSEMBLY or
PIECES; they do not adopt edited controls until Rebuild is used. The panel shows
the last break criterion and distinguishes sampled loads from native-threshold
reports, whose triggering load is unavailable.

`--anchors` adds bottom-row support anchors; `--sampled` selects sampled reaction
strengths. `--reset-at=420` resets after 420 frames to the selected initial form.
The demonstration uses a 40,000 N force threshold and a dense 1,000 kg projectile
at 15 m/s, independently of the library's 2,000 N default. `--walls 32` shows the
multi-wall case.
Capture files are 1280×720 RGBA8 scene pixels. The GPU example always enables
Vulkan validation. WSL is restricted to builds and CPU tests.

The CPU benchmark reports authoring/update costs and native body/joint/awake
counts. Timed updates exclude geometry/node creation and world-transform
publication. Maximum strength retains the complete graph during idle runs;
PIECES does not imply that its native bodies are asleep. Timing results and
manual acceptance records belong to the corresponding change evidence.

![An impact opens the authored wall](images/breakable.png)
The anchored example before and after restoring its captured rest recipe:

![Anchored wall after impact](images/breakable_anchors_broken.png)

![Anchored wall after reset](images/breakable_anchors_reset.png)

Run `python scripts/build.py --test` for the full CPU matrix, or
`c3c test physics_test --path addons/c3d_physics.c3l` for the package. The breakable
cases cover ownership, rollback, native thresholds, removed assembly shapes,
world replacement, overflow, publication and motion inheritance.
