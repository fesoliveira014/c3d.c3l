# Buoyancy

The `c3d_physics` add-on lifts dynamic bodies out of a fluid the application installs. A `Buoyancy` component on a node
with a dynamic body receives, every fixed step, the lift of the fluid it displaces and the drag of the fluid moving past
it. The fluid comes from a surface function (`PhysicsWorld.set_fluid_surface`) or a sampler that also reports the
fluid's velocity (`PhysicsWorld.set_fluid_sampler`), stored per world. The physics package knows nothing about where
the fluid comes from: an analytic level, a tide, a current, or the landscape add-on's water through `water::fluid_sample`
([water](water.md#buoyancy)). Neither package imports the other.

## Quick start

A pond whose surface is a flat disc, and a raft that floats on it. `Pond` is application data:

```c3
fn float? pond_level(
    void* context,
    float x,
    float z,
    float step_offset,
) {
    Pond* pond = context;
    if (x * x + z * z > pond.radius * pond.radius) return NOT_FOUND~;
    return pond.level;
}

physics.set_fluid_surface(&pond_level, &pond);
scene.add(raft, (Buoyancy){ .fluid_density = physics::DEFAULT_FLUID_DENSITY, .linear_drag = 3000 });
```

A moving fluid reports its velocity beside the height:

```c3
fn float? river_sample(
    void* context,
    float x,
    float z,
    float step_offset,
    Vec3* velocity,
) {
    River* river = context;
    *velocity = river.flow;
    return river.level;
}

physics.set_fluid_sampler(&river_sample, &river);
```

## Install a fluid

`FluidSurfaceFn` is `fn float? (void* context, float x, float z, float step_offset)`. `FluidSampleFn` adds a trailing
`Vec3* velocity`.

- The function returns the world height of the surface over a point. An empty optional means no fluid there, and that
  cell receives nothing. A sampler writes the fluid's velocity in metres per second into `velocity`; the value is
  unspecified when the optional is empty. A surface reports zero velocity.
- One fluid per world. Each install, of either kind, replaces the previous one. Passing `null` removes it, and every
  body's `submerged_fraction` reads 0 from the next step. The caller keeps the context alive while it is installed.
- `step_offset` is the time from the update's first fixed step to the one being taken: step index times fixed dt. An
  application whose fluid moves adds it to the frame time it stored in the context, so every step of a multi-step update
  samples its own time.
- The function runs serially inside `PhysicsWorld.update`, once per cell and step.
- The application sets the context (the frame time, a retaken `SurfaceView`) before `PhysicsWorld.update`. After a water
  update or an origin shift it takes the water view again ([water](water.md#buoyancy)).

## The cell model

`Buoyancy` has three authored fields and one the world writes:

| Field | Meaning |
| --- | --- |
| `fluid_density` | Kilograms per cubic metre; `DEFAULT_FLUID_DENSITY` is fresh water, 1000 |
| `linear_drag` | Newton-seconds per metre on the whole body fully submerged |
| `drag_coefficient` | Dimensionless C_d on the solid bounds' projected area; 0 keeps only linear drag |
| `submerged_fraction` | Written each step: the mean submersion of the body's cells, in [0, 1] |

The authored fields are not checked in the step loop, as `Wind` and `Force` are not: keep them non-negative and finite.

- When a dynamic body is built, the world measures its solids once: `RigidBody.solid_bounds` is the body-space union of
  the tight bounds of the colliders with a density above zero, and `RigidBody.solid_volume` the sum of their mass over
  density. Zero-density colliders add neither, so a body floats at its mass-weighted density. Compound, height-field and
  mesh colliders are static only and never measured.
- Each step the box splits into `BUOYANCY_CELLS` (8) octant cells. Each cell centre goes to world space with the body's
  current pose and the fluid is sampled there. The cell's fraction is `clamp((surface - y) / h + 0.5, 0, 1)`, with `h`
  the rotated cell's world height span, so a tilted body still submerges each cell over its full height.
- A submerged cell receives, at its centre, `-gravity * rho * V / 8 * fraction` of lift, with the world's
  `tuning.gravity` (not the body's `gravity_scale`: a scaled body is lighter, not less buoyant), and the drag below. A
  cell with fraction 0 receives nothing.
- At rest on a flat surface a body settles where its mean fraction equals `rho_body / rho_fluid`, whatever its shape.

## Drag

With `v_rel = v - v_fluid`, the velocity of the body at the cell centre relative to the fluid there, and `A(d)` the area
of the solid bounds projected on the plane perpendicular to `d` (the sum of the areas of the box's three face pairs,
each weighted by `|d . axis|` of the body axis normal to it), a cell's drag is

```text
F = -(linear_drag / 8 + 1/2 * rho * C_d * A(v_rel_hat) / 8 * |v_rel|) * v_rel * fraction
```

- Each cell carries an eighth of the body's projected area, so a fully submerged body moving at one velocity feels
  `1/2 * rho * C_d * A * |v| * v`. `C_d` is the usual whole-body coefficient on the bounds' projected area. A cube's is
  about 1.05. A partly submerged body scales with the submerged fraction.
- The force is applied at the cell centre, so a fluid moving past a body also turns it.
- The magnitude of `F` is limited to `m_cell * |v_rel| / fixed_dt`, with `m_cell` one eighth of the body's mass, so one
  explicit step cannot reverse the cell's velocity relative to the fluid. The limit binds when
  `(linear_drag + 1/2 * rho * C_d * A(v_rel_hat) * |v_rel|) * fraction > mass / fixed_dt`, so with `C_d > 0` it also binds
  at high relative speed. With linear drag alone and a fully submerged body, that is `linear_drag` above
  `mass / fixed_dt` (60 N s/m for a 1 kg body at 60 Hz, 36,000 N s/m for 600 kg); below that, it never changes such a
  body. Where it binds, the drag is weaker than the formula states.
- The terminal speed of a body sinking through a fluid on quadratic drag alone is
  `sqrt(2 (m - rho V) g / (rho C_d A))`, with `A` the bounds' projected area along the fall.
- The fluid's velocity enters only through the relative velocity: a body with `linear_drag = 0` and
  `drag_coefficient = 0` feels no current.

## Sleep

A submerged cell applies its force with `wake: true`. Applying a force wakes a sleeping body but does not reset an awake
body's sleep timer, so a floating body at rest sleeps for one step every 0.5 s and the next step's lift wakes it; its pose
does not change while it sleeps. A body with no submerged cell receives no force and no wake, and sleeps normally.

## Rebase the origin

`PhysicsWorld.shift_origin` moves bodies but not the fluid. A `FluidSurfaceFn` or `FluidSampleFn` that reads world `x`
and `z` must receive the shifted coordinates from the application, for example by capturing the accumulated offset, or
the body floats against a displaced surface after the shift. A `SurfaceView` of the water add-on is taken again after the
shift. The full order is in [origin rebasing](origin_rebasing.md).

## Limits

- One fluid per world.
- Each body floats by the bounds of its density-carrying box, hull, sphere and capsule colliders. A body with no such collider
  has no solid volume and receives nothing.
- The fluid is sampled at eight points per body and step, which is coarse over a body much longer than a wave.
- The explicit step limit weakens drag on light bodies at high relative speed.

## See also

- [Physics](physics.md) for bodies, forces and tuning
- [Water](water.md#buoyancy) for `water::fluid_sample`
- [Large worlds](large_world.md)
