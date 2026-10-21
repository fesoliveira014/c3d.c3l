# Collision queries reference

Rules for prepared shapes, surface queries, height-field sources and windows, and the faults of both. The task
descriptions and the call list are in [collision queries](collision_queries.md). Length limits assume the default
native unit setting of one unit per metre.

## Prepared scale

`scale` applies in the shape's local axes when the shape is prepared; query poses stay rigid. A zero or nonfinite
component returns `c3d::INVALID_ARGUMENT` before any native call. The size limits apply to the scaled dimensions, and
scaled values whose arithmetic overflows or underflows return `b3::DEGENERATE_GEOMETRY`.

| Kind | Accepted scale | `c3d::UNSUPPORTED` |
| --- | --- | --- |
| `SPHERE` | components of equal magnitude; any sign pattern | unequal magnitudes |
| `CAPSULE` | components of equal magnitude; any sign pattern | unequal magnitudes, scaled segment below one slop |
| `BOX` | any diagonal scale; half-extents multiply by the magnitudes | a scaled half-extent below 0.2 slop |
| `HULL` | any diagonal scale, including mirrored | a magnitude below 0.01 |
| `MESH` | any diagonal scale, including mirrored | a magnitude below 0.01 |
| `HEIGHT_FIELD` | positive diagonal scale, baked at cook time | a negative component |

A mirrored sphere, capsule or box is the same shape as the unmirrored one. A mirrored hull keeps outward-facing
normals and a mirrored mesh keeps its front faces. A mirrored height field is `c3d::UNSUPPORTED`; it is never
converted to a mesh.

### Hulls

A scaled hull is cooked once from the unit hull with the scale baked into its points; queries never scale at query time.
The scaled cook is a separate cache entry keyed by the geometry revision and the exact scale components: matching
requests share it and any different component creates another. A scaled hull occupies two slots, its unit cook and its
scaled cook; both stay cached until a source edit makes them stale, and only unheld stale entries are reclaimed, when the
table is full. A rejected preparation releases what it held. Matching retained cooks stay usable after the source's CPU
data is released.

Preparation keeps the native cooked hull, with at most 128 vertices. Query owners also admit at most 32 vertices per
face, so native contact clipping stays within its fixed scratch; exceeding it returns `c3d::CAPACITY_EXCEEDED`. This
does not narrow ordinary body creation. Nonfinite authored values return `c3d::INVALID_ARGUMENT`; degenerate or
unrepresentable geometry is refused. New hull cooks also check source arithmetic and the native work-allocation limit
before calling box3d.

## Prepared meshes

A `MESH` description names a geometry whose positions are the surface, with its indices, or consecutive position
triples when it has none. `material_indices` is optional, holds one index per triangle and is part of the entry key.
Before a new entry is cooked:

- a nonfinite position, an index outside the positions, an index count that is not a multiple of three or a material
  index count that differs from the triangle count returns `c3d::INVALID_ARGUMENT`;
- counts past the native signed 32-bit range return `c3d::CAPACITY_EXCEEDED`.

The native cook drops triangles whose area is below 0.01 times the squared linear slop, which is 2.5e-7. The view
describes the retained surface, and a geometry with no retained triangle returns `b3::DEGENERATE_GEOMETRY`. Every
preparation reads the retained surface through the view's scale, including one that reuses an entry a body cooked. A
scaled vertex that is not finite or a scaled triangle without area returns `b3::DEGENERATE_GEOMETRY`, and a tree
taller than 256 levels returns `c3d::CAPACITY_EXCEEDED`. This check needs no CPU arrays, so an owner can be prepared
from an entry that a body cooked after the arrays were released.

The cooked entry is unscaled and keyed by geometry, revision and material index content. Owners of any scale and
bodies share it; the scale lives on the view. A source edit creates a new entry on the next acquisition and owners that
hold the old entry keep it. A rejected preparation does not affect bodies that use the same entry. Queries never cook,
allocate or build a broad phase.

## Surface queries

A surface is a mesh or a height field. Convex means sphere, capsule, box or hull; convex pairs keep their native
four-point manifold.

| Pair | Contacts | Distance | Cast | Sweep | Ray |
| --- | --- | --- | --- | --- | --- |
| convex and surface, either order | yes | yes | yes, either or both moving | fixed orientations | against the surface |
| surface and surface | `c3d::UNSUPPORTED` | `c3d::UNSUPPORTED` | `c3d::UNSUPPORTED` | `c3d::UNSUPPORTED` | against either |

- **Contacts.** Every native point of every triangle within the speculative margin is reported with the normal of that
  triangle's contact, from the first shape toward the second, and the triangle's `triangle_index` in the cooked entry.
  The index is meaningful only for the entry the owner holds. Points are neither deduplicated, welded nor sorted.
  Separation is native: it can be positive inside the margin of four linear slops (0.02), and a negative value is a
  local penetration measure, not a signed distance to a volume. A triangle reports nothing for a shape behind its front
  face: a sphere is tested by its centre, a capsule by its segment midpoint and a hull by its centroid with one slop of
  tolerance. Reversing the arguments reverses every normal and leaves points and separations unchanged.
- **Contact storage.** Triangle contacts stream into the caller's output. Every native point is copied or the call
  returns `c3d::CAPACITY_EXCEEDED`, with no truncated prefix and unspecified output. The first failure is kept and later
  triangles write nothing. An empty output succeeds only when nothing touches.
- **Distance.** The result is unsigned, zero means the shapes overlap, and the whole retained surface is measured, so
  the nearest triangle can lie outside the other shape's bounds. The normal is the native one where it is defined and
  zero otherwise. A closed mesh has no inside: a shape wholly inside it reports the distance to the surface. Reversing
  the arguments swaps the witnesses and reverses the normal.
- **Casts.** The cast runs in the surface's starting frame with the convex shape moving by the relative translation, so
  either shape or both can move. The returned point is the witness at the returned time, with the surface's own
  translation times that time added once. The shapes close to a core distance of `max(slop, r - slop)`, with `r` the sum
  of the two radii (5 mm for a zero sum) with a tolerance of a quarter slop. A start inside that band is a hit at time
  zero with a zero normal, and touching alone does not promise time zero. A cast never encroaches. Mesh casts reach a
  triangle from either side.
- **Sweeps.** A sweep with fixed orientations is the translational cast between the start poses. Rotations that differ
  only by quaternion sign are unchanged; a change of either orientation returns `c3d::UNSUPPORTED`.
- **Rays.** A ray hits front faces only and reports the geometric normal of the hit triangle. The fraction lies strictly
  between zero and one: an origin on the surface, a hit exactly at the maximum distance, and a coplanar or back-facing
  ray all return `b3::NO_HIT`.
- **Admission.** Relative transforms, translations and proxy bounds must be finite, and the convex higher-order bounds
  apply to surfaces through their scaled bounds. An unrepresentable query returns `c3d::UNSUPPORTED`.

For convex pairs, `time_of_impact` keeps the native normal for a hit, including a possible time-zero hit; its native
overlapped path returns a zero normal. Time zero alone does not determine the normal.

## Height fields

A `HEIGHT_FIELD` description supplies `height_field` and optional `material_indices`.

- A `HEIGHTS` source holds row-major samples with x fastest, `count_x` columns and `count_z` rows, copied when cooked.
- A `TEXTURE` source reads the red channel of mip zero of a live texture in the cache's store (`RGBA8_UNORM` values
  divide by 255, `R16_UINT` by 65535, `RGBA32_FLOAT` is read as is). Other formats are `c3d::UNSUPPORTED`. The counts
  come from the texture.
- `material_indices` holds one byte per cell, `(count_x - 1) * (count_z - 1)` in all, and the byte `HEIGHT_FIELD_HOLE`
  marks a hole.

The grid starts at the local origin and runs along positive x and z at the scaled spacing, so the local bounds are
`[0, scale.x * (count_x - 1)]` by `[scale.y * lowest, scale.y * highest]` by `[0, scale.z * (count_z - 1)]`. Each cell
splits along the diagonal from its far-left corner to its near-right corner, and front faces point toward positive y.

The scale is baked at cook time and is positive. A zero or nonfinite component returns `c3d::INVALID_ARGUMENT`, a negative
component returns `c3d::UNSUPPORTED`, and a spacing whose reciprocal is not finite returns `b3::DEGENERATE_GEOMETRY`. A
source is validated before any native call:

- A count below two, a sample or material count that does not match the counts, or a nonfinite sample returns
  `c3d::INVALID_ARGUMENT`.
- Sample, offset and blob sizes that do not fit the native signed 32-bit integers return `c3d::CAPACITY_EXCEEDED`.
- A sample range or scaled bound that is not finite, and a retained cell that is nonfinite or has no area, return
  `b3::DEGENERATE_GEOMETRY`. A flat field is valid, and so is a field of only holes.
- A texture that is not live returns `c3d::INVALID_ID`. One that is not a single-layer 2D mip-zero source in a readable
  format returns `c3d::UNSUPPORTED`, and a texture whose pixels were released without a matching cooked entry returns
  `physics::SOURCE_UNAVAILABLE`.

### Quantization

The native cook quantizes each height to 16 bits across the sample range. The retained surface lies under the authored
heights by at most one step, `max(highest - lowest, 0.005) / 65535 * scale.y`, so a field never reproduces its samples
exactly. Every preparation reads the retained surface, including one that reuses an entry a body cooked. A whole-map
field quantizes over the range of its own samples. A windowed field, and a field with a neighbour, quantize over the
fixed range 0 to 1, which is `0` to `scale.y` metres, a step of `scale.y / 65535`. Equal quantization is what lets
windows of one map, and [tiles](terrain.md#tile-sets) of one set at equal `height_scale`, meet exactly, and an edit
never re-quantizes another window.

### Windows

A `TEXTURE` field may carry a `window`, `{ x, z, count_x, count_z }` in cells, that prepares only `count_x + 1` by
`count_z + 1` samples of the map; all zero covers the whole map. A window reads one sample past each side that has map
beyond it. It needs `RGBA8_UNORM` or `R16_UINT` samples, because only those convert into a fixed range:

| Condition | Fault |
| --- | --- |
| A window on a `HEIGHTS` source, with a zero count, or past the map | `c3d::INVALID_ARGUMENT` |
| An `RGBA32_FLOAT` map | `c3d::UNSUPPORTED` |

A window with map beyond any side takes `material_indices` for its own cells plus one ring of map cells, repeated at the
map border: `(count_x + 2) * (count_z + 2)` entries, against `count_x * count_z` for a window that covers the whole map.
The window is part of the entry key.

### Neighbours

A `TEXTURE` field may carry `neighbours`, four `HeightFieldNeighbour { texture, material_indices }` in `HeightFieldSide`
order (`NEGATIVE_X`, `POSITIVE_X`, `NEGATIVE_Z`, `POSITIVE_Z`), that continue its map past a side. Where the map ends,
the apron of a side holds the neighbour's second column or row in, since the first duplicates the shared edge, so two
tiles cook as one surface along their shared edge. A side without a neighbour repeats the border sample, and corners are
never read.

| Condition | Fault |
| --- | --- |
| A neighbour of another format or shared-edge length | `c3d::INVALID_ARGUMENT` |
| A neighbour on a `HEIGHTS` source | `c3d::INVALID_ARGUMENT` |
| `material_indices` that are not one per neighbour cell, or `material_indices` on a side with no texture | `c3d::INVALID_ARGUMENT` |
| An `RGBA32_FLOAT` map with a neighbour | `c3d::UNSUPPORTED` |

Neighbour `material_indices` are optional and copied with the body, so the caller's array need not outlive the call.
A neighbour without them gives solid cells. A whole field's own indices stay one per cell and the cook adds the ring.
The neighbour textures and their revisions are part of the entry key and of the revision sum behind the
`SOURCE_UNAVAILABLE` retry.

### Cache keys

A texture field is keyed by texture, revision, window, neighbours, exact scale and material content. A raw `HEIGHTS`
field is keyed by a 64-bit content hash of its counts, samples, materials and holes, and by its exact scale. Equal
content in a different array shares one entry; a changed sample, hole or scale makes a new one. The cache keeps no copy
of the samples to compare, so a hash collision would share an entry cooked from different samples. A raw entry is freed
when its last holder releases it; a texture entry stays cached for matching preparations, as a mesh entry does. Worlds
use the same keys, so bodies with equal content share one entry.

### Height-field queries

The pair table applies. Differences from a mesh:

- **Holes.** Contacts skip hole cells, and casts and rays pass through them. A field of only holes reports no contacts
  and `b3::NO_HIT` for distance, casts and rays.
- **Distance.** The result is the minimum over the retained cells of the whole field, clipped to the grid before the
  native cell loops run, so a query box that reaches far outside the field costs no more than the field.
- **Casts and rays.** The native traversal clips the sweep to the field grown by the proxy extent and a native margin of
  0.05. A query whose grid indices cannot be represented as native signed 32-bit integers returns `c3d::UNSUPPORTED`,
  for example a field with a very narrow spacing in x or z. A far-away pose is limited by the admission bounds, not by
  the field.
- **Cost.** The native traversal visits the cells under the query footprint, not only the cells that produce output.

## Height-field windows

A `TEXTURE` height-field collider on a body cooks the whole map into one native object, so an edit re-cooks every
sample. `add_height_field_windows` tiles the field into static window bodies instead, so an edit re-cooks only the
windows it touches.

```c3
physics::add_height_field_windows(
    scene:        &scene,
    assets:       &assets,
    node:         terrain_node.id,
    collider:     &collider,
    window_cells: 256,
)!;
// write texels in place, then:
assets.mark_texture_dirty(height_map);
physics::mark_height_field_windows_changed(
    scene: &scene,
    node:  terrain_node.id,
    rect:  { .x = x, .z = z, .columns = columns, .rows = rows },
)!;
world.update(dt);
```

| Call | Effect |
| --- | --- |
| `add_height_field_windows(scene, assets, node, collider, window_cells)` | Creates one child node per window under `node`, at the window origin `(x * scale.x, 0, z * scale.z)`, each with a static `PhysicsBody` holding one windowed collider copied from the template, and a `HeightFieldWindows` component on `node` that owns them. Edge windows take the remaining cells. The node's world matrix must be current. The bodies build on the next update. |
| `mark_height_field_windows_changed(scene, node, rect)` | Marks every window whose sample range `[x - 1, x + count + 1]` meets the `SampleRect`, given in samples of the map (its texels). Returns how many it marked, and faults `c3d::INVALID_ID` for a dead node or one without windows. |
| `remove_height_field_windows(scene, node)` | Removes the window nodes and bodies. Does nothing without windows, and invalidates component pointers of every store the window nodes used. |

- The template is a `HEIGHT_FIELD` collider over a `TEXTURE` source whose `window` is ignored. Per-cell
  `material_indices` cover the whole map and are cut per window; `add_height_field_windows` copies the template's
  neighbours, cuts their cells into each window's ring and keeps on a window body only the maps of the sides where the
  map ends. The call faults `c3d::INVALID_ARGUMENT`, `c3d::CAPACITY_EXCEEDED`, `c3d::INVALID_ID` and `c3d::UNSUPPORTED`;
  it faults `c3d::INVALID_ARGUMENT` when the node already has windows.
- Windows share the samples on their common edge and read one sample past it, so an edit on or beside a shared edge
  marks two windows and one on or beside a shared corner marks four. A body crosses a window seam as it crosses the
  interior of a whole field.
- A marked window is rebuilt synchronously by the next `PhysicsWorld.update`; an unmarked one is never rebuilt, so a
  body resting on it keeps its contact and its sleep. The rebuilt window has the one-step contact gap of any
  `mark_changed`. `PhysicsCounters.pending_bodies` counts the bodies marked and not yet built.
- To change `window_cells`, remove the windows and add them again. Removing the node removes its window nodes with it.
- Each window takes one snapshot slot (the key adds the window to the texture, revision, scale and material indices).
  Size `PhysicsDesc.snapshot_capacity` (`CollisionCacheDesc.snapshot_capacity` for a world that borrows a cache) for the
  windows plus the application's other shapes. A window that finds no free
  slot fails to build with `c3d::CAPACITY_EXCEEDED`, reported in `build_failures` at the update;
  `add_height_field_windows` does not check. A re-cooked window leaves its previous entry unheld, and a full table
  reclaims it.
- A collider with a neighbour reads the neighbour across a map edge, so a body crosses from one tile collider to the
  next as it crosses the interior of one field. After an edit of a neighbour within two texels of the shared edge, mark
  this collider's facing edge: a live collider is re-cooked only when marked. Adding or removing a neighbour changes the
  description, so rebuild the body or the windows.
- With `C3D_PHYSICS_SERIAL`, `HeightFieldWindows` is a described owner whose payload is `{ window_cells, collider }`.
  Export omits the window bodies and nodes, and loading regenerates them through `add_height_field_windows`
  ([serialization](serialization_reference.md#physics)).

## Faults

| Fault | Cause |
| --- | --- |
| `c3d::INVALID_ARGUMENT` | Zero or nonfinite scale, dimension or source value; counts that do not match the source; a bad window or neighbour; invalid poses or directions; a cache from another store. |
| `c3d::INVALID_ID` | A dead geometry or texture. |
| `c3d::UNSUPPORTED` | `COMPOUND`; a scale outside the kind's domain; a size below the native floor; an unreadable texture; unrepresentable query bounds; a surface pair; a rotating surface sweep. |
| `c3d::CAPACITY_EXCEEDED` | Output too small; more than 32 vertices per hull face; mesh or height-field sizes past native limits; a full snapshot table. |
| `physics::SOURCE_UNAVAILABLE` | CPU data released and no matching cooked entry. |
| `b3::DEGENERATE_GEOMETRY` | A hull, mesh or field with no volume or area, or arithmetic that overflows. |
| `b3::INVALID_DEFINITION` | box3d refused the cooked definition. |
| `b3::NO_HIT` | A cast, sweep, ray or distance found nothing. |
| `c3d::RESOURCE_IN_USE` | `destroy_collision_cache` while owners, worlds or holders remain. |
