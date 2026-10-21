# c3d_character

A kinematic capsule character controller for c3d. Module `c3d::character`, package `c3d_character`, built on the mover
primitives of the physics package (`addons/c3d_physics.c3l`, module `c3d::physics`). A `Character` component on a node
describes the capsule. `create_character_system` installs the physics world's mover pass, which moves every character
inside the world's fixed steps: it slides along the gathered planes, climbs steps up to `step_height`, stops at slopes
steeper than `max_slope_degrees`, rides moving ground and, with `push_bodies`, drives a kinematic body that shoves
dynamic bodies the capsule's filter mask leaves out. The pass writes the node's position only; the rotation stays the
application's.

## Package and boundaries

- `c3d::character` imports the standard library, core (`c3d`) and `c3d::physics`. It never imports `b3`, `gpu`, `sdl` or
  `imgui`.
- Under `C3D_CHARACTER_NAV`, `src/nav/` adds the crowd binding and imports `c3d::nav`. A consumer that enables the feature
  also selects `c3d_nav`; without it the package never resolves `c3d::nav`.
- Under `C3D_CHARACTER_SERIAL`, `src/serial/` imports `c3d::serial`. It needs `C3D_PHYSICS_SERIAL`, and navigation-enabled
  serialization also needs `C3D_NAV_SERIAL`. Consumers select `c3d_serial`.
- Core, the physics package and the nav package never import it. Select it with `c3d_character`, `c3d_physics` and `b3`
  ([release](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/release.md#using-a-release)).

## Quick start

Inside a fallible function, with a physics world created and `register_physics` called:

```c3
character::register_character(&scene)!;
CharacterSystem system = character::create_character_system(mem, &world, &scene)!;
defer character::destroy_character_system(&system);

scene.update_world();
scene.add_character(player, character::default_character_desc())!;

// each frame
scene.update_world();
scene.move_character(player, desired_velocity);
world.update(delta);
scene.update_world();
```

`player` is a node whose origin is at the character's feet. A world carries one mover pass, so create one system per
world, and destroy the system before the world.

## Concepts

- **Feet origin.** The node origin is the capsule's lowest point. `add_character` reads the feet from the node,
  `teleport_character` takes the feet and the pass writes the feet. `Character.previous` and `Character.current` hold the
  capsule center, `half_height + radius` above the feet. A capsule mesh is a child node raised by that offset; a model
  authored at the feet sits on the node itself.
- **Mover pass.** The pass reads `Character.desired` (horizontal intent) in each fixed step and writes the node position
  at the end of the update, interpolated between the last two steps.
- **Push body.** With `push_bodies`, `add_character` also authors a kinematic `PhysicsBody` with one capsule collider on
  the node. It shoves the dynamic bodies that `CharacterDesc.filter.mask` leaves out of the capsule's own collisions.
- **Ground.** `Character.grounded`, `ground_normal` and `ground` report what the last step stood on. Moving ground carries
  the character.

`CharacterDesc` fields:

| Field | Default | Meaning |
| --- | --- | --- |
| `radius` | 0.4 m | Capsule radius. Positive. |
| `half_height` | 0.6 m | Half length of the capsule segment along world Y. Positive. |
| `step_height` | 0.35 m | Highest ledge climbed in one move. |
| `max_slope_degrees` | 50 | Steeper planes are walls. |
| `skin` | 0.005 m | Gap kept between the capsule and every surface. |
| `push_bodies` | false | Carry the kinematic push body. |
| `filter` | `FILTER_ALL` | `mask`: what the capsule collides with; `category` and `group`: the push body's shape. |

## Use a character

| Call | Effect |
| --- | --- |
| `Scene.add_character(node, desc)` | Authors the character. Faults `CHARACTER_EXISTS`, `physics::BODY_EXISTS`. |
| `Scene.remove_character(node)` | Removes the character and its push body. |
| `Scene.move_character(node, desired_velocity)` | Sets the horizontal intent; the last call before a step wins. |
| `Scene.jump_character(node, speed)` | Launches upward on the next step when grounded; dropped in the air. |
| `Scene.teleport_character(node, position)` | Moves the capsule without sweeping and writes the node immediately. `position` is the feet. |
| `Scene.set_character_desc(node, desc)` | Replaces the description in place. |
| `CharacterSystem.debug_draw(sink, options)` | Appends capsules, gathered planes and ground normals to a debug sink. |

### Change a character

`set_character_desc` is the way to change a description after `add_character`. It keeps the feet of both poses, so the
node does not move, and keeps the velocity, the intent and the ground. It adds or removes the push body when
`push_bodies` changes, and rewrites the push body's capsule and filter (category and group) when those change, which
rebuilds the body on the next update. Turning `push_bodies` on over a `PhysicsBody` the application added faults
`physics::BODY_EXISTS` and changes nothing. The step reads every description field each fixed step, so a direct write of
`step_height`, `max_slope_degrees` or `skin` works, but a direct write of `radius`, `half_height`, `filter` or
`push_bodies` moves the feet or leaves the push body stale. A capsule that grows into geometry is pushed out by the next
step's collide pass.

### Root motion

`Scene.move_character_root_motion(node, delta, dt)` converts an animation delta into horizontal world velocity and
authored facing, and leaves position to the physics mover. The node carries `Character`, world transforms are current
and `dt` is finite and positive. The delta is in the node's frame: if the animator belongs to a model child with a
different orientation or scale, convert the delta first. Consume each delta once.

```c3
anim::update(&assets, &scene, dt);
scene.update_world();
if (dt > 0) scene.move_character_root_motion(player, animator.root_motion, dt);
world.update(dt);
scene.update_world();
```

Parent-relative and world-space character nodes are supported. Turning assumes upright positive uniform scale. A
nav-driven character instead uses its velocity to choose a blend-space parameter; choose one velocity writer per
character per frame.

### Crowd-driven characters

With `C3D_CHARACTER_NAV`, `register_nav_driven` registers the `NavDriven` component and `Scene.add_nav_driven(node)`
marks a node that carries a `Character` and a `NavAgent` (faults `NAV_DRIVEN_EXISTS`, `NO_NAV_AGENT`). The agent plans
and steers but never writes the node. `drive_characters(&scene, &crowd)` copies the agent's velocity into
`Character.desired` and its off-mesh traversal into `NavDriven.traversal`. The character collides with every physics
body, including bodies the navmesh does not know, and crosses an off-mesh connection along the crowd's traversal
without sweeping. `Scene.remove_nav_driven` returns the node to the application and stops the character. The package
writes no rotation.

```c3
scene.update_world();
nav::crowd_update(&scene, &crowd, dt);
character::drive_characters(&scene, &crowd);
world.update(dt);
scene.update_world();
```

## Rebase the origin

`scene.shift_characters(offset)` subtracts the offset from each character's `previous`, `current` and mover plane points
(`offset.y == 0`). Call it after `world.shift_origin(&scene, offset)`, which moves the kinematic push bodies, and before
the next `update`. Grounding and velocity are kept. Under `C3D_CHARACTER_NAV` it also shifts the points of each
`NavDriven.traversal`; the crowd and navmesh have their own shift functions. The full order is in
[origin rebasing](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/origin_rebasing.md).

## Serialization

With `C3D_CHARACTER_SERIAL` and `C3D_PHYSICS_SERIAL`, call `character::register_serial_codecs()`. A `Character` saves its
description and restores at the saved node pose; velocity, intent, contact and jump state restart. See
[serialization](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/serialization.md#character-adapter).

## Targets

| Target | Kind |
| --- | --- |
| `character_test`, `character_nav_test` | CPU tests without and with `C3D_CHARACTER_NAV` |
| `character_serial_test`, `character_nav_serial_test`, `character_serial_policy_test`, `character_nav_serial_policy_test` | CPU tests of the serialization adapter |
| `character`, `character_nav`, `rebase_bench` | Examples; `python3 scripts/build.py --example character` |

All tests run in `python3 scripts/build.py --test`. `character` demonstrates walking, running, jumping, pushing boxes,
riding a platform, sliding along walls, stopping at steep slopes and climbing stairs. `character_nav` sends driven
characters across a nav level while the player walks among them.

## Documentation

[Physics](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/physics.md) for the world and mover primitives,
[animation](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/animation.md) for root motion and
[large worlds](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/large_world.md).
