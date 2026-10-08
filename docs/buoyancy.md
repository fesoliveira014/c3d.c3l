# Buoyancy

The `c3d_physics` add-on lifts dynamic bodies out of a fluid whose surface the application installs. A
`Buoyancy` component on a node with a dynamic body receives, every fixed step, the lift of the fluid it
displaces and a linear drag, from a surface function `PhysicsWorld.set_fluid_surface` stores per world. The
physics package knows nothing about where the surface comes from: an analytic level, a tide, or the landscape
add-on's water through the adapter in [water](water.md#buoyancy). Neither package imports the other.

## Installing a surface

```c3
alias FluidSurfaceFn = fn float? (void* context, float x, float z, float step_offset);

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

- The function returns the world height of the surface over a point; an empty optional means no fluid there,
  and that cell receives nothing.
- One surface per world. A second call replaces the first; `null` removes it, and every body's
  `submerged_fraction` reads 0 from the next step. The caller keeps the context alive while it is installed.
- `step_offset` is the time from the update's first fixed step to the one being taken: step index × fixed dt.
  An application whose surface moves adds it to the frame time it stored in the context, so every step of a
  multi-step update samples its own time.
- The function runs serially inside `PhysicsWorld.update`, once per cell and step.

## The cell model

`Buoyancy` has two authored fields and one the world writes:

| Field | Meaning |
| --- | --- |
| `fluid_density` | Kilograms per cubic metre; `DEFAULT_FLUID_DENSITY` is fresh water, 1000 |
| `linear_drag` | Newton-seconds per metre on the whole body fully submerged |
| `submerged_fraction` | Written each step: the mean submersion of the body's cells, in [0, 1] |

The authored fields are not checked in the step loop, as `Wind` and `Force` are not: keep them non-negative and
finite.

- When a dynamic body is built, the world measures its solids once: `RigidBody.solid_bounds` is the body-space
  union of the tight bounds of the colliders with a density above zero, and `RigidBody.solid_volume` the sum of
  their mass over density. Zero-density colliders, the usual sensor, add neither, so a body floats at its
  mass-weighted density. Compound, height-field and mesh colliders are static only and never measured.
- Each step the box splits into `BUOYANCY_CELLS` (8) octant cells. Each cell centre goes to world space with the
  body's current pose; the surface is sampled there; the cell's fraction is
  `clamp((surface − y) / h + 0.5, 0, 1)`, with `h` the rotated cell's world height span, so a tilted body still
  submerges each cell over its full height.
- A submerged cell receives, at its centre, `(−gravity · ρ · V / 8 − v · drag / 8) · fraction`, with the
  world's `tuning.gravity` (not the body's `gravity_scale`: a scaled body is lighter, not less buoyant) and `v`
  the velocity of the body at the cell centre. A cell with fraction 0 receives nothing.
- At rest on a flat surface a body settles where its mean fraction equals `ρ_body / ρ_fluid`, whatever its
  shape.

## Rebasing the origin

`PhysicsWorld.shift_origin` moves bodies but not the surface. A `FluidSurfaceFn` that
reads world `x` and `z` must be given the shifted coordinates by the application, for
example by capturing the accumulated offset, or the body floats against a displaced
surface after the shift.

## Sleep

Applying a force wakes a sleeping body but does not reset an awake body's sleep timer, so a floating body at
rest sleeps for one step every 0.5 s and the next step's lift wakes it; its pose does not change while it
sleeps. A body with no submerged cell receives no force and no wake, and sleeps normally.

## Tests and cost

`physics_test`'s buoyancy group runs over an analytic surface: a light box settles at its density line, a
heavy one sinks, bodies out of the fluid sleep while floaters never sleep through two consecutive steps, every
sample carries its step offset, a second install replaces the first, a sphere and a box of equal volume float
alike, and a body of two colliders floats at its summed volume.

`physics.update` per fixed step on WSL (`-O3`, one thread, medians of three runs), 1 m boxes at density 600
over the water example's calm waves through the water adapter:

| Bodies | Calm waves | Choppy waves (4, 2.5 m shortest) |
| --- | ---: | ---: |
| 16 | 10.9 µs | 15.1 µs |
| 256 | 162.6 µs | 253.5 µs |
