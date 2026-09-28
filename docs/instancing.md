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

Edit elements in place, then mark the batch before the `render_view` that should show the edit:

```c3
InstancedMesh* batch = scene.get(trio, InstancedMesh);
batch.transforms[1].position.y = height;
batch.colors[2] = { 0.2f, 0.4f, 1, 1 };
scene.mark_instances_dirty(trio);
```

The drawn records change only through `mark_instances_dirty`, `set_instances` or `resize_instances`; each advances `InstancedMesh.revision`, which is never 0 and is compared for equality only. An unmarked edit is not drawn, with no fault and no message. Extraction bounds, picking, tracing and view history read the arrays at once, so an unmarked edit moves bounds, picks and traces while the drawn instances stay. A mark after `render_view` takes effect in the next frame.

Change the count with `resize_instances(node, count)`, which fills new slots with the identity transform and white, or replace the live instances with `set_instances(node, transforms, colors)`. Neither allocates; past the capacity both fault `CAPACITY_EXCEEDED`. A color slice longer than the transform slice is `INVALID_ARGUMENT`. Removing the node frees both arrays and never the assets.

The instance index is the array position. It is not a generational identity: it moves when the application reorders or resizes.

## Drawing

- **Culling.** The batch is culled as a whole against the bound of all live instances, or `local_bounds` when `has_bounds_override` is set. `cast_shadow` and `receive_shadow` apply to every instance.
- **Mirrored instances.** A transform whose scale product is negative mirrors space. The renderer packs non-mirrored instances first and draws each group with its own front face, so a batch holding both makes two draws per pass.
- **Color.** The instance color multiplies the vertex color, alpha included, in every built-in material. A masked material cuts per instance, and its shadow matches.
- **Motion blur and TAA.** Each instance moves by its own previous matrix, kept per view while the batch's live count stays the same; after a count change the batch node's motion applies for one rendering.
- **Materials.** Opaque and masked materials are the supported case. Blended batches draw without sorting inside the batch, and do not cast shadows.
- **Deformation.** Instances draw the rest pose of the geometry; skinning and morph targets are not applied.

The renderer keeps each batch's instance records in its own GPU memory, 128 bytes per instance of capacity, and shares them across every view and shadow layer. It uploads them when the batch's revision or its node's world matrix changes, or its capacity grows; a batch at rest uploads nothing. `Stats.uploads` and `Stats.upload_bytes` count these uploads. `Stats.instances` counts drawn instances across passes; `Stats.triangles` counts each instance's triangles.

Records are world-space, so a batch whose node moves re-uploads every record in that frame: a batch of 100,000 instances under a moving node uploads 12.8 MB per frame. For a large batch that must stay resident, move the instances and keep the node at rest.

`RendererDesc.max_instance_batches` (default 1024) bounds the batch nodes holding records: live ones plus those unresolved within the last `INSTANCE_ABSENCE_FRAMES` frames. Past it, `render_view` faults `CAPACITY_EXCEEDED`. A batch not drawn by any view or shadow layer for more than `INSTANCE_ABSENCE_FRAMES` frames (hidden, culled, removed) releases its records and uploads them again on its next draw.

## Custom vertex stages

A custom material whose shader has a vertex stage draws a batch only when the shader also supplies the instanced pair, `CustomVertex.instanced_shaded` and `instanced_depth`: the same source compiled with `INSTANCED`, and with `DEPTH_ONLY` and `INSTANCED`. A stage that ends in `write_mesh_outputs` needs no source change. Without the pair the batch is skipped and counted in `Stats.dangling_refs`. Fragment-only custom materials draw batches unchanged.

## Picking

`spatial::pick` tests a batch's aggregate bound, then each live instance. A hit carries the batch node, `instanced = true` and `instance_index`.

Example: `python3 scripts/build.py --example instancing`.

## Crowds

A crowd draws many animated copies of one skinned model, each instance with its own clip, time and
speed, in one draw per skinned part per parity per pass.

```c3
Node* crowd = model::add_crowd(
    assets:      &assets,
    scene:       &scene,
    model:       character,
    capacity:    512,
    pose_bounds: pose_bounds,
    instances:   instances[..],
)!;

while (window.poll()) {
    anim::crowd_update(&assets, &scene, window.clock.delta);
    scene.update_world();
    // render
}
```

- `add_crowd` covers every skin of the template that shares one skeleton and joint list; it faults
  `INVALID_ARGUMENT` for a template without skins, skins on different skeletons, more instances than
  `capacity`, or an instance clip the template does not own. It creates the crowd node, which carries
  `AnimatedCrowd`, and one child `InstancedMesh` node per skinned part: one scene node plus one per part.
  Meshes without a skin (a rigid prop) are not drawn; `template.meshes.len - crowd.parts.len` of them
  are left out.
- Each `CrowdInstance` has a placement, a `CrowdPose` (`clip`, `time`, `speed`, `loop`) and a tint.
  `set_crowd` replaces them and the live count for every part at once.
- `crowd_update` advances every pose (loop wraps, otherwise the time clamps), samples its clip into one
  model-space palette per instance, writes the placements into every part batch and bounds each batch
  by `pose_bounds` under every placement. Poses are independent: no blending, fading or retargeting per
  instance; a character that needs those is an `Animator` instance.
- `pose_bounds` is instance-local and must cover every pose of one instance; culling and shadow fitting
  use nothing else.
- Part nodes keep an identity local transform and are removed only by removing the crowd node, which
  removes them with it. The crowd's model must stay in the store while the crowd lives.
- Every part reads the same palettes: all parts share the placements, so they pack instances in the
  same parity order. Morph weights are per instance and per part.
- `crowd_update` marks every part batch, so part records upload every frame (128 bytes per instance
  per part).
- The renderer uploads one palette array per crowd per frame (`joints * 64` bytes per instance) and
  reuses it for every part, view and shadow layer. Above `OVERSIZED_UPLOAD_BYTES` (8 MiB, about 2470
  instances of a 53-joint character) the upload takes dedicated overflow memory every frame.
- Crowds never enter the ray tracing paths (shadows, ambient occlusion, reflections, path tracing),
  whatever `InstancedMesh.trace` says; raster shadows and temporal views work. This is the limit plain
  skinned meshes have.
- Custom materials: a fragment-only custom material draws with the built-in skinned instanced stage. A
  custom instanced vertex pair skins a crowd when compiled with the deformation defines
  ([Custom shaders](custom_shaders.md)).

Example: `python3 scripts/build.py --example crowd` walks 512 instances of the committed Quaternius
character through six of its clips; `B` switches to 512 `Animator` instances of the same model for
comparison, `--baseline` starts there.
