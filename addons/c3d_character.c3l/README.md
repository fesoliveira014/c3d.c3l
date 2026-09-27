# c3d_character

A kinematic capsule character controller for c3d: module `c3d::character`, an add-on package built
on the mover primitives of the physics package (`addons/c3d_physics.c3l`, module `c3d::physics`).
It imports the standard library, core `c3d` and `c3d::physics`, and `c3d::nav` under the
`C3D_CHARACTER_NAV` feature. Applications select it explicitly; core, the physics package and the
nav package never import it.

A `Character` component on a node describes the capsule. `create_character_system` installs the
physics world's mover pass, which moves every character inside the world's fixed steps: slide along
the gathered planes, climb steps up to `step_height`, stop at slopes steeper than
`max_slope_degrees`, ride moving ground, and, with `push_bodies`, drive a kinematic body that shoves
dynamic bodies the capsule's filter mask leaves out. The pass writes the node's position only; the
rotation stays the application's.

The node origin is the capsule's lowest point, the feet: `add_character` reads the feet from the
node, `teleport_character` takes the feet, and the pass writes the feet. `Character.previous` and
`Character.current` hold the capsule center, `half_height + radius` above the feet. A capsule mesh
is a child node raised by that offset; a model authored at the feet sits on the node itself.

## Frame order

```c3
scene.update_world();          // world matrices for kinematic targets and new bodies
scene.move_character(node, desired_velocity);
physics.update(delta);         // builds bodies, runs the fixed steps and the characters, writes nodes
scene.update_world();          // world matrices of the moved nodes
```

## Crowd-driven characters

With the `C3D_CHARACTER_NAV` feature, `src/nav/` binds a character to a crowd agent of the nav
package (`addons/c3d_nav.c3l`, module `c3d::nav`). The feature imports `c3d::nav`, so a consumer
that enables it also lists `c3d_nav` in its dependencies; without the feature the package never
resolves `c3d::nav`.

`register_nav_driven` registers the `NavDriven` component. `Scene.add_nav_driven` marks a node
that carries a `Character` and a `NavAgent`: the agent plans and steers but never writes the node,
and `drive_characters` copies the agent's velocity into `Character.desired` and its off-mesh
traversal into `NavDriven.traversal` every frame. The character then collides with every physics
body, including bodies the navmesh does not know, and crosses an off-mesh connection along the
crowd's traversal without sweeping. `Scene.remove_nav_driven` returns the node to the application
and stops the character. The package writes no rotation; an application that wants its characters
to face their motion turns each node toward `Character.velocity` at a limited rate.

```c3
scene.update_world();                          // world matrices; crowd_update reads driven nodes
nav::crowd_update(scene, &crowd, dt);          // plans and steers every agent
character::drive_characters(scene, &crowd);    // agent velocity and traversal into the characters
physics.update(dt);                            // steps the characters, writes their nodes
scene.update_world();
```

## Tests and example

`python3 scripts/build.py --test` runs the `character_test` and `character_nav_test` targets, or
directly:

```bash
c3c test character_test --path addons/c3d_character.c3l
c3c test character_nav_test --path addons/c3d_character.c3l
```

`python3 scripts/build.py --example character` builds and runs the example: walk, run, jump, push
boxes, ride the platform, slide along walls, stop at steep slopes and climb the stair.
