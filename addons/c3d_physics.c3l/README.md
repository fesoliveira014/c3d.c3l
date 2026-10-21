# c3d_physics

Rigid-body physics for c3d. Module `c3d::physics`, package `c3d_physics`, built on [box3d](https://github.com/erincatto/box3d)
through `lib/box3d.c3l` (module `b3`). Bodies are ECS data bound to scene nodes; the world steps at a fixed rate with
interpolated write-back, reports events and answers queries. Core does not import the package and carries no physics
feature flag.

## What it provides

- Rigid bodies and colliders (sphere, capsule, box, hull, mesh, height field, compound), surface materials, filters,
  joints, `Wind`, `Force` and `Buoyancy` components, events, scene queries, recording and replay, debug draw.
  [Physics guide](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/physics.md).
- World-free collision queries on prepared shapes (`CollisionShape`, `CollisionCache` in `c3d::physics`) and the direct
  `c3d::physics::collide` API.
  [Collision queries](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/collision_queries.md).
- Ragdolls with physical get-up recovery.
  [Ragdolls](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/ragdoll.md).
- Pre-fractured pieces joined by breakable welds and anchors.
  [Breakables](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/breakables.md).
- Position-based cloth over owned geometry copies, with collisions, tearing and crowds (`c3d::physics::cloth`).
  [Cloth](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/cloth.md).
- Buoyancy against a fluid the application installs.
  [Buoyancy](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/buoyancy.md).

## Select the package

List `c3d_physics` and `b3` with c3d's own dependencies in the application's `project.json`
([release](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/release.md#using-a-release) lists the packages and their
extras). Applications that use cloth compile with `--fp-math=strict`.

With the `C3D_PHYSICS_SERIAL` feature, also select `c3d_serial` and call `physics::register_serial_codecs()` beside
`physics::register_physics(scene)`. Without it the package has no serialization dependency
([serialization](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/serialization.md#physics-adapter)).

## Quick start

Inside a fallible function, with a `Scene scene` and an `AssetStore assets` already created:

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
ColliderDesc shape = physics::default_collider_desc(BOX);
shape.half_extents = { 0.5f, 0.5f, 0.5f };
world.add_body(crate, physics::default_body_desc(DYNAMIC), (&shape)[:1])!;

// each frame
scene.update_world();
world.update(delta);
scene.flush_removals();
scene.update_world();
```

`crate` is a mesh node. Destroy the world before the scene and the asset store.

## Boundaries

- `c3d::physics` imports the standard library, core (`c3d`) and `b3`. It never imports `gpu`, `sdl` or `imgui`, and
  creates no GPU object.
- `c3d::physics::cloth` imports the standard library, core and `c3d::physics`, not `b3`. `c3d::physics::collide` imports
  the standard library, `c3d::maths` and `b3` only.
- Under `C3D_PHYSICS_SERIAL`, `src/serial/` imports `c3d::serial`. The package never imports `c3d_job`; the `cloth`,
  `breakable` and `physics_components` examples select it to drive `PhysicsWorld.set_parallel`.
- `c3d_character` and `c3d_physics_gui` build on this package; it imports neither.

## Targets

| Target | Kind |
| --- | --- |
| `physics_test`, `physics_serial_test`, `physics_serial_policy_test` | CPU tests, run by `python3 scripts/build.py --test` |
| `cloth_acceptance` in `test/gpu` | Manual Vulkan acceptance of cloth publication and vertex motion |
| `physics`, `physics_instanced`, `physics_components`, `vehicle`, `ragdoll`, `collision_math`, `breakable`, `cloth` | Examples; `python3 scripts/build.py --example <name>` |

```bash
c3c test physics_test --path addons/c3d_physics.c3l
```

## Documentation

[Physics](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/physics.md),
[collision queries](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/collision_queries.md) and its
[reference](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/collision_queries_reference.md),
[ragdolls](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/ragdoll.md),
[breakables](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/breakables.md),
[cloth](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/cloth.md) and its
[reference](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/cloth_reference.md),
[buoyancy](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/buoyancy.md),
[physics inspector](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/physics_inspector.md).
