# c3d_character

A kinematic capsule character controller for c3d: module `c3d::character`, an add-on package built
on the mover primitives of the physics package (`addons/c3d_physics.c3l`, module `c3d::physics`).
It imports the standard library, core `c3d` and `c3d::physics`. Applications select it explicitly;
core and the physics package never import it.

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

## Tests and example

`python3 scripts/build.py --test` runs the `character_test` target, or directly:

```bash
c3c test character_test --path addons/c3d_character.c3l
```

`python3 scripts/build.py --example character` builds and runs the example: walk, run, jump, push
boxes, ride the platform, slide along walls, stop at steep slopes and climb the stair.
