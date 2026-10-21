# Collision queries

The physics add-on answers geometric questions without a world: contacts, closest points, casts, time of impact and
ray casts between two shapes. `c3d::physics` owns prepared shapes and an optional shared cooking cache for them;
`c3d::physics::collide` owns the direct value API for convex shapes. Neither needs a `PhysicsWorld` or a scene. A world
answers the same questions about the bodies it holds ([world queries](physics.md#queries)). Select the physics package
as for any physics use. Details of scale, meshes, height fields and faults are in the
[reference](collision_queries_reference.md).

## Quick start

Inside a fallible function, with an `AssetStore assets` that holds a geometry `rock`:

```c3
CollisionCache cache = physics::create_collision_cache(mem, &assets, physics::default_collision_cache_desc())!;
defer physics::destroy_collision_cache(&cache)!!;

CollisionShapeDesc rock_desc = physics::default_collision_shape_desc(HULL);
rock_desc.geometry = rock;
CollisionShape rock_shape = physics::create_collision_shape(mem, &cache, rock_desc)!;
defer physics::destroy_collision_shape(&rock_shape);

CollisionShapeDesc ball_desc = physics::default_collision_shape_desc(SPHERE);
ball_desc.radius = 0.5f;
CollisionShape ball_shape = physics::create_collision_shape(mem, &cache, ball_desc)!;
defer physics::destroy_collision_shape(&ball_shape);

maths::Transform rock_pose = maths::TRANSFORM_IDENTITY;
maths::Transform ball_pose = maths::TRANSFORM_IDENTITY;
ball_pose.position = { 0, 1.2f, 0 };
collide::Distance gap = rock_shape.view().distance(rock_pose, ball_shape.view(), ball_pose)!;
```

## Concepts

- **Cache.** `CollisionCache` owns immutable cooked hull, mesh and height-field data for one borrowed `AssetStore`.
  Prepared shapes and worlds hold entries in it.
- **Owner and view.** `CollisionShape` owns prepared query state and keeps its cache in use. `CollisionShapeView`
  borrows that state until the owner is destroyed and has no destructor. Do not copy an owner to make another owner.
- **Lifetimes.** Keep the store alive through the cache's destruction. Destroy every prepared owner and every borrowing
  world before the cache. `destroy_collision_cache` faults `c3d::RESOURCE_IN_USE` and changes nothing while any owner,
  world or snapshot holder remains; a world with no bodies still borrows the cache. Successful destruction zeroes the
  owner value.
- **Units.** Set box3d's length-unit configuration before creating caches, prepared shapes or worlds, and keep it
  unchanged through their lifetimes. The size limits below are given at the default setting of one unit per metre.
- **Threads.** Cache mutation, source edits and destruction follow the scene's owner-thread ordering. Synchronize them
  against queries and simulation.
- **Poses and results.** A query pose is a `maths::Transform` with a finite unit rotation and unit scale (within
  `collide::UNIT_SCALE_TOLERANCE`, so a pose decomposed from a world matrix qualifies). Scale belongs to the shape,
  not the pose. Returned points, normals and distances are in world space, and normals point from the first shape
  toward the second. View operations allocate no memory.

## Prepare a shape

`CollisionShapeDesc` holds a `kind`, a `scale` and the dimensions or source of that kind, without body filtering,
events or material values. `default_collision_shape_desc(kind)` returns unit scale.

| `ColliderKind` | Description fields |
| --- | --- |
| `SPHERE` | `radius` |
| `CAPSULE` | `radius`, `half_height`; the segment runs along local Y with length `2 * half_height` |
| `BOX` | `half_extents` |
| `HULL` | `geometry`: a live geometry of the cache's store |
| `MESH` | `geometry`, optional `material_indices` (one per triangle) |
| `HEIGHT_FIELD` | `height_field`, optional `material_indices` (one per cell) |

`COMPOUND` returns `c3d::UNSUPPORTED`; compounds are world-query shapes. Dimensions are positive and finite. A capsule
segment must be at least one native linear slop (0.005 m by default) and box half-extents at least 0.2 slop (0.001 m).
Smaller positive values return `c3d::UNSUPPORTED` instead of accepting a native clamp. `scale` multiplies the shape's
local axes at preparation; each kind accepts a different set (see [prepared scale](collision_queries_reference.md#prepared-scale)).
`create_collision_shape` faults `c3d::INVALID_ARGUMENT`, `c3d::INVALID_ID`, `c3d::UNSUPPORTED`,
`c3d::CAPACITY_EXCEEDED`, `physics::SOURCE_UNAVAILABLE`, `b3::DEGENERATE_GEOMETRY` and `b3::INVALID_DEFINITION`
([causes](collision_queries_reference.md#faults)). A geometry id is local to its store: pass the store the cache was
created with.

## Query a pair

All operations are methods of `CollisionShapeView`, take the poses of both shapes and need non-null views.

| Method | Result |
| --- | --- |
| `contacts(pose_a, other, pose_b, output)` | Writes the complete native contact set into `output` (`CollisionContact`: `point`, `normal`, `separation`, `triangle_index`) and returns the count. |
| `distance(pose_a, other, pose_b)` | `collide::Distance`: unsigned separation, both witnesses and a normal. |
| `cast(pose_a, other, pose_b, translation_a, translation_b)` | `collide::Impact` for the two world translations. The point includes both shapes' motion at the returned fraction. |
| `time_of_impact(sweep_a, other, sweep_b)` | `collide::Impact` for two `collide::Sweep` values (start and end pose, so rotations count). |
| `ray_cast(pose, origin, direction, max_distance)` | `collide::ShapeRayHit`. `direction` is unit length and `max_distance` positive. |

- Convex pairs return at most four contact points, each with signed native separation, a normal and
  `triangle_index == NO_COLLISION_TRIANGLE`. A positive separation occurs inside the native speculative margin. An empty
  result returns zero, even with an empty output slice.
- Insufficient output returns `c3d::CAPACITY_EXCEEDED`, never a truncated prefix, and the output is unspecified.
- Casts, sweeps and rays return `b3::NO_HIT` on a miss. `distance` returns zero for overlapping shapes.
- A cast or sweep that starts inside the closing band (a few millimetres) reports time zero and a zero normal; geometric
  touching alone does not promise time zero. A ray that starts inside a convex shape reports fraction zero and a zero
  normal.
- Invalid values return `c3d::INVALID_ARGUMENT`. Finite shapes whose required bounds cannot be represented in native
  arithmetic return `c3d::UNSUPPORTED`; a large common world origin alone does not impose a cutoff.
- A mesh or height field pairs with convex shapes and with rays. Two surfaces are `c3d::UNSUPPORTED` except for rays.
  The rules for contacts, casts and rays against surfaces are in the
  [reference](collision_queries_reference.md#surface-queries).

## Direct convex queries

`c3d::physics::collide` works on plain values and needs no cache. A `Shape` is a plain value at its own origin:

- `sphere_shape(radius)`
- `capsule_shape(half_height, radius)`: the segment runs along local Y and `half_height` must be positive. box3d's
  capsule pair reports nothing for a segment shorter than one linear slop.
- `box_shape(half_extents)`: allocates nothing; each query builds a box hull on the stack.
- `hull_shape(&hull)`: a convex hull cooked beforehand.

```c3
Hull hull = collide::create_hull(assets.geometry(rock).data.positions)!;
defer collide::destroy_hull(&hull);
Shape rock_shape = collide::hull_shape(&hull);
```

`create_hull` takes no allocator: box3d owns the allocation until `destroy_hull`. It faults `b3::DEGENERATE_GEOMETRY` for
fewer than four points, an empty slice included, or points that span no volume. A shape from `hull_shape` copies the
hull's pointer, so it stays valid wherever the `Hull` value lives until `destroy_hull`. Poses are unit-scale
`maths::Transform` values; bake scale into the shape or prepare a scaled `CollisionShape`.

| Function | Result |
| --- | --- |
| `manifold(a, pose_a, b, pose_b)` | Up to `MAX_MANIFOLD_POINTS` (4) touching points with separation (negative while penetrating) and a normal from `a` to `b`. `count` 0 means no contact within the speculative margin. |
| `distance(a, pose_a, b, pose_b)` | Closest points and the normal from `a` to `b`; distance 0 when the shapes overlap. |
| `cast(a, pose_a, b, pose_b, translation)` | First contact when `b` moves by `translation` against a resting `a`. `time` is the fraction of the translation. Faults `b3::NO_HIT`. |
| `time_of_impact(a, sweep_a, b, sweep_b)` | First contact of two shapes moving from start to end pose. Faults `b3::NO_HIT`. |
| `ray_cast(shape, pose, origin, direction, max_distance)` | Nearest entry of a unit-length ray; `fraction` is of `max_distance`. Faults `b3::NO_HIT`. |
| `hull_points(shape)` | The cooked points of a `HULL` shape, borrowed until `destroy_hull`, for drawing. |

The argument order sets the normal's direction and never the points. Casts and sweeps aim at box3d's linear slop (5 mm)
of overlap rather than the exact touch. When the two shapes' radii sum to less than one slop the stop falls short of
the touch, at one slop it lands on it, and above that it lies past it. A pose built from `time` can therefore overlap
by up to one slop. The slop rule also applies to prepared convex casts and sweeps.

`collide::Sweep`, `collide::Manifold` and `collide::ManifoldPoint` share names with `b3` types. A module that imports
both `c3d::physics::collide` and `b3` writes these three qualified.

## Share cooked geometry with worlds

Pass a cache as the optional fifth argument of `create_physics_world`. It must reference the same `AssetStore`;
a mismatch returns `c3d::INVALID_ARGUMENT` without borrowing it. A world without the argument keeps a private cache.
An external cache supplies the capacity and wireframe policy, so that world's `PhysicsDesc.snapshot_capacity` and
`cache_wireframes` do not override it. `default_collision_cache_desc()` provides 256 slots with wireframes enabled; a
zero-slot cache still supports prepared primitives.

Worlds and prepared hulls, meshes and height fields reuse matching cooks. Native bodies still clone their own hull
shape data. A source edit creates a new immutable entry on the next acquisition and held older entries stay valid. A
live body adopts a source edit only after `PhysicsBody.mark_changed()`. Released CPU data does not invalidate a
matching retained cook; a missing required cook returns `physics::SOURCE_UNAVAILABLE`. Unheld stale entries may be
reclaimed. The occupancy a borrowing world reports counts the shared table; native body counts stay world-local.
`ColliderDesc` and serialization do not change: prepared pointers and native identities are never serialized.

## Example

`collision_math` (`python3 scripts/build.py --example collision_math`) prepares cached convex, mesh and height-field
owners, moves one shape against another and draws the contact points and normals, the closest-point segment, the cast
with both translations, the swept contact and a ray. Each shape has scale controls and a reflection toggle; a refused
scale or query shows its fault in the panel.

## Limits

- Prepared shapes cover spheres, capsules, boxes, hulls, meshes and height fields. Compounds are world-query shapes.
- Two surfaces (mesh or height field) do not pair, except for ray casts.
- A prepared height field never reproduces its samples exactly: its heights are quantized to 16 bits.
- Convex hulls hold at most 128 vertices, and prepared hulls at most 32 vertices per face.
- World queries cap their results at 256 overlap shapes, 128 cast hits and 64 body contacts.

## See also

- [Collision queries reference](collision_queries_reference.md)
- [Physics](physics.md) for world queries and bodies
- [Terrain](terrain.md) for height fields built from terrain, and [height-field windows](collision_queries_reference.md#height-field-windows)
