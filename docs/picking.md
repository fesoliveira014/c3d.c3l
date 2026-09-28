# CPU picking

Module `c3d::spatial`. `spatial::pick` finds the meshes a world-space ray meets from the scene's current transforms and the asset store's CPU geometry. It needs no renderer, no GPU readback and no spatial index, and it works before the first frame. It is the linear reference: a [`SceneIndex`](#scene-index) answers the same query through a tree over the scene's bounds.

## Rays

A pick starts from a pixel of one view. The pixel is relative to the view rectangle's top-left corner (`ViewDesc.viewport`, or the whole output when the viewport has zero extent), in framebuffer pixels; `Input.mouse_position` already is. The matrices come from the same unjittered camera the view renders with:

```c3
Vec2 viewport = { (float)window.width, (float)window.height };
CameraMatrices matrices = camera::derive_matrices(*camera, camera_node.world, viewport);
Ray ray = camera::screen_to_ray(&matrices, pixel, viewport);
```

The viewport extent supplies the aspect when `Camera.aspect` is zero, so the ray matches the rendered projection whatever the render scale.

## Query

```c3
scene.update_world();
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

`pick` returns an array owned by the allocator, nearest first, with at most one hit per mesh; an empty array means no hit. A mesh takes part when it is effectively visible, on a layer of `options.layers`, and its geometry, material and, for a skinned mesh, skeleton ids are live. `PICK_OPTIONS_DEFAULT` picks bounds on every layer.

`PickHit` carries the node, the world distance along the ray, the position `origin + distance * direction`, and, when a triangle was tested, `triangle_hit`, `triangle_index` and `barycentric`. `triangle_index` counts triangles in primitive order: indexed geometry triangle `t` uses `indices[3t]`, `indices[3t + 1]`, `indices[3t + 2]`; non-indexed geometry uses vertices `3t` to `3t + 2`. `barycentric` weights those three vertices in that order and sums to one. For an [instanced batch](instancing.md), each live instance the ray meets is its own hit on the batch node, with `instanced` set and `instance_index` its array position; mesh hits read `false` and zero.

Hits are ordered by ascending distance, then by node index, then by instance index. Node pointers are borrows; keep the entity id across structural scene changes.

## Precision

`BOUNDS` reports the ray's entry into each mesh's world bound: `Mesh.local_bounds` when `has_bounds_override` is set, else the geometry's bounds, transformed by the node's world matrix, or the per-joint retained bound of a skinned mesh under its current pose and morph weights. Bounds survive `release_geometry_cpu`, so bounds picking keeps working after the streams are gone.

`TRIANGLES` tests triangles only for static retained geometry: positions still present, `TRIANGLES` topology, no morph targets, no skin binding and no bounds override. Such a mesh is hit only where a triangle is, at the nearest one; when two triangles lie at the same distance, the lower triangle index wins. Every other mesh reports its bounds hit with `triangle_hit == false`; rest-pose triangles are never presented as an animated surface. Released geometry needs an explicit reload before a triangle query sees it again. Geometry whose arrays form no triangle list (an index past the last vertex, a count that is not a multiple of three) also reports its bounds hit.

## Faces

`PickOptions.faces` selects which triangle sides count. `BOTH` accepts every triangle. `FRONT` accepts the counter-clockwise front in the geometry's local space, matching the renderer's cull flip for mirrored nodes. `MATERIAL`, the default, behaves as `BOTH` for a double-sided material and as `FRONT` otherwise. Bounds hits ignore the policy.

## Distances under scale

A triangle test runs in the mesh's local space with the ray transformed by the inverse world matrix and its direction left unnormalized; the intersection parameter is then the world distance along the original ray, whatever the node's scale. Bounds hits are computed in world space directly. Both kinds sort in one list by that distance.

## Triangle trees

A triangle query traces the geometry's triangle tree, which the asset store owns: `AssetStore.triangle_bvh` builds it on first use for the geometry's current revision and keeps it until the revision moves, `release_geometry_cpu` frees it, or the geometry is removed. The store also records, per revision, whether the arrays form a triangle list (`AssetStore.triangles_valid`); the renderer's software trace level and its hardware bottom levels use the same answer and the same tree. Both picks and the warm-up below write the store's cache, so run them on the thread that owns the store.

The first triangle query of a large mesh pays for the build: 29.8 ms for 262,088 triangles on an i9-14900K at O3. Build the trees at load time instead:

```c3
scene.update_world();
spatial::prepare_triangle_picks(&assets, &scene);
```

`prepare_triangle_picks` walks every mesh and batch, hidden or on any layer, and builds the tree of each geometry whose triangles a query would test, once per geometry. Skinned, morphed, overridden and released geometry build none; a malformed list is recorded and builds none. A kept tree costs 32 bytes per node and 4 per triangle, about 21 bytes per triangle: 5.6 MB for 262,088 triangles. `release_geometry_cpu` frees it; bounds queries keep working after the release.

## Scene index

`SceneIndex` holds one entry per effectively visible mesh and one per live batch instance, with its world bound, and a tree over those bounds:

```c3
SceneIndex index = spatial::create_scene_index(mem, capacity);
defer spatial::destroy_scene_index(&index);

// every frame
scene.update_world();
index.refresh(&assets, &scene)!;

// on a click
@pool() {
    PickHit[] hits = index.pick(tmem, &assets, ray, options);
    if (hits.len > 0) selected = hits[0].node.id;
};
```

`refresh` reads node world matrices, visibility and batch arrays as left by the last `update_world`; refresh after the last change and before picking. `pick` returns exactly the hits and order `spatial::pick` returns for the scene of the last refresh, triangle ties included. Removing a node between a refresh and a pick leaves the index holding its pointer; refresh first. Instance transforms edited in place reach the index only after `Scene.mark_instances_dirty`, as they reach the renderer.

`revision` advances when a refresh finds any entry changed, and the next pick rebuilds the tree. A bound that changes from 0 to -0 counts as a change and costs one rebuild. A refresh visits every mesh; a batch whose node world matrix, geometry and its revision, batch revision, count and flags match the previous refresh keeps its entries without visiting its instances. Readings are in [Benchmarking](benchmarking.md#scene-index-and-triangle-trees): on an i9-14900K at O3, a refresh with nothing changed takes 14 µs for 2,000 meshes and a 4,096-instance batch; the tree rebuild over those 6,096 entries 0.52 ms; 64 bounds picks 0.27 ms through the index against 11 ms through the scan.

`capacity` counts meshes plus batch instances. A refresh that finds more faults `c3d::CAPACITY_EXCEEDED` and leaves `count` at zero, so picks return nothing until a refresh fits. The index allocates once at creation: 40 bytes per entry, a 100-byte batch key per entry, 32 bytes per tree node (2 × capacity − 1) and 4 per primitive. At a capacity of 65,536 that is 2.6 MB of entries, 6.6 MB of keys, 4.2 MB of nodes and 0.26 MB of primitives; each tree rebuild takes 24 bytes per entry of temporary memory. `dangling` counts meshes and batches the last refresh skipped for dead ids.

## Querying your own boxes

`bvh::build_box_bvh` builds a tree over any boxes, and `Bvh.@each_ray_hit` visits the boxes whose leaves the ray enters. Visited ids are candidates, not hits; test each one:

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

`bvh::build_box_bvh_into` builds into caller storage of `2 × count − 1` nodes and `count` primitives instead of allocating. The `collision_math` example of the physics package picks a scatter of boxes this way.
