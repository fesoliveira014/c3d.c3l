# Collision queries

`c3d::physics::collide`, in the physics package, answers collision questions about shapes that are
not in a physics world: how two posed shapes touch, how far apart they are, when a moving shape
first touches a resting one, and where a ray enters one shape. It needs no `PhysicsWorld` and no
scene. Import `c3d::physics::collide`; the package is selected as for any physics use.

## Shapes and hulls

A `Shape` is a plain value at its own origin:

- `sphere_shape(radius)`
- `capsule_shape(half_height, radius)`: the segment runs along local Y; `half_height` must be
  positive (box3d's capsule pair reports nothing for a segment shorter than one linear slop).
- `box_shape(half_extents)`
- `hull_shape(&hull)`: a convex hull cooked beforehand.

A hull is cooked once from points and owned by a `Hull`:

```c3
Hull hull = collide::create_hull(assets.geometry(rock).data.positions)!;
defer collide::destroy_hull(&hull);
Shape rock_shape = collide::hull_shape(&hull);
```

`create_hull` takes no allocator: box3d owns the allocation until `destroy_hull`. It faults
`b3::DEGENERATE_GEOMETRY` for fewer than four points, an empty slice included, or for points that
span no volume. A shape from `hull_shape` copies the cooked hull's pointer, so it stays valid
wherever the `Hull` value lives, until `destroy_hull`. Boxes allocate nothing; each query builds a
box hull on the stack.

Poses are `maths::Transform` with unit scale (within `UNIT_SCALE_TOLERANCE`, so a pose decomposed
from a world matrix qualifies). Scaled shapes are not supported: bake the scale into the shape.

## Queries

Every returned point, normal and distance is in world space.

- `manifold(a, pose_a, b, pose_b)`: up to `MAX_MANIFOLD_POINTS` touching points with their
  separation (negative while penetrating) and a normal from `a` to `b`. `count` 0 means no contact
  within box3d's speculative margin; a point inside that margin can carry a small positive
  separation. The argument order sets the normal's direction, never the points.
- `distance(a, pose_a, b, pose_b)`: closest points and the normal from `a` to `b`; distance 0 when
  the shapes overlap.
- `cast(a, pose_a, b, pose_b, translation)`: first contact when `b` moves by `translation` against
  a resting `a`. `time` is the fraction of the translation; the normal points from `a` to `b`. A
  start that already overlaps reports time 0 and a zero normal. Faults `b3::NO_HIT` on a miss.
- `time_of_impact(a, sweep_a, b, sweep_b)`: first contact of two shapes moving from their start to
  their end poses; same result rules as `cast`, including time 0 and a zero normal for an overlapped
  start. Faults `b3::NO_HIT` when they never touch.
- `hull_points(shape)`: the cooked points of a `HULL` shape, borrowed until `destroy_hull`, for drawing.
- `ray_cast(shape, pose, origin, direction, max_distance)`: nearest entry of a unit-length ray;
  `fraction` is of `max_distance`. A ray starting inside reports fraction 0 and a zero normal.
  Faults `b3::NO_HIT` on a miss.

Casts and sweeps aim at box3d's linear slop (5 mm) of overlap rather than the exact touch. When the
two shapes' radii sum to less than one slop the stop falls short of the touch; at one slop it lands
on it; above that it lies past it, by a full slop from two slops of radius on. A pose built from
`time` can therefore overlap by up to one slop.

Mesh, height field and compound shapes are world queries (`PhysicsWorld.raycast`,
`overlap_sphere`), not these.

## Names beside box3d

`collide::Sweep`, `collide::Manifold` and `collide::ManifoldPoint` share names with `b3` types. A
module that imports both `c3d::physics::collide` and `b3` writes these three qualified.

The `collision_math` example in the physics package moves one shape against another and draws the
manifold points, the closest-point segment and the swept contact.
