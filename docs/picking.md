# CPU picking

Picking turns a screen position into the scene objects under it. It is pure CPU work in
`c3d::spatial`: the query reads the scene's current world transforms and the store's geometry
bounds, needs no renderer, no frame and no GPU readback, and answers before the first frame is
recorded. Highlighting a hit is the application's job, usually through the debug-line sink.

```bash
python3 scripts/build.py --example pick
./examples/build/pick
```

## The query

```c3
@pool() {
    PickHit[] hits = spatial::pick(
        allocator: tmem,
        assets:    &assets,
        scene:     &scene,
        ray:       ray,
        options:   { .precision = TRIANGLES, .layers = camera.layers },
    );
    if (hits.len) panels.selected = hits[0].node.id;
};
```

```c3
fn PickHit[] pick(
    Allocator allocator,
    AssetStore* assets,
    Scene* scene,
    Ray ray,
    PickOptions options = PICK_OPTIONS_DEFAULT,
);
```

`PickOptions`:

| Field | Meaning |
| --- | --- |
| `precision` | `BOUNDS` (default) or `TRIANGLES` |
| `faces` | `MATERIAL` (default), `BOTH` or `FRONT` |
| `layers` | Layer mask; a node joins the scan when `layers & node.layers != 0` |

`PickHit`:

| Field | Meaning |
| --- | --- |
| `node` | The hit node, borrowed; valid while it is live |
| `distance` | Ray parameter, i.e. world distance for a normalized ray direction |
| `position` | `ray.origin + ray.direction * distance` |
| `triangle_hit` | Whether the result came from the triangle path rather than the bound |
| `triangle_index` | Index of the hit triangle; `indices[3k..3k+2]` when indexed |
| `barycentric` | Weights of the triangle's first, second and third vertex |
| `instanced`, `instance_index` | Reserved for explicit instanced meshes; `false` and `0` today |

The result is allocator-owned and nearest first, with **at most one hit per node**; no hit is an
empty slice, never a fault. Free it with `alloc::free(allocator, hits.ptr)`, or query inside the
`@pool()` scope that consumes it. The query has one precondition, `@require
ray.direction.is_normalized()`, because distances are world units by construction.

The scan is flat: every `Mesh` component in component order, skipping nodes that are not
`visible_effective`, nodes outside the layer mask, and nodes whose geometry id no longer resolves.
The tree is never walked and a previous render's bounds snapshot is never read, so the query
follows any transform edit that `Scene.update_world` has folded in.

## Bounds and triangles

`BOUNDS` reports the ray's entry into the object's box, transformed from the mesh's authored
override (`Mesh.has_bounds_override`, `Mesh.local_bounds`) or the geometry's own bounds. This is
bound selection, not surface selection: an authored animation bound may be deliberately loose. It
keeps working after `release_geometry_cpu`, because a release keeps the bounds and drops only the
streams.

`TRIANGLES` intersects retained static geometry with Möller–Trumbore and reports the nearest
triangle, its primitive index and the barycentric coordinates of the crossing. The narrow phase
runs in the node's local space with the ray direction left **un-normalized**, so a hit parameter
stays the world-ray parameter and a nonuniform object scale cannot make a local parameter
masquerade as a world distance.

Geometry whose rest triangles are not the surface the node shows falls back to its bound, and the
hit reports `triangle_hit = false` rather than disappearing from the list. That applies when the
topology is not `TRIANGLES`, the position stream was released, the node carries a `SkinBinding`,
the mesh has a nonzero morph weight, or `has_bounds_override` is set. A mesh that is in fact static
clears the override to gain triangle precision.

## Accepted sides

`faces` decides which sides of a triangle count:

| Value | Accepts |
| --- | --- |
| `MATERIAL` | The front side always; the back side when the material is absent or `double_sided` |
| `BOTH` | Both sides, whatever the material says |
| `FRONT` | The front side only |

The front side is the local winding—counter-clockwise, the convention every primitive and importer
follows—and the test is purely local. A mirrored `node.world` does not invert it: the renderer
keeps a mirrored mesh's local front side in front by flipping the rasterizer's convention, so
picking and rendering agree. `Geometry.flip_winding` is the way to change which side is front.

Rejecting a side is not the fallback case. When the geometry carries usable triangles and every
candidate is on a rejected side, the object produces no hit at all, which is the precise answer to
a precise question.

## Screen coordinates

The application derives the ray; `camera::screen_to_ray` takes a pixel relative to the view's
viewport's top-left corner and the viewport's extent in pixels. Both come from the view:

```c3
PixelRect viewport = desc.viewport;                    // zero extent covers the whole output
Vec2 extent = viewport.width && viewport.height
    ? (Vec2){ (float)viewport.width, (float)viewport.height }
    : (Vec2){ (float)window.width, (float)window.height };
Vec2 pixel = {
    input.mouse_position.x - (float)viewport.x,
    input.mouse_position.y - (float)viewport.y,
};
CameraMatrices matrices = camera::derive_matrices(
    camera:       *scene.get(camera_node, Camera),
    camera_world: camera_node.world,
    viewport:     extent,
);
Ray ray = camera::screen_to_ray(&matrices, pixel, extent);
```

`Input.mouse_position` is already in framebuffer pixels. The ray uses the **output** rectangle, not
the working resolution: `render_scale` changes how many pixels a view renders into, not where the
pointer lands, and temporal jitter never moves a selection ray. Picking an off-screen view works
the same way with that view's viewport and the target's dimensions.

## Example

`examples/pick` runs a query through the viewport centre before its first frame and prints the
result, then picks on every left click with the panel's precision and sides. A hit writes the
node's `Entity` into `GuiPanelState.selected`, so the scene panel follows the selection, and the
debug-line sink draws the bound, the hit position axes and the pick ray—plus the hit triangle when
the triangle path answered. Two `geometry::box` meshes and two instances of one glTF model share
the scene with a monitor slab that samples the off-screen view; a second camera writes that view,
so the highlight appears in both outputs.
