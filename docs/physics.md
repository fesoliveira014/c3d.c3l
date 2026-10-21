# Physics

The `c3d_physics` add-on (`addons/c3d_physics.c3l`, module `c3d::physics`) binds [box3d](https://github.com/erincatto/box3d)
rigid bodies to scene nodes. It owns the world, bodies and colliders, joints, forces, events, scene queries,
ragdolls, buoyancy, breakables and cloth. Applications select the package; core does not import it and has no
physics feature flag. Serialization of the physics components needs `C3D_PHYSICS_SERIAL` and `c3d_serial`.

Related pages: [collision queries](collision_queries.md), [ragdolls](ragdoll.md), [breakables](breakables.md),
[cloth](cloth.md), [buoyancy](buoyancy.md), [physics inspector](physics_inspector.md) and the
[character controller](../addons/c3d_character.c3l/README.md).

## Quick start

List `c3d_physics` and `b3` with c3d's own dependencies ([release](release.md#using-a-release)). Register the
components, create the world, author bodies on nodes and update once per frame. Inside a fallible function, with a
`Scene scene` and an `AssetStore assets` already created:

```c3
physics::register_physics(&scene)!;
PhysicsWorld world = physics::create_physics_world(
    allocator: mem,
    assets:    &assets,
    scene:     &scene,
    desc:      physics::default_physics_desc(),
)!;
defer physics::destroy_physics_world(&world);

scene.update_world();

ColliderDesc ground_shape = physics::default_collider_desc(BOX);
ground_shape.half_extents = { 20, 0.5f, 20 };
world.add_body(ground, physics::default_body_desc(STATIC), (&ground_shape)[:1])!;

ColliderDesc crate_shape = physics::default_collider_desc(BOX);
crate_shape.half_extents = { 0.5f, 0.5f, 0.5f };
crate_shape.hit_events = true;
world.add_body(crate, physics::default_body_desc(DYNAMIC), (&crate_shape)[:1])!;

while (running) {
    scene.update_world();
    world.update(delta);
    foreach (hit : world.hits()) on_hit(hit.a, hit.b, hit.approach_speed);
    scene.flush_removals();
    scene.update_world();
}
```

`ground` and `crate` are mesh nodes the application created. `on_hit` is application code. The `physics` example
is this loop with a renderer; run it with `python3 scripts/build.py --example physics`.

## Concepts

### Authored and built bodies

A `PhysicsBody` component is the authored description: a `BodyDesc` and a copy of its `ColliderDesc` array. The
world builds it into a `RigidBody` component, which holds the box3d body and one `Collider` record per shape.
`PhysicsBody.status` is `PENDING`, `LIVE` or `FAILED`.

| Path | Effect |
| --- | --- |
| `PhysicsWorld.add_body(node, body, colliders)` | Authors and builds immediately. Faults leave the node unchanged. |
| `Scene.add_physics_body(node, body, colliders)` | Authors only. The next `PhysicsWorld.update` builds it. |
| `Scene.add_static_mesh_bodies(root, filter)` | Authors one static `MESH` body for each mesh node under `root` that has none. Returns the count. |
| `PhysicsBody.mark_changed()` | Rebuilds from the current description on the next update and resets motion to the description. |
| `PhysicsWorld.remove_body(node)` | Removes the built and the authored body immediately. |

A body that cannot build stays `FAILED` with its fault in `PhysicsBody.failure`, and the fault is listed in
`build_failures()` for that update. `SOURCE_UNAVAILABLE` retries automatically when the revision of a source asset
changes; every other failure needs `mark_changed` or a new body. Destroying the world keeps the authored bodies and
sets them back to `PENDING`, so a new world rebuilds them.

### Poses and transform ownership

- A body starts at the node's world pose. Node scale is ignored; scale a collider with `ColliderDesc.local.scale`
  where the shape allows it.
- A dynamic body writes its pose to the node's world pose each `update`, interpolated between the last two fixed
  steps unless `PhysicsTuning.interpolate` is false.
- A kinematic body follows its node: before each fixed step the node's world transform becomes the body's target
  pose. Move the node and call `Scene.update_world` before `update`.
- A static body is not moved. Moving its node does not move the body; `PhysicsWorld.teleport` moves a body without
  sweeping and writes the pose to the node immediately.
- Units are metres, kilograms and seconds. Y is up.

### Fixed step

`update(dt)` adds `dt` to an accumulator and runs `PhysicsTuning.fixed_dt` steps (default 1/60 s) with
`sub_steps` solver sub-steps each (default 4). One update runs at most `max_steps_per_frame` steps (default 4); a
longer backlog is dropped, not simulated. `steps_last_update` and `alpha` report the result. `update` with
`dt = 0` builds pending bodies and runs no step.

### Lifetimes

The world borrows the scene and the asset store. Destroy the world before the scene and the store. `destroy_physics_world`
removes the built bodies and joints and leaves the authored components. Register the components with
`register_physics` before creating the world.

### Collision data

Hulls, meshes and height fields are cooked from the asset store the first time a body needs them and held in
snapshot slots (`PhysicsDesc.snapshot_capacity`, default 256, one slot per distinct cooked source). A live body keeps
the snapshot it cooked when its source asset is replaced or edited; `mark_changed` rebuilds it from the current
revision. A world can borrow a [`CollisionCache`](collision_queries.md#share-cooked-geometry-with-worlds) instead of
owning its table. If an asset's CPU data was released and no cooked entry exists, the body fails with
`SOURCE_UNAVAILABLE`.

## Bodies and colliders

`BodyDesc` fields:

| Field | Default | Meaning |
| --- | --- | --- |
| `kind` | `DYNAMIC` | `STATIC`, `KINEMATIC` or `DYNAMIC`. |
| `name` | empty | Copied; shown in debug output. |
| `linear_velocity`, `angular_velocity` | 0 | Initial velocities. Dropped on a disabled body. |
| `linear_damping`, `angular_damping` | 0 | Velocity damping. |
| `gravity_scale` | 1 | Scales world gravity for this body. |
| `allow_sleep` | true | Lets the body sleep. |
| `bullet` | false | Continuous collision against other dynamic bodies. box3d advises using it sparingly. |
| `disabled` | false | The body neither simulates, collides nor answers queries. `set_enabled` changes it. |
| `locks` | none | `MotionLocks`: fixed linear and angular axes. |

`default_body_desc(kind)` fills these. `ColliderDesc.kind` selects the shape; the other fields apply by kind.

| `ColliderKind` | Fields | Body kinds |
| --- | --- | --- |
| `SPHERE` | `radius` | any |
| `CAPSULE` | `radius`, `half_height`; the segment runs along local Y | any |
| `BOX` | `half_extents` | any |
| `HULL` | `geometry`: the convex hull of the geometry's positions | any |
| `MESH` | `geometry`, optional `material_indices` (one per triangle) | `STATIC` only |
| `HEIGHT_FIELD` | `height_field` (see [height fields](collision_queries_reference.md#height-fields)), optional per-cell `material_indices` | `STATIC` only |
| `COMPOUND` | `children`: spheres, capsules, boxes, hulls and meshes with their own placement and materials; no `sensor` | `STATIC` only |

`MESH`, `HEIGHT_FIELD` and `COMPOUND` colliders return `STATIC_ONLY` on a non-static body and `UNSUPPORTED` with a
non-identity `local` position or rotation. A mesh or height field's `local.scale` scales the shape; a compound takes scale
only from each child's `local`, and hull children must be unscaled. The common collider fields:

| Field | Default | Meaning |
| --- | --- | --- |
| `local` | identity | Placement in body space. `scale` applies to hulls, meshes and height fields. |
| `density` | 1000 | kg/m³. Zero adds no mass. |
| `material` | friction 0.6, restitution 0 | `SurfaceMaterialDesc`: `friction`, `restitution`, `rolling_resistance` (spheres and capsules), `tangent_velocity` (shape-local, for conveyors) and an application `id`. |
| `face_materials`, `material_indices` | empty | Per-face (mesh) or per-cell (height field) materials. |
| `sensor` | false | Detects overlaps without a collision response. A sensor with density above zero still adds mass. |
| `contact_events` | false | Reports contact begin and end, and makes the shape visible to sensors. Applies to any pair in which either shape sets it. |
| `hit_events` | false | Reports hits above `hit_speed_threshold`. Applies to any pair in which either shape sets it. |
| `filter` | `FILTER_ALL` | `CollisionFilter`: `category`, `mask` and `group`. |
| `explosion_scale` | 1 | Scales the impulse of `explode`. |

Two shapes with the same nonzero `group` always collide when it is positive and never when it is negative. Otherwise
they collide when each one's `category` is in the other's `mask`. Queries and mover casts test category and mask only.

### Surface materials

The friction and restitution of a contact come from `PhysicsTuning.friction_mix` and `restitution_mix`. Both are pure
functions that may run on box3d worker threads inside the step. A null mix uses box3d's default: the geometric mean of
the two frictions and the larger restitution. The `id` of each shape's material reaches `HitEvent` and `RayHit` so the
application can pick sounds and effects.

## Joints

A `PhysicsJoint` on a node attaches that node's body to the body of `desc.other`. `JointDesc.frame` places the joint
in the node's body space; `anchor_frame` places it in the other body's space. Both bodies must be live. The joint
binds on the next update after both exist.

| `JointKind` | Members of the matching field | Use |
| --- | --- | --- |
| `DISTANCE` | `distance`: length, range, spring, motor | Rope or rod |
| `REVOLUTE` | `revolute`: target angle, angle limit, spring, motor | Hinge about the frame's z axis |
| `SPHERICAL` | `spherical`: cone, twist limit, spring, motor | Ball joint |
| `PRISMATIC` | `prismatic`: target translation, limit, spring, motor | Slider along the frame's x axis |
| `WELD` | `weld`: linear and angular springs | Rigid attachment; a disabled spring is fully rigid |
| `WHEEL` | `wheel`: suspension, steering, spin | Vehicle wheel |
| `MOTOR` | `motor`: velocity and spring targets with caps | Drive the body relative to the anchor |
| `PARALLEL` | `parallel`: spring, torque cap | Keep two z axes parallel |
| `FILTER` | none | Disable collisions between the two bodies |

`default_joint_desc(kind, other)` fills box3d's defaults. `collide_connected` lets the connected bodies collide.

| Call | Effect |
| --- | --- |
| `PhysicsWorld.add_joint(node, desc)` | Authors and binds immediately. Faults `NO_BODY` when either body is not built. |
| `Scene.add_physics_joint(node, desc)` | Authors only. Faults `JOINT_EXISTS` on a second joint for the node. |
| `PhysicsJoint.mark_changed()` | Rebinds on the next update. |
| `PhysicsWorld.apply_joint(node)` | Pushes the edited description into the bound joint immediately. A changed kind or `other` rebinds on the next update. |
| `PhysicsWorld.remove_joint(node)` | Removes the authored and bound joint. |
| `PhysicsWorld.joint_state(node)` | `JointState`: constraint force and torque, linear and angular separation. Faults `NO_JOINT`. |

A node carries at most one joint. `force_threshold` and `torque_threshold` of `JointDesc` set when
`joint_events()` reports the joint. The `vehicle` example builds a chassis on four `WHEEL` joints.

## Forces and motion

| Call or component | Effect |
| --- | --- |
| `Wind` component | Applies air flow to every collider of the body each fixed step. `velocity`, `drag`, `lift`, `max_speed`. Cloth reads only `velocity` and `max_speed` ([cloth](cloth.md#mass-and-wind)). |
| `Force` component | Applies `force` (world space) at `local_point` (body space) each fixed step. |
| `Buoyancy` component | Lift and drag from a fluid the application installs ([buoyancy](buoyancy.md)). |
| `PhysicsWorld.apply_impulse(node, impulse, world_point)` | Applies an impulse and wakes the body. |
| `PhysicsWorld.set_velocity(node, linear, angular)` | Sets both velocities and wakes the body. |
| `PhysicsWorld.explode(desc)` | Pushes dynamic bodies away from `ExplosionDesc.position` with a radial impulse. |
| `PhysicsWorld.set_kinematic_target(node, position, rotation)` | Sets the pose a kinematic body reaches by the end of the current fixed step. Faults `NO_BODY` or `NOT_KINEMATIC`. |
| `PhysicsWorld.teleport(node, position, rotation)` | Moves a body without sweeping and writes the pose to the node. |
| `PhysicsWorld.point_velocity(node, world_point)` | World velocity of the body at a point. |
| `PhysicsWorld.set_enabled(node, enabled)` | Enables or disables the body. Enable before setting velocities. |

`Wind` and `Force` act through components because box3d clears applied forces after every step; the world
reapplies them before each one.

## Events

The world fills these lists during `update` and resets them at the start of the next one:

| List | Element | Requires |
| --- | --- | --- |
| `contacts_begin()`, `contacts_end()` | `ContactEvent { a, b }` | `contact_events` on either shape of the pair |
| `hits()` | `HitEvent`: nodes, `point`, `normal`, `approach_speed`, both surface ids | `hit_events` on either shape of the pair; approach speed above `hit_speed_threshold` (default 1 m/s) |
| `sensors_begin()`, `sensors_end()` | `SensorEvent { sensor, visitor }` | a `sensor` shape; the visitor's shape needs `contact_events` and must be convex |
| `joint_events()` | `JointEvent { node, other }` | a joint threshold |
| `breaks()` | `BreakEvent` | a [`Breakable`](breakables.md#update-and-event-order) |
| `build_failures()` | `BuildFailure { node, reason }` | none |

Node pointers in events are frame borrows: read them before `Scene.flush_removals`. Each list holds
`PhysicsDesc.event_capacity` entries (default 4096); an event past capacity increments `dropped_events`.

## Queries

| Call | Result |
| --- | --- |
| `raycast(origin, direction, max_distance, filter)` | Closest `RayHit`, or `b3::NO_HIT`. `direction` is unit length; `fraction` is of `max_distance`. |
| `overlap_sphere(allocator, center, radius, filter)` | Nodes whose shapes overlap the sphere, each once. |
| `overlap_aabb(allocator, bounds, filter)` | Nodes with a shape whose bounds overlap the box (broad phase). |
| `cast_shape(allocator, shape, translation, filter)` | `ShapeCastHit` list for a moving sphere, capsule or box, nearest first. |
| `contact_points(allocator, node)` | `ContactPoint` list of the node's last step. `normal` points from the node toward `other`; a speculative point may be slightly separated. |
| `cast_mover(...)`, `collide_mover(...)`, `solve_planes(...)`, `clip_vector(...)` | Capsule mover primitives for application-driven controllers. |

The allocator receives the result array. Results past 256 overlap shapes, 128 cast hits and 64 body contacts per
call are dropped. Queries without a world, and prepared mesh and height-field shapes, are in
[collision queries](collision_queries.md). `PhysicsWorld.set_mover_pass(pass)` installs the per-step and write-back
hooks of an application mover; the [character controller](../addons/c3d_character.c3l/README.md) uses it.

## Tuning and diagnostics

`PhysicsDesc` holds the creation-time settings; `PhysicsTuning` holds the ones `set_tuning` changes on a live world.

| Field | Default | Meaning |
| --- | --- | --- |
| `tuning.gravity` | (0, -9.81, 0) | m/s². |
| `tuning.fixed_dt` | 1/60 | Seconds per step. Must be positive. |
| `tuning.sub_steps` | 4 | Solver sub-steps per step. Must be positive. |
| `tuning.max_steps_per_frame` | 4 | Steps one update may take. |
| `tuning.interpolate` | true | Interpolate dynamic poses between steps. |
| `tuning.hit_speed_threshold` | 1 | m/s. |
| `tuning.contact_hertz`, `contact_damping_ratio`, `contact_speed` | box3d's | Contact softness. |
| `tuning.maximum_linear_speed`, `restitution_threshold` | box3d's | Speed cap and bounce threshold. |
| `tuning.continuous`, `tuning.sleep` | box3d's | Continuous collision and sleeping. |
| `tuning.friction_mix`, `restitution_mix` | null | Custom contact mixes; null keeps box3d's. |
| `cache_wireframes` | true | Builds collider wireframes with each snapshot. Off, `debug_draw` skips cooked colliders. |
| `event_capacity` | 4096 | Entries per event list; about 800 KiB per world at the default. |
| `snapshot_capacity` | 256 | Collision snapshot slots. |
| `worker_count` | 1 | box3d worker threads. Fixed at creation. |

Diagnostics: `counters()` returns `PhysicsCounters` (bodies, awake bodies, shapes, contacts, joints, islands, snapshot
occupancy); `profile()` returns the phase times of the last fixed step in milliseconds; `body_state(node)` returns
awake state, mass, centre of mass and velocities; `wake(node)` wakes a body. `update` visits every authored
`PhysicsBody` to find pending builds, so a scene with many authored static bodies has a per-update cost that grows
with their number.

### Debug draw

`PhysicsWorld.debug_draw(sink, options)` appends lines to a CPU [`DebugDraw`](debug_draw.md) sink that the
application cleared. `PhysicsDebugOptions` selects collider wires, contacts, bounds, joints, mass frames, islands and
the contact-force options. A full sink stops generating collider lines and adds the skipped count to
`DebugDraw.dropped`. With `set_parallel` installed and more than 256 bodies, collider lines are generated on the
workers when they all fit in the sink; the result matches the serial draw. Do not step or edit the world while
`debug_draw` runs. The [physics inspector](physics_inspector.md) draws these options from a panel.

### Recording and replay

`start_recording(byte_capacity)` records the world's mutations; `stop_recording(allocator)` returns the bytes.
`create_physics_replay(allocator, data, friction_mix, restitution_mix)` opens them in a separate box3d world with
`step`, `restart`, `seek`, `frame`, `frame_count` and `diverge_frame`, and `PhysicsReplay.debug_draw` draws it. A
recording stores calls, not callbacks: a replay matches the recording only with the mixes the recorded world used.
A recording captures an origin shift as `set_transform` calls on every body, and replay reproduces it. A replay runs the
box3d world only: it recreates no scene components and reports no events.

## Update on a worker pool

`PhysicsWorld.set_parallel(ParallelFor)` lets the world run [cloth staging](cloth.md#update-on-a-job-pool), breakable
graph building and debug collider generation on the application's workers. The hook, its rules and the adapter for a
[`c3d_job`](jobs.md) pool are in [the job pool](jobs.md#parallelfor-hook); the physics package imports no job library.

Results are bit-identical to the serial path for any worker count. While a parallel call runs, the application must
not mutate the scene or the world, or step it. The box3d step has its own threads (`PhysicsDesc.worker_count`).

## Ragdolls, breakables, cloth and characters

- A `Ragdoll` turns a skinned character's bones into capsule bodies and joints and blends simulation with animation.
  See [ragdolls](ragdoll.md).
- A `Breakable` holds pre-fractured pieces joined by welds that break under load. See [breakables](breakables.md).
- `c3d::physics::cloth` simulates cloth over an owned copy of a mesh. See [cloth](cloth.md).
- The `c3d_character` package moves kinematic capsules through the world. See its
  [README](../addons/c3d_character.c3l/README.md).

## Rebase the origin

After `Scene.shift_origin(offset)` and `scene.update_world()`, call `world.shift_origin(&scene, offset)` with the
same offset (`offset.y` must be 0). It subtracts the offset from every body pose, static bodies included, rebuilds the
static tree once, and moves ragdoll recovery targets and cloth state with them. Velocities, sleep state,
joints, welds and contacts are kept, so a resting stack stays asleep. Call it between the end of the frame and the
next `update`. The `FluidSurfaceFn` or `FluidSampleFn` of buoyancy belongs to the application and must follow the
shift. The full order is in [origin rebasing](origin_rebasing.md).

## Serialization

With `C3D_PHYSICS_SERIAL`, `physics::register_serial_codecs()` installs the codecs for `PhysicsBody`, `PhysicsJoint`,
`Wind`, `Force`, `Buoyancy`, `Ragdoll`, `Breakable`, `Cloth`, `CrowdCloth` and `HeightFieldWindows`. Restored bodies
are `PENDING`; the world builds them on its next update. `RigidBody`, `Joint`, `ClothOutput` and
`HeightFieldWindowOwner` are transient. Payload versions and coverage are in
[serialization](serialization_reference.md#physics).

## Examples

All examples live in `addons/c3d_physics.c3l/examples`; build one with `python3 scripts/build.py --example <name>`.

| Example | Shows |
| --- | --- |
| `physics` | Thrown boxes on ramps and a moving kinematic platform, contact highlights, ray picks, debug draw |
| `physics_instanced` | The same scene with every box drawn from one instanced batch |
| `physics_components` | Bodies and level built from components: `Wind`, `Force`, explosions, surface materials, joints. `--stress` adds about twenty thousand static bodies |
| `vehicle` | A chassis on `WHEEL` joints with steering, suspension and a drive motor |
| `ragdoll` | Simulated and animated bones, blending and physical get-up recovery |
| `breakable` | A fractured wall, anchors, sampled strengths and reset |
| `cloth` | Flags, capes, contacts, self-contact, crowds and tearing |
| `collision_math` | World-free collision queries on prepared shapes |

## Limits

- One fluid per world; a `Buoyancy` body floats by the bounds of its solid shapes ([buoyancy](buoyancy.md#limits)).
- A joint node carries one joint. Bodies on a joint must both be built.
- `MESH`, `HEIGHT_FIELD` and `COMPOUND` colliders are static. Mesh and height-field shapes do not pair with each other in
  [world-free queries](collision_queries.md#limits).
- A node's scale is not applied to its body.
- The world is not thread-safe. Call it from one thread. The friction and restitution mixes run on box3d workers and
  the ranges of [`set_parallel`](#update-on-a-worker-pool) run on the application's workers.

## See also

- [Collision queries](collision_queries.md) and [reference](collision_queries_reference.md)
- [Ragdolls](ragdoll.md), [breakables](breakables.md), [cloth](cloth.md), [buoyancy](buoyancy.md)
- [Physics inspector](physics_inspector.md)
- [Large worlds](large_world.md), [serialization](serialization.md), [job pool](jobs.md)
- The package [README](../addons/c3d_physics.c3l/README.md)
