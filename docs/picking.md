# CPU picking

Module `c3d::spatial`. `spatial::pick` finds the meshes a world-space ray meets from the scene's current transforms and the asset store's CPU geometry. It needs no renderer, no GPU readback and no spatial index, and it works before the first frame.

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

`PickHit` carries the node, the world distance along the ray, the position `origin + distance * direction`, and, when a triangle was tested, `triangle_hit`, `triangle_index` and `barycentric`. `triangle_index` counts triangles in primitive order: indexed geometry triangle `t` uses `indices[3t]`, `indices[3t + 1]`, `indices[3t + 2]`; non-indexed geometry uses vertices `3t` to `3t + 2`. `barycentric` weights those three vertices in that order and sums to one. `instanced` and `instance_index` are reserved for instanced meshes and read `false` and zero until they exist.

Hits are ordered by ascending distance, then by node index. Node pointers are borrows; keep the entity id across structural scene changes.

## Precision

`BOUNDS` reports the ray's entry into each mesh's world bound: `Mesh.local_bounds` when `has_bounds_override` is set, else the geometry's bounds, transformed by the node's world matrix, or the joint-derived bound for a skinned mesh. Bounds survive `release_geometry_cpu`, so bounds picking keeps working after the streams are gone.

`TRIANGLES` tests triangles only for static retained geometry: positions still present, `TRIANGLES` topology, no morph targets, no skin binding and no bounds override. Such a mesh is hit only where a triangle is, at the nearest one. Every other mesh reports its bounds hit with `triangle_hit == false`; rest-pose triangles are never presented as an animated surface. Released geometry needs an explicit reload before a triangle query sees it again.

## Faces

`PickOptions.faces` selects which triangle sides count. `BOTH` accepts every triangle. `FRONT` accepts the counter-clockwise front in the geometry's local space, matching the renderer's cull flip for mirrored nodes. `MATERIAL`, the default, behaves as `BOTH` for a double-sided material and as `FRONT` otherwise. Bounds hits ignore the policy.

## Distances under scale

A triangle test runs in the mesh's local space with the ray transformed by the inverse world matrix and its direction left unnormalized; the intersection parameter is then the world distance along the original ray, whatever the node's scale. Bounds hits are computed in world space directly. Both kinds sort in one list by that distance.
