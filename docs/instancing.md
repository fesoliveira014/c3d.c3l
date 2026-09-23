# Explicit instancing

Module `c3d::scene` owns the component; `c3d::render` draws it. An `InstancedMesh` draws many copies of one geometry and one material with one draw call per pass. Each copy has its own transform and color. There is no automatic batching: a batch exists because the application made one.

## Batches

```c3
Transform[3] transforms = { left, middle, right };
Vec4[1] colors = { { 1, 0.2f, 0.2f, 1 } };
Node* trio = scene.add_instanced_mesh(
    geometry:   cube,
    material:   white,
    capacity:   16,
    transforms: transforms[..],
    colors:     colors[..],
    name:       "trio",
)!;
```

`add_instanced_mesh` allocates `transforms` and `colors` once, at `capacity`, from the scene allocator, and copies the slices in. Instances live in `[0, count)`. Colors past the given slice start white. The node's world matrix applies to every instance: an instance's model matrix is `node.world * transforms[i].to_mat4()`.

Edit elements in place between frames; the next extraction reads them:

```c3
InstancedMesh* batch = scene.get(trio, InstancedMesh);
batch.transforms[1].position.y = height;
batch.colors[2] = { 0.2f, 0.4f, 1, 1 };
```

Change the count with `resize_instances(node, count)`, which fills new slots with the identity transform and white, or replace the live instances with `set_instances(node, transforms, colors)`. Neither allocates; past the capacity both fault `CAPACITY_EXCEEDED`. A color slice longer than the transform slice is `INVALID_ARGUMENT`. Removing the node frees both arrays and never the assets.

The instance index is the array position. It is not a generational identity: it moves when the application reorders or resizes.

## Drawing

- **Culling.** The batch is culled as a whole against the bound of all live instances, or `local_bounds` when `has_bounds_override` is set. `cast_shadow` and `receive_shadow` apply to every instance.
- **Mirrored instances.** A transform whose scale product is negative mirrors space. The renderer packs non-mirrored instances first and draws each group with its own front face, so a batch holding both makes two draws per pass.
- **Color.** The instance color multiplies the vertex color, alpha included, in every built-in material. A masked material cuts per instance, and its shadow matches.
- **Motion blur and TAA.** Each instance moves by its own previous matrix, kept per view while the batch's live count stays the same; after a count change the batch node's motion applies for one rendering.
- **Materials.** Opaque and masked materials are the supported case. Blended batches draw without sorting inside the batch, and do not cast shadows.
- **Deformation.** Instances draw the rest pose of the geometry; skinning and morph targets are not applied.

Packed instance data goes through the frame upload ring, 128 bytes per instance, once per frame per batch, and is reused by every view and shadow layer of the frame. `Stats.instances` counts drawn instances across passes; `Stats.triangles` counts each instance's triangles.

## Custom vertex stages

A custom material whose shader has a vertex stage draws a batch only when the shader also supplies the instanced pair, `CustomVertex.instanced_shaded` and `instanced_depth`: the same source compiled with `INSTANCED`, and with `DEPTH_ONLY` and `INSTANCED`. A stage that ends in `write_mesh_outputs` needs no source change. Without the pair the batch is skipped and counted in `Stats.dangling_refs`. Fragment-only custom materials draw batches unchanged.

## Picking

`spatial::pick` tests a batch's aggregate bound, then each live instance. A hit carries the batch node, `instanced = true` and `instance_index`.

Example: `python3 scripts/build.py --example instancing`.
