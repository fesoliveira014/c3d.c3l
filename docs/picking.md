# CPU picking

Module `c3d::spatial`. `spatial::pick` finds the meshes a world-space ray meets from the scene's current transforms and the
asset store's CPU geometry. It needs no renderer, no GPU readback and no spatial index, and it works before the first frame.
It is the linear reference: a [`SceneIndex`](#scene-index) answers the same query through a tree over the scene's bounds.

## Quick start

```c3
import c3d::camera;
import c3d::maths;
import c3d::spatial;

scene.update_world();

Vec2 viewport = { (float)window.width, (float)window.height };
CameraMatrices matrices = camera::derive_matrices(*camera, camera_node.world, viewport);
Ray ray = camera::screen_to_ray(&matrices, window.input.mouse_position, viewport);

@pool() {
    PickHit[] hits = spatial::pick(
        allocator: tmem,
        assets:    &assets,
        scene:     &scene,
        ray:       ray,
        options:   { .precision = TRIANGLES, .faces = MATERIAL, .layers = camera.layers },
    );
    if (hits.len > 0) selected = hits[0].node.id;
};
```

`camera` is the node's `Camera*`, from `scene.get(camera_node, Camera)`. `hits` is nearest first; an empty array means no hit.

## Concepts

- **What takes part.** A mesh takes part when it is effectively visible, on a layer of `options.layers`, not `trace_only`,
  and its geometry, material and, for a skinned mesh, skeleton ids are live. Host-authored instanced batches, billboard
  batches, ribbon batches and LOD groups take part as listed under [Hits](#hits). Device-authored batches do not.
- **One hit per mesh.** A mesh yields at most one hit. Each live instance of an [instanced batch](instancing.md) that the ray
  meets is its own hit on the batch node.
- **Order.** Hits sort by ascending distance, then node index, then instance index, then part index.
- **Borrows.** `PickHit.node` is a borrow. Keep the entity id across structural scene changes.
- **Defaults.** `PICK_OPTIONS_DEFAULT` picks bounds on every layer.

## Cast a ray from a pixel

A pick starts from a pixel of one view. The pixel is relative to the view rectangle's top-left corner (`ViewDesc.viewport`, or
the whole output when the viewport has zero extent), in framebuffer pixels; `Input.mouse_position` already is. The matrices
come from the same unjittered camera the view renders with. The viewport extent supplies the aspect when `Camera.aspect` is
zero, so the ray matches the rendered projection whatever the render scale.

## Hits

| `PickHit` field | Meaning |
| --- | --- |
| `node` | The hit node. |
| `geometry` | Geometry of the hit mesh, instance or LOD part; zero for billboards and ribbons. |
| `distance` | World distance along the ray. |
| `position` | `origin + distance * direction`. |
| `instanced` | Set for an instance of an instanced batch and for a billboard. |
| `instance_index` | Array position of the instance, billboard or LOD placement; zero for a mesh. |
| `billboard` | Set when the hit is a billboard of a [billboard batch](billboards.md); `instanced` is set too. |
| `ribbon` | Set when the hit is a [ribbon batch](ribbons.md), bounded by the whole batch. |
| `lod_group` | Set when the hit is a part of a [LOD group](lod.md); the ray tests level zero. |
| `part_index` | Part of level zero for a LOD hit; zero otherwise. |
| `triangle_hit` | True when a triangle was tested and hit. |
| `triangle_index` | Triangle in primitive order: indexed geometry triangle `t` uses `indices[3t]`, `indices[3t + 1]`, `indices[3t + 2]`; non-indexed geometry uses vertices `3t` to `3t + 2`. |
| `barycentric` | Weights of those three vertices in that order; they sum to one. |

`triangle_hit`, `triangle_index` and `barycentric` are set only for a triangle query that tested a triangle.

`PickOptions`:

| Field | Values | Meaning |
| --- | --- | --- |
| `precision` | `BOUNDS`, `TRIANGLES` | How far a query looks into each mesh. |
| `faces` | `MATERIAL`, `BOTH`, `FRONT` | Which triangle sides count. |
| `layers` | Layer mask | Nodes whose `layers` share a bit take part. |

## Precision

`BOUNDS` reports the ray's entry into each mesh's world bound: `Mesh.local_bounds` when `has_bounds_override` is set, else
the geometry's bounds, transformed by the node's world matrix, or the per-joint retained bound of a skinned mesh under its
current pose and morph weights. Bounds survive `release_geometry_cpu`, so bounds picking keeps working after the streams are
gone.

`TRIANGLES` tests triangles only for static retained geometry: positions still present, `TRIANGLES` topology, no morph
targets, no skin binding, no bounds override and no [geometry write](custom_shaders.md#geometry-writes) since the last CPU
revision. Such a mesh is hit only where a triangle is, at the nearest one; when two triangles lie at the same distance, the
lower triangle index wins. Every other mesh reports its bounds hit with `triangle_hit == false`; rest-pose triangles are
never presented as an animated surface. Released geometry needs an explicit reload before a triangle query sees it again.
Geometry whose arrays form no triangle list (an index past the last vertex, a count that is not a multiple of three) also
reports its bounds hit.

## Faces

`PickOptions.faces` selects which triangle sides count. `BOTH` accepts every triangle. `FRONT` accepts the counter-clockwise
front in the geometry's local space, matching the renderer's cull flip for mirrored nodes. `MATERIAL`, the default, behaves as
`BOTH` for a double-sided material and as `FRONT` otherwise. Bounds hits ignore the policy.

## Distances under scale

A triangle test runs in the mesh's local space with the ray transformed by the inverse world matrix and its direction left
unnormalized; the intersection parameter is then the world distance along the original ray, whatever the node's scale. Bounds
hits are computed in world space directly. Both kinds sort in one list by that distance.

## Triangle trees

A triangle query traces the geometry's triangle tree, which the asset store owns. `AssetStore.triangle_bvh` builds it on first
use for the geometry's current revision and keeps it until the revision moves, `release_geometry_cpu` frees it, or the
geometry is removed. The store also records, per revision, whether the arrays form a triangle list
(`AssetStore.triangles_valid`); the renderer's software trace level and its hardware bottom levels use the same answer and the
same tree. Picks and the warm-up below write the store's cache, so run them on the thread that owns the store.

The first triangle query of a large mesh pays for the build. Build the trees at load time instead:

```c3
scene.update_world();
spatial::prepare_triangle_picks(&assets, &scene);
```

`prepare_triangle_picks` walks every mesh and batch, hidden or on any layer, and builds the tree of each geometry whose
triangles a query would test, once per geometry. Skinned, morphed, overridden and released geometry build none; a malformed
list is recorded and builds none. A kept tree costs 32 bytes per node and 4 per triangle, about 21 bytes per triangle.
`release_geometry_cpu` frees it.

## Scene index

`SceneIndex` holds one entry per pickable item of the scene with its world bound, and a tree over those bounds:

```c3
SceneIndex index = spatial::create_scene_index(mem, capacity);
defer spatial::destroy_scene_index(&index);

// after the last change of the scene, before a pick
scene.update_world();
index.refresh(&assets, &scene)!;

// on a click
@pool() {
    PickHit[] hits = index.pick(
        allocator: tmem,
        assets:    &assets,
        ray:       ray,
        options:   options,
    );
    if (hits.len > 0) selected = hits[0].node.id;
};
```

- `refresh` reads node world matrices, visibility and batch arrays as left by the last `update_world`. Refresh after the
  last change and before picking.
- `pick` returns exactly the hits and order `spatial::pick` returns for the scene of the last refresh, triangle ties
  included.
- Removing a node between a refresh and a pick leaves the index holding its pointer; refresh first.
- Instance transforms edited in place reach the index only after `Scene.mark_instances_dirty` or
  `Scene.mark_instances_range_dirty`, as they reach the renderer.
- `revision` advances when a refresh finds any entry changed, and the next pick rebuilds the tree. A bound that changes from
  0 to -0 counts as a change.
- A refresh visits every mesh. A batch whose node world matrix, geometry and its revision, batch revision, count and flags
  match the previous refresh keeps its entries without visiting its instances.
- `dangling` counts meshes and batches the last refresh skipped for dead ids.

### Capacity

`capacity` counts the entries a scene holds at once. One entry stands for each of:

- an effectively visible mesh that is not `trace_only`;
- a live leaf instance of a host-authored instanced batch (every instance when the batch has no quadtree);
- a billboard of a visible billboard batch;
- a visible ribbon batch with at least two points;
- a placement of a visible LOD group, per part of level zero.

A refresh that finds more faults `CAPACITY_EXCEEDED` and leaves `count` at zero, so picks return nothing until a refresh fits.

The index allocates once at creation. Per unit of capacity it holds a 56-byte entry, a 104-byte batch key, two 32-byte tree
nodes and a 4-byte primitive index, about 230 bytes. Each tree rebuild takes temporary memory from the temp allocator.

## Query your own boxes

`bvh::build_box_bvh` builds a tree over any boxes, and `Bvh.@each_ray_hit` visits the boxes whose leaves the ray enters.
Visited ids are candidates, not hits; test each one:

```c3
Bvh tree = bvh::build_box_bvh(mem, boxes)!;
defer bvh::free_bvh(mem, &tree);

float nearest = math::FLOAT_MAX;
bool found;
uint picked;
tree.@each_ray_hit(ray, math::FLOAT_MAX; uint box) {
    float distance;
    if (maths::ray_intersects_aabb(ray, boxes[box], &distance) && distance < nearest) {
        nearest = distance;
        found = true;
        picked = box;
    }
};
```

`bvh::build_box_bvh_into` builds into caller storage of `2 × count − 1` nodes and `count` primitives instead of allocating.
The `collision_math` example of the physics package picks a scatter of boxes this way.

## Faults

| Call | Fault |
| --- | --- |
| `SceneIndex.refresh` | `CAPACITY_EXCEEDED` when the scene holds more entries than `capacity`. |
| `AssetStore.triangle_bvh` | `INVALID_ARGUMENT` when the arrays form no triangle list; `ASSET_DATA_UNAVAILABLE` after `release_geometry_cpu`. |
| `AssetStore.triangles_valid` | `ASSET_DATA_UNAVAILABLE` after `release_geometry_cpu`. |
| `bvh::build_box_bvh` | `INVALID_ARGUMENT` for an empty box list. |

`spatial::pick`, `SceneIndex.pick` and `prepare_triangle_picks` do not fault.

## Limits

- Triangle precision covers static retained geometry only. Skinned, morphed and overridden meshes report bounds.
- Bounds survive `release_geometry_cpu`; triangles do not.
- Device-authored instanced batches and meshes with `trace_only` are not picked.
- A ribbon batch is one hit bounded by the whole batch. A batch with fewer than two points is not picked.
- `SceneIndex` has a fixed capacity and rebuilds its tree after any change a refresh finds.

## See also

- [Scene nodes](scene.md) for transforms, visibility and layers.
- [Instancing](instancing.md), [billboards](billboards.md), [ribbons](ribbons.md) and [LOD](lod.md) for the batch kinds that
  take part.
- [Benchmarking](benchmarking.md#scene-index-and-triangle-trees) for index and tree timings.
