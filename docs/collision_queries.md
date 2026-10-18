# Collision queries

The physics package provides world-free collision queries and scene-bound world queries.
`c3d::physics` owns prepared shapes and an optional shared cooking cache. The existing
`c3d::physics::collide` value API provides direct convex operations and their result types.
Neither world-free API needs a `PhysicsWorld` or a scene. Select the physics package as for
any physics use.

## Prepared queries

`CollisionCache` owns immutable cooked data for one borrowed `AssetStore`.
`CollisionShape` owns prepared query state and keeps its cache in use; `CollisionShapeView`
borrows that state until the owner is destroyed. Keep the store alive through cache destruction,
and destroy every owner and borrowing world before destroying the cache. Do not copy owner
values to create another owner. Set box3d's length-unit configuration before creating caches,
prepared shapes or worlds, and keep it unchanged through their lifetimes.
Cache mutation, source edits and destruction follow existing owner-thread ordering; callers
synchronize them against queries and simulation.

Inside a fallible function:

```c3
CollisionCache cache = physics::create_collision_cache(mem, &assets, physics::default_collision_cache_desc())!;
defer physics::destroy_collision_cache(&cache)!!;
CollisionShapeDesc desc = physics::default_collision_shape_desc(physics::ColliderKind.HULL);
desc.geometry = rock;
CollisionShape shape = physics::create_collision_shape(mem, &cache, desc)!;
defer physics::destroy_collision_shape(&shape);
CollisionShapeView view = shape.view();
```

`CollisionShapeDesc` contains scale and geometry/source values, without body filtering, events,
density, friction or restitution. Preparation supports `SPHERE`, `CAPSULE`, `BOX`, `HULL` and
`MESH`. Supply positive finite dimensions, or a live hull or mesh `geometry` from the cache's store.
The capsule segment is local Y, with length `2 * half_height`; it must be at least one native
linear slop. Box half-extents must be at least `0.2 * native linear slop`. At the default native
unit setting these limits are 0.005 and 0.001 respectively. Smaller positive values return
`UNSUPPORTED` instead of accepting native clamping. `HEIGHT_FIELD` and `COMPOUND` currently
return `UNSUPPORTED`.

### Prepared scale

`scale` applies in the shape's local axes when the shape is prepared. Query poses stay rigid.
A zero or nonfinite component returns `INVALID_ARGUMENT` before any native call. The limits
above apply to the scaled dimensions; scaled values whose arithmetic overflows or underflows
return `DEGENERATE_GEOMETRY`.

| Kind | Accepted scale | `UNSUPPORTED` |
| --- | --- | --- |
| `SPHERE` | components of equal magnitude; any sign pattern | unequal magnitudes |
| `CAPSULE` | components of equal magnitude; any sign pattern | unequal magnitudes, scaled segment below the limit |
| `BOX` | any diagonal scale; half-extents multiply by the magnitudes | a scaled half-extent below the limit |
| `HULL` | any diagonal scale, including mirrored | a magnitude below 0.01 |
| `MESH` | any diagonal scale, including mirrored | a magnitude below 0.01 |

A mirrored sphere, capsule or box is the same shape as the unmirrored one. A mirrored hull keeps
outward-facing normals, and a mirrored mesh keeps its front faces.

A scaled hull is cooked once from the unit hull with the scale baked into its points; queries
never scale at query time. The scaled cook is a separate cache entry keyed by the geometry
revision and the exact scale components. Matching requests share the entry,
and any different component creates another one. The entry for unit scale is the one worlds use,
and bodies are unaffected by scaled entries. A scaled hull that is not cached yet can occupy two
slots, its unit cook and its scaled cook, and the unit cook stays cached afterwards. A rejected
preparation releases what it held and leaves entries that bodies use valid. The hull limits below
apply to the scaled cook.

Hull preparation retains the native cooked hull, with at most 128 vertices. Query owners admit
at most 32 vertices per face so native contact clipping stays within its fixed scratch capacity;
exceeding that limit returns `CAPACITY_EXCEEDED`. This limit does not narrow ordinary body
creation. Nonfinite authored values return `INVALID_ARGUMENT`; degenerate or unrepresentable
represented geometry is refused. A geometry ID is local to its store: callers must supply its
originating store, because equal numeric IDs from different stores cannot establish provenance.
New hull cooks also check source arithmetic and the native work-allocation count limit before
calling box3d. Matching retained cooks remain usable after source CPU data is released.

All view operations allocate no memory. Poses use finite unit rotations and unit scale within
`collide::UNIT_SCALE_TOLERANCE`. Invalid values return `INVALID_ARGUMENT`; unsupported finite
scale or unrepresentable derived query arithmetic returns `UNSUPPORTED`. Returned points,
normals and distances are in world space. Normals point from the first shape toward the second.
Admission uses conservative bounds on relative geometry and motion for native arithmetic.
A finite prepared shape can therefore return `UNSUPPORTED` for a query whose required bounds
cannot be represented; a large common world origin alone does not impose a cutoff.

- `contacts(pose_a, other, pose_b, output)` writes the complete native reduced convex manifold
  and returns its count. There are at most four points, each with signed native separation,
  a normal and `triangle_index == NO_COLLISION_TRIANGLE`. Positive separation can occur inside
  the native speculative margin. An empty result returns zero, including with an empty output
  slice. Insufficient output returns `CAPACITY_EXCEEDED`; output contents are unspecified on
  failure. There is no successful truncated prefix.
- `distance(pose_a, other, pose_b)` returns `collide::Distance`: unsigned separation, world
  witnesses and a normal. Overlap returns zero; native zero-distance witnesses need not coincide.
- `cast(pose_a, other, pose_b, translation_a, translation_b)` accepts both world translations
  and returns `collide::Impact`. Its point includes both shapes' motion at the returned fraction.
- `time_of_impact(sweep_a, other, sweep_b)` accepts `collide::Sweep` values with both translations
  and rotations, and returns `collide::Impact`.
- `ray_cast(pose, origin, direction, max_distance)` returns `collide::ShapeRayHit`. Direction is
  unit length and the maximum distance is positive. A ray starting inside a convex shape returns
  fraction zero and a zero normal.

Casts, sweeps and rays return `b3::NO_HIT` on a miss. An initial-band translational cast hit has
time zero and a zero normal. Convex `time_of_impact` retains the native normal for a HIT, including
a possible time-zero hit; its native OVERLAPPED path returns a zero normal. Time zero alone does
not determine the normal. Geometric touching alone does not promise time zero. The slop behavior
described below also applies to prepared convex casts and sweeps.

### Prepared meshes

A `MESH` description names a geometry whose positions, with its indices or consecutive position
triples when it has none, are the surface. `material_indices` is optional, holds one index per
triangle and is part of the cooked entry's key. Before a new entry is cooked, a nonfinite position,
an index outside the positions, an index count that is not a multiple of three or a material index
count that differs from the triangle count returns `INVALID_ARGUMENT`, and counts past the native
signed 32-bit range return `CAPACITY_EXCEEDED`.

The native cook drops triangles whose area is below 0.01 times the squared linear slop, which is
2.5e-7 at the default unit setting. The view describes the retained surface, and a geometry with no
retained triangle returns `DEGENERATE_GEOMETRY`. Every preparation reads the retained surface
through the view's scale, including one that reuses an entry a body cooked. A scaled vertex that is
not finite or a scaled triangle without area returns `DEGENERATE_GEOMETRY`, and a tree taller than
256 levels returns `CAPACITY_EXCEEDED`. This check needs no CPU arrays, so an owner can be prepared
from an entry that a body cooked after the arrays were released.

The cooked entry is unscaled and keyed by geometry, revision and material index content. Owners of
any scale and bodies share it, and the scale lives on the view. A source edit creates a new entry
on the next acquisition; owners that hold the old entry keep it. A rejected preparation releases
what it held and does not affect bodies that use the same entry. Queries never cook, allocate or
build a broadphase.

| Pair | Contacts | Distance | Cast | Sweep | Ray |
| --- | --- | --- | --- | --- | --- |
| convex and mesh, either order | yes | yes | yes, either or both moving | fixed orientations | against the mesh |
| mesh and mesh | `UNSUPPORTED` | `UNSUPPORTED` | `UNSUPPORTED` | `UNSUPPORTED` | against either |

Convex means sphere, capsule, box or hull; convex pairs keep their native four-point manifold.

- **Contacts.** Every native point of every triangle within the speculative margin is reported with
  the normal of that triangle's contact, from the first shape toward the second, and the triangle's
  `triangle_index` in the cooked entry. The index is meaningful only for the entry the owner holds; points are neither
  deduplicated, welded nor sorted. Separation is native, so it can be positive inside the margin of
  four linear slops (0.02 at the default unit setting), and a negative value is a local penetration
  measure, not a signed distance to a volume. A triangle reports nothing for a shape behind its front
  face: a sphere is tested by its centre, a capsule by its segment midpoint and a hull by its
  centroid with one slop of tolerance. Reversing the arguments reverses every normal and leaves the
  points and separations unchanged.
- **Contact storage.** Triangle contacts stream into the caller's output. Each triangle and hull pair
  passes through a fixed scratch of 64 points, 1,536 bytes of stack, and every native point is copied
  to the output or the call returns `CAPACITY_EXCEEDED`. No truncated prefix is returned, output
  contents are unspecified after a failure, and an empty output succeeds only when nothing touches.
  The first failure is kept and later triangles write nothing.
- **Distance.** The result is unsigned, zero means the shapes overlap, and the whole retained surface
  is measured, so the nearest triangle can lie outside the other shape's bounds. The normal is the
  native one where it is defined and zero otherwise. A closed mesh has no inside: a shape wholly
  inside it reports the distance to the surface. Reversing the arguments swaps the witnesses and
  reverses the normal.
- **Casts.** The cast runs in the mesh's starting frame with the convex shape moving by the relative
  translation, so either shape or both can move. The returned point is the witness at the returned
  time, and the mesh's own translation times that time is added to it once. The shapes close to a
  core distance of `max(slop, radius_sum - slop)`, 5 mm at the default unit setting for a zero
  radius sum, with a tolerance of a quarter slop, and a start inside that band is a hit at time zero
  with a zero normal. Touching alone does not promise time zero. A cast never encroaches, and a miss
  returns `b3::NO_HIT`. Mesh casts reach a triangle from either side.
- **Sweeps.** A sweep with fixed orientations is the translational cast between the start poses.
  Rotations that differ only by quaternion sign are unchanged; a change of either orientation
  returns `UNSUPPORTED`.
- **Rays.** A ray hits front faces only and reports the geometric normal of the hit triangle. The
  fraction lies strictly between zero and one: an origin on the surface, a hit exactly at the maximum
  distance, and a coplanar or back-facing ray all return `b3::NO_HIT`.
- **Admission.** Relative transforms, translations and proxy bounds must be finite, and the convex
  higher-order bounds apply to meshes through their scaled bounds. An unrepresentable query returns
  `UNSUPPORTED`.

### Sharing cooked geometry with worlds

Pass an optional fifth `cache` argument to `create_physics_world`. The cache must reference the
exact same `AssetStore`; a mismatch returns `INVALID_ARGUMENT` without borrowing it. A world
without that argument retains its private cache. An external cache supplies capacity and
wireframe policy, so that world's `PhysicsDesc.snapshot_capacity` and `cache_wireframes` do
not override it. `default_collision_cache_desc()` provides 256 slots with wireframes enabled;
a zero-slot cache still supports prepared primitives.

Worlds, prepared hulls and prepared meshes reuse matching source/revision cooks. Native bodies still clone their
own hull shape data. A source edit creates a new immutable entry on the next acquisition; held
older entries remain valid. As before, a live body adopts source edits only after
`PhysicsBody.mark_changed()` requests a rebuild. Released CPU data does not invalidate a matching
retained cook; a missing required cook returns `SOURCE_UNAVAILABLE`. Unheld stale entries may be
reclaimed. Cache occupancy reported by a borrowing world's diagnostics counts the shared table,
while native body counts remain world-local.

`destroy_collision_cache` returns `RESOURCE_IN_USE` unchanged while any world, prepared owner
or snapshot holder remains. A world with no bodies still borrows the cache. Successful cache and
shape destruction zero their owner values. `ColliderDesc` and serialization remain unchanged;
prepared pointers and native identities are not serialized.

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
from a world matrix qualifies). Scaled shapes are not supported here: bake the scale into the shape,
or prepare a scaled `CollisionShape`.

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
  their end poses. A time-zero HIT can retain a defined native normal; the native OVERLAPPED path
  returns time zero with a zero normal. Faults `b3::NO_HIT` when they never touch.
- `hull_points(shape)`: the cooked points of a `HULL` shape, borrowed until `destroy_hull`, for drawing.
- `ray_cast(shape, pose, origin, direction, max_distance)`: nearest entry of a unit-length ray;
  `fraction` is of `max_distance`. A ray starting inside reports fraction 0 and a zero normal.
  Faults `b3::NO_HIT` on a miss.

Casts and sweeps aim at box3d's linear slop (5 mm) of overlap rather than the exact touch. When the
two shapes' radii sum to less than one slop the stop falls short of the touch; at one slop it lands
on it; above that it lies past it, by a full slop from two slops of radius on. A pose built from
`time` can therefore overlap by up to one slop.

Height field and compound shapes are world queries (`PhysicsWorld.raycast`, `overlap_sphere`), not
these. A mesh is prepared as a `CollisionShape` and queried through its view.

## World queries

`PhysicsWorld` answers the same questions about the bodies it holds, in the caller's allocator:

- `raycast(origin, direction, max_distance)`: the closest body along a ray.
- `overlap_sphere(allocator, center, radius)`: the nodes whose shapes overlap a sphere, each once, at most
  `MAX_OVERLAP_SHAPES` (256) shapes.
- `overlap_aabb(allocator, bounds)`: the nodes with a shape whose bounds overlap the box, each once. This is
  box3d's broad phase: a shape whose bounds touch the box counts even if the shape does not. At most
  `MAX_OVERLAP_SHAPES` shapes.
- `cast_shape(allocator, shape, translation)`: every shape a moving sphere, capsule or box would touch, nearest
  first, at most `MAX_CAST_HITS` (128).
- `contact_points(allocator, node)`: the points where the node's body touched others in the last step, from
  at most `MAX_BODY_CONTACTS` (64) contacts, with the normal from the node toward the other body. box3d keeps
  speculative points, so a point may be slightly separated.

Results past a cap are dropped.

## Names beside box3d

`collide::Sweep`, `collide::Manifold` and `collide::ManifoldPoint` share names with `b3` types. A
module that imports both `c3d::physics::collide` and `b3` writes these three qualified.

The `collision_math` example prepares cached convex and mesh owners, moves one shape against
another, and draws the contact points and normals, the closest-point segment, the cast with both
translations, the swept contact and a ray. Each shape has scale controls, uniform for the sphere and
capsule and per axis for the box, hull and mesh, and a reflection toggle. A refused scale or query
shows its fault in the panel. `--acceptance [--frames=count] [--capture=path.rgba]` runs without a
window: it renders a reflected, non-uniform mesh and a relative-motion cast from a fixed camera,
prints the query results and saves a raw RGBA capture.
