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

The drawn records change only through `mark_instances_dirty`, `set_instances` or `resize_instances`; each advances `InstancedMesh.revision`, which is never 0 and is compared for equality only. An unmarked edit is not drawn, with no fault and no message. The batch bound that extraction, shadows and picking use, the mirrored count and view history also follow the revision, so an unmarked edit moves none of them. Tracing and picking's per-instance tests read the arrays at once, so an unmarked edit does move traces and per-instance picks. A mark after `render_view` takes effect in the next frame.

Change the count with `resize_instances(node, count)`, which fills new slots with the identity transform and white, or replace the live instances with `set_instances(node, transforms, colors)`. Neither allocates; past the capacity both fault `CAPACITY_EXCEEDED`. A color slice longer than the transform slice is `INVALID_ARGUMENT`. Removing the node frees both arrays and never the assets.

The instance index is the array position. It is not a generational identity: it moves when the application reorders or resizes.

## Drawing

- **Culling.** Extraction culls the batch as a whole against the bound of all live instances, or `local_bounds` when `has_bounds_override` is set; [instance culling](#instance-culling) then culls each instance on the GPU. The bound of all live instances is kept node-local on the batch (`InstancedMesh.aggregate`, written by the library). It is computed once per revision and geometry revision, and transformed by the node's world each frame. Under a rotated node it is the box of that box, looser than a per-instance merge, and the looseness grows with the batch's extent: for a batch about 5.7 units long under a node turned 45 degrees, the shadow cascade's depth range grew by up to 1.3%. `cast_shadow` and `receive_shadow` apply to every instance.
- **Indirect draws.** Every batch draws through one indirect command per parity range and pass, `draw_count` 1 and first instance 0; plain meshes draw directly. An unculled range's arguments are written by the CPU into the frame upload ring (20 bytes indexed, 16 non-indexed, 32 with alignment); a culled range's are written by the cull pass. `Stats.indirect_draws` counts these draws across every pass, the velocity pass included.
- **Mirrored instances.** A transform whose scale product is negative mirrors space. The renderer packs non-mirrored instances first and draws each group with its own front face, so a batch holding both makes two draws per pass.
- **Color.** The instance color multiplies the vertex color, alpha included, in every built-in material. A masked material cuts per instance, and its shadow matches.
- **Motion blur and TAA.** Each instance moves by its own previous matrix, kept per view while the batch's live count stays the same; after a count change the batch node's motion applies for one rendering. The view keeps node-local matrices and rewrites them only when the batch's revision changes. A batch at rest, or one whose node moves without an edit, draws through the node's motion, with no per-instance work and no upload; at rest its velocity is exactly zero. In the frame of an edit the renderer uploads 64 bytes per instance. A batch marked every frame (an animated batch, a crowd part) pays that every frame, so a large batch that must stay cheap is edited rarely.
- **Materials.** Opaque and masked materials are the supported case. Blended batches draw without sorting inside the batch, and do not cast shadows.
- **Deformation.** Instances draw the rest pose of the geometry; skinning and morph targets are not applied.

The renderer keeps each batch's instance records in its own GPU memory, 128 bytes per instance of capacity, and shares them across every view and shadow layer. It uploads them when the batch's revision or its node's world matrix changes, or its capacity grows; a batch at rest uploads nothing. `Stats.uploads` and `Stats.upload_bytes` count these uploads. `Stats.instances` counts the instances of unculled ranges across passes; `Stats.triangles` counts each of those instances' triangles. Culled ranges report through the culling fields below.

Records are world-space, so a batch whose node moves re-uploads every record in that frame: a batch of 100,000 instances under a moving node uploads 12.8 MB per frame. For a large batch that must stay resident, move the instances and keep the node at rest.

`RendererDesc.max_instance_batches` (default 1024) bounds the batch nodes holding records: live ones plus those unresolved within the last `INSTANCE_ABSENCE_FRAMES` frames. Past it, `render_view` faults `CAPACITY_EXCEEDED`. A batch not drawn by any view or shadow layer for more than `INSTANCE_ABSENCE_FRAMES` frames (hidden, culled, removed) releases its records and uploads them again on its next draw. Shadow layers draw a shadow-casting batch whether or not a view sees it, so such a batch keeps its records while a shadow-casting light is on.

## Instance culling

`ViewDesc.instance_culling`, on in `default_view_desc` and `texture_view_desc`, culls every instance of a batch against the frustum on the GPU before it is drawn. The view's shadow layers and depth prepass follow the flag of the view that renders them. Culling is frustum only: no occlusion, no level of detail.

- **Passes.** Each culling pass runs one compute dispatch per culled range: the view (with its uploads, before its shadow atlas and passes), its depth prepass, and all of its shadow layers in one stage before the shadow atlas. The velocity pass and the forward and deferred passes of a view read the view's ranges and dispatch nothing. `Pass.INSTANCE_CULL` times the dispatches.
- **Bounds.** An instance is tested as the eight corners of a local box under its world matrix against each plane, which is tighter than the world box extraction tests. The local box is the geometry bound for a plain batch and the crowd's `pose_bounds` for a crowd part. A batch with `has_bounds_override` that is not a crowd part is drawn unculled: its override bounds the batch, not one instance.
- **Index space.** A culled range draws `gl_InstanceIndex` over its visible list. Built-in stages and `write_mesh_outputs` map it back with `instance_source(draw)`; a custom instanced vertex stage that reads per-instance data itself must do the same ([Custom shaders](custom_shaders.md)).
- **Memory.** Each frame slot owns one device-local arena of `RendererDesc.instance_cull_bytes` (default `INSTANCE_CULL_ARENA_BYTES`, 16 MiB), so culling reserves `FRAMES_IN_FLIGHT x instance_cull_bytes` of device memory once the first range is culled. A culling pass places one 32-byte indirect command per range and a visible list of 4 bytes per instance, all or nothing per range. A range that does not fit is drawn unculled and counted in `Stats.cull_overflows`; nothing faults. `instancing` at 99,856 instances uses about 400 KB per culling pass.
- **Turning it off.** `instance_culling = false` restores the CPU-written arguments and draws every instance; nothing else changes.

Cost model. GPU work grows with instances tested: one invocation per instance per culling pass. CPU recording grows with culled ranges times culling passes: a 176-byte root and one dispatch each, plus one barrier per pass. `instancing` culls 3 ranges (two trio parities and the props) in up to 6 passes (four shadow cascades, the depth prepass, the view): 16 to 18 dispatches as the trio enters and leaves cascades. 300 batches with one range each in 6 passes would record about 1,800. Culling on against culling off at one count, 99,856 instances, WSL llvmpipe (frame counts are environment only): `cpu_record` median 23.54 ms culled against 23.41 ms unculled before the aggregate and history below, and 26 frames against 13 in the same six seconds. 170,818 of 599,151 instances were visible across passes.

Recording against instance count, one build with the grid size as the only difference, culling on, host CPU, 12-second runs:

| Props | Non-temporal `cpu_record` | Temporal `cpu_record` | Temporal ring bytes |
| --- | --- | --- | --- |
| 1,024 | 0.539 ms | 0.629 ms | 68,824 |
| 10,000 | 0.532 ms | 0.615 ms | 69,000 |
| 99,856 | 0.535 ms | 0.620 ms | 69,288 |

Before the kept aggregate and the stamped history, the same runs took 0.786, 2.850 and 23.803 ms (non-temporal) and 0.957, 3.698 and 30.903 ms (temporal, with 6.46 MB of previous matrices per frame at 99,856).

"Flat" covers a batch at rest in views that do not trace. These still walk every instance: a batch with `trace` set in a view that traces (the trace instance list), a batch whose node moves (its world-space records re-upload, 128 bytes per instance: 16.0 ms and 12.8 MB at 99,856), a batch marked every frame, and picking, per call.

| `Stats` field | Frame | Meaning |
| --- | --- | --- |
| `cull_dispatches` | This frame | Culled ranges dispatched, summed over culling passes |
| `cull_overflows` | This frame | Ranges drawn unculled because the arena was full |
| `instances_tested` | Read back, `FRAMES_IN_FLIGHT` frames late | Instances of culled ranges, summed over culling passes |
| `instances_visible` | Same frame as `instances_tested` | Instances that survived; never above `instances_tested` |
| `indirect_draws` | This frame | Unchanged: culled and unculled ranges alike |

`instances_tested` and `instances_visible` describe one earlier frame together and count culled ranges only; an aborted frame reports nothing. `stats_panel` shows them as a percentage.

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
