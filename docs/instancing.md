# Explicit instancing

An `InstancedMesh` draws many copies of one geometry and one material with one draw call per pass. Each copy has its own
transform and color. Module `c3d::scene` owns the component and `c3d::render` draws it. A batch exists because the
application made one; there is no automatic batching.

| Related page | Contents |
| --- | --- |
| [Quadtree selection](instancing_quadtree.md) | Per-view level selection over a batch whose instances form a quadtree. |
| [Crowds](crowds.md) | Animated copies of one model in instanced batches. |
| [Whole-object LOD](lod.md) | Alternatives with different geometry, materials and part counts. |
| [Billboards](billboards.md), [ribbons](ribbons.md) | Camera-facing quads and strips that share [device batches](#device-batches). |

## Quick start

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

InstancedMesh* batch = scene.get(trio, InstancedMesh);
batch.transforms[1].position.y = height;
batch.colors[2] = { 0.2f, 0.4f, 1, 1 };
scene.mark_instances_dirty(trio);
```

`add_instanced_mesh` allocates `transforms` and `colors` once, at `capacity`, from the scene allocator, and copies the
slices in. Instances live in `[0, count)`. Colors past the given slice start white. Removing the node frees both arrays
and never the assets. `add_instanced_mesh` requires a `capacity` above zero. It faults `CAPACITY_EXCEEDED` when
`transforms` is longer than `capacity`, and `INVALID_ARGUMENT` for more colors than transforms, for `transforms` on a
device batch or for `mirror` on a host batch.

## Concepts

- **Node-relative records.** An instance's model matrix is `node.world * transforms[i].to_mat4()`. The renderer stores
  `transforms[i].to_mat4()` and composes the node's world on the GPU. A moved node, a moved ancestor and a change of the
  [frame origin](large_world.md) upload no record.
- **Library-owned fields.** `InstancedMesh.aggregate`, `ranges` and `revision` belong to the library. Applications do
  not write them.
- **Index is position.** The instance index is the array position, not a generational identity. It moves when the
  application reorders or resizes.
- **Sources.** `InstancedMesh.source` is `TRANSFORMS` (the default; the arrays above) or `DEVICE` (records that compute
  stages write; see [Device batches](#device-batches)).

## Edit a batch

### Mark in-place edits

Edit elements in place, then mark the batch before the `render_view` that should show the edit. The drawn records change
only through `mark_instances_dirty`, `mark_instances_range_dirty`, `set_instances` or `resize_instances`. Each advances
`InstancedMesh.revision`, which is never 0 and is compared for equality only. A mark after `render_view` takes effect in
the next frame.

An unmarked edit is not drawn, with no fault and no message. The batch bound that extraction, shadows and picking use,
the mirrored count and the view history also follow the revision, so an unmarked edit moves none of them. Scene tracing
and picking's per-instance tests read the arrays at once, so an unmarked edit does move traces and per-instance picks.

### Mark a range

When an edit touches a span of a large batch, name the span:

```c3
scene.mark_instances_range_dirty(props, first, count);
```

The call declares the instances `[first, first + count)` edited and advances the revision like `mark_instances_dirty`.
It requires `count > 0` and `first + count <= batch.count`, the live count. The renderer then packs and copies only the
span into the batch's records, and each view rewrites only the span of its motion history. The edit must stay inside the
span: nothing reads an instance outside it again.

A range mark only grows the batch bound, so an instance that moved inward leaves it loose. Culling stays correct. A
whole mark, or range marks that have covered as many instances as the batch holds, compute the bound tight again.

The batch keeps its last `INSTANCE_RANGE_MARKS` (4) range marks. A renderer slot or view history uploads the whole batch
for that frame instead of the span when:

- `INSTANCE_RANGE_MARKS` or more marks have accumulated since its last upload;
- an upload slot holds a mirrored record or the span contains a mirrored instance, because mirrored records pack after
  the others and a parity change moves every record after it (a view's motion history falls back when any instance of
  the batch mirrors);
- the live count changed since its last upload, or the capacity grew;
- it has no uploaded revision: the batch is new, its records were released, or the frame that uploaded it was aborted.

`mark_instances_dirty`, `set_instances` and `resize_instances` discard the marks, so the next upload is whole.

### Resize or replace

`resize_instances(node, count)` changes the live count and fills new slots with the identity transform and white.
`set_instances(node, transforms, colors)` replaces the live instances. Neither allocates. Both fault `CAPACITY_EXCEEDED`
past the capacity, and `set_instances` faults `INVALID_ARGUMENT` for a color slice longer than the transform slice.

## Device batches

A device batch draws records and a live count that compute stages wrote into a renderer buffer. The CPU neither packs
nor reads them. Three batch kinds have a device source: `InstancedMesh` (`InstanceSource.DEVICE`), `BillboardBatch`
([`BillboardSource.DEVICE`](billboards.md#sources)) and `RibbonBatch` ([`RibbonSource.DEVICE`](ribbons.md#sources)).
This section owns the contract they share.

Create the batch with its device source and a `capacity`, then attach the buffer:

```c3
Node* node = scene.add_instanced_mesh(
    geometry: geometry,
    material: material,
    capacity: capacity,
    source:   InstanceSource.DEVICE,
)!;
scene.set_instance_device(
    node,
    {
        .buffer         = buffer,
        .records_offset = records_offset,
        .count_offset   = count_offset,
        .capacity       = capacity,
    },
    bound,
);
```

`buffer` comes from `Renderer.create_buffer`. `Scene.set_instance_device`, `set_billboard_device` and
`set_ribbon_device` take the node, a device description and a node-local bound.

### Shared contract

- **Layout.** The buffer holds `capacity` records at `records_offset`, a multiple of 16, and one `uint` count word at
  `count_offset`, a multiple of 4. The description's `capacity` equals the batch's. The setters require both alignments
  and the capacity; core does not check the buffer size.
- **Bounds.** The setters set `has_bounds_override` and `local_bounds`. The box must contain everything the buffer can
  hold, because extraction culls the whole batch against it.
- **Ordering.** A `Renderer.dispatch` that names the buffer in `DispatchDesc.writes` orders its writes before every
  later cull and draw of the frame. Nothing on the CPU reads the count, so it may change every frame.
- **Lifetime.** A destroyed buffer skips the draw and counts in `Stats.dangling_refs`. A batch with no attached buffer
  draws nothing.
- **Arena overflow.** A batch the [cull arena](#instance-culling) cannot hold draws nothing and counts in
  `Stats.cull_overflows`, or in `Stats.sort_overflows` for a batch that sorts.
- **Records.** The records are not validated. The owner keeps them finite.
- **Excluded.** Picking and `SceneIndex` skip a device batch, and serialization faults `UNSUPPORTED` when it writes one.

### Differences by kind

| | Instances | Billboards | Ribbons |
| --- | --- | --- | --- |
| Record | `InstanceGpu`, `INSTANCE_RECORD_BYTES` (128) bytes. | `BillboardGpu`, 64 bytes. | `RibbonPointGpu`, `RIBBON_RECORD_BYTES` (48) bytes; `capacity + 1` records. |
| Record space | Node-local. The node's world applies. | Relative to `Renderer.frame_origin`. The node's world is ignored, so the node must keep an identity world. | As billboards. |
| Count word | Live instances. A count past `capacity` draws every slot. | Live records. | Live points; see [ribbons](ribbons.md#device-batches). |
| Per-record culling | Per-instance box test, with sway and fade. | Per-record sphere test; survivors sort by depth, except in a weighted view. | None; the batch culls as a whole. |
| Cull dispatch | Always runs, with an open frustum when `instance_culling` is off, because slots past the count hold stale records. | As instances. | One single-thread dispatch per view culling pass copies the segment count into the draw arguments, also with `instance_culling` off. It counts in `Stats.cull_dispatches`. |
| Attach | `set_instance_device`, `InstanceDevice` | `set_billboard_device`, `BillboardDevice` | `set_ribbon_device`, `RibbonDevice` |

Records of an instance batch are packed by `pack_instance_record` from the public `instance_record.glsl` ([public
includes](custom_shaders_reference.md#public-includes)): an affine model, a color and a seed in [0, 1). They must not mirror
space. Records draw as one range, so a negative scale draws with the wrong winding. Motion vectors follow the node
alone, because a device batch keeps no per-instance history.

A device instance batch culls in the view, its depth prepass and every shadow layer, so `cast_shadow` holds with no CPU
count. It supports no quadtree (`set_instance_quadtree` faults `UNSUPPORTED`), no `LodGroup` and no crowd.

### Host mirror

`add_instanced_mesh(mirror: true)` allocates `transforms` and `colors` at `capacity` for a device instance batch. The
owner may fill them and call `mark_instances_dirty`. Scene tracing reads the mirror and nothing else does: `trace` and
`count` apply to it as to a host batch, so the traced instances are as late as the owner makes them. Without a mirror, a
device batch is not traced.

## Drawing

- **Culling.** Extraction culls the batch as a whole against the bound of all live instances, or `local_bounds` when
  `has_bounds_override` is set. [Instance culling](#instance-culling) then tests each instance on the GPU. The node's
  world transforms the bound each frame, and [sway](#sway-and-distance-fade) grows it by its reach. `cast_shadow` and
  `receive_shadow` apply to every instance.
- **Draws.** Every batch draws through one indirect command per parity range and pass (`Stats.indirect_draws`). A
  transform whose scale product is negative mirrors space. The renderer packs unmirrored instances first and draws each
  group with its own front face, so a batch holding both makes two draws per pass.
- **Color.** The instance color multiplies the vertex color, alpha included, in every built-in material. A masked
  material cuts per instance, and its shadow matches.
- **Materials.** Opaque, masked and blended materials draw. A blended batch sorts its instances back to front in each
  view ([Blended batches](#blended-batches)) and casts a shadow only under [colored
  shadows](shadows.md#colored-shadows).
- **Deformation.** Instances draw the rest pose of the geometry, apart from the built-in [sway and
  fade](#sway-and-distance-fade). Skinning and morph targets are not applied; [crowds](crowds.md) are the animated path.
- **Motion vectors.** Each instance moves by its own previous matrix, kept per view while the batch's live count stays
  the same. After a count change the batch node's motion applies for one rendering. A batch at rest, or one whose node
  moves without an edit, draws through the node's motion with no per-instance work and no upload. At rest its velocity
  is exactly zero when its sway is off, or has frequency 0 and unchanged parameters. An edit uploads 48 bytes of history
  per edited instance. A batch marked whole every frame pays for the whole batch every frame, so mark a large batch by
  range or edit it rarely.

### Uploads and residency

The renderer keeps each batch's records in GPU memory, 128 bytes per instance of capacity, shared by every view and
shadow layer. It uploads them when the batch's revision changes or its capacity grows. A batch at rest, or under a
moving node, uploads nothing. After a range mark it uploads the marked span in one copy, except in the cases listed
under [Mark a range](#mark-a-range). `Stats.uploads` counts the uploads and `Stats.upload_bytes` the bytes staged: 128
per instance of the span, or of the batch for a whole upload. `Stats.instances` and `Stats.triangles` count the
instances and triangles of unlisted ranges across passes. Listed ranges, culled or blended, report through the counters
in [Reference](#reference).

`RendererDesc.max_instance_batches` (default 1024) bounds the batch nodes holding records: live ones plus those
unresolved within the last `INSTANCE_ABSENCE_FRAMES` frames. Past it, `render_view` faults `CAPACITY_EXCEEDED`. A batch
that no view or shadow layer draws for more than `INSTANCE_ABSENCE_FRAMES` frames releases its records and uploads them
again on its next draw. Shadow layers draw a shadow-casting batch whether or not a view sees it, so it keeps its records
while a shadow-casting light is on, unless it lies wholly past its fade band.

## Instance culling

`ViewDesc.instance_culling`, on in `default_view_desc` and `texture_view_desc`, culls every instance of a batch against
the frustum on the GPU before it is drawn. The view's shadow layers and depth prepass follow the flag of the view that
renders them. Culling is frustum only: no occlusion, no level of detail. A range of any instance count culls in one
dispatch, so no dispatch-size limit bounds a batch below its capacity. GPU work grows with the instances tested. CPU
recording grows with the listed ranges times the culling passes: one dispatch per range per pass and one barrier per
pass, so 300 batches of one range each in six passes record about 1,800 dispatches. A batch at rest in views that do not
trace costs the CPU nothing per instance. A batch with `trace` set in a view that traces, a batch marked every frame,
and picking still walk every instance.

- **Passes.** Each culling pass runs one compute dispatch per listed range: the view, its depth prepass and all of its
  shadow layers. The other passes read the ranges and dispatch nothing. `Pass.INSTANCE_CULL` times the dispatches and
  `Pass.INSTANCE_SORT` the sort steps of [blended batches](#blended-batches).
- **Bounds.** An instance is tested as the eight corners of its local box under its world matrix. The local box is the
  geometry bound, or the crowd's `pose_bounds` for a crowd part. A batch with `has_bounds_override` that is not a crowd
  part or a [device batch](#device-batches) is drawn unculled, because its override bounds the batch, not one instance.
  A swaying batch widens each plane by its sway amplitude, and a fading batch drops the instances whose collapse is
  complete.
- **Index space.** A culled range draws `gl_InstanceIndex` over its visible list. On a blended range it is the draw
  rank, 0 farthest. Built-in stages and `write_mesh_outputs` map it back with `instance_source(draw)`. A custom
  instanced vertex stage that reads per-instance data itself must do the same ([Vertex
  contract](custom_shaders_reference.md#vertex-contract)).
- **Memory.** Each frame slot owns one device-local arena of `RendererDesc.instance_cull_bytes` (default
  `INSTANCE_CULL_ARENA_BYTES`, 16 MiB), so culling reserves `FRAMES_IN_FLIGHT * instance_cull_bytes` of device memory
  once the first range is listed, which a blended batch does with culling off too. A culling pass places one 32-byte
  indirect command per listed range, then each range's visible list of 4 bytes per instance, and for a blended range its
  sort keys. A range that does not fit is drawn unculled and counted in `Stats.cull_overflows` (`Stats.sort_overflows`
  for a blended range). Nothing faults.
- **Turning it off.** `instance_culling = false` restores CPU-written draw arguments and draws every instance of opaque
  and masked batches. Blended ranges still list, with open planes, and sort.

### Blended batches

A batch whose material has `alpha_mode == BLEND` draws its instances back to front in every view, inside the batch, with
no per-instance CPU work. The cull pass writes a 64-bit key beside each visible index: the view depth of the instance's
box center under its world matrix, then its storage index. A fixed plan of bitonic compute steps sorts the keys and
rewrites the visible list far to near. Equal depths keep storage order, which holds from frame to frame.

- **Automatic.** Every blended range lists in every view, with or without instance culling and with
  `has_bounds_override`. A range the view does not cull runs the cull pass with open planes, so every instance survives
  and gets a key. The depth prepass, shadow layers and velocity pass never draw a blended range.
- **Order across draws.** Each parity range sorts on its own, the unmirrored range first. The batch orders as one unit
  among other blended draws by its bound center ([Materials](materials.md)). The key point ignores sway and custom
  vertex displacement.
- **Cost.** The sort plan is sized by the range's instance count, not its visible count. Each step is one dispatch, and
  the view's sorted ranges step together with one barrier per step round. The step count grows with the square of the
  logarithm of the count. A sorted range of `n` instances takes `32 + align8(4n) + 8 * pow2(n)` bytes of the cull arena
  per view and frame slot, where `pow2` rounds up to a power of two.
- **Overflow.** A range above `MAX_SORTED_INSTANCES` (2,097,152), or whose list and keys do not fit the arena, draws
  unsorted and unculled from CPU arguments and counts in `Stats.sort_overflows`.
- **Weighted views.** In a view with `transparency = WEIGHTED`, a batch whose material joins the [weighted
  pass](transparency.md#weighted-transparency) does not sort. Its ranges list and cull like an opaque batch's and have no
  instance limit. A batch with an `ADDITIVE` material keeps the sort in every view. The sorted order applies again when
  the view switches back to `SORTED`.

## Sway and distance fade

```c3
InstancedMesh* grass = scene.get(grass_node, InstancedMesh);
grass.sway = {
    .direction  = { 1, 0, 0.4f },
    .amplitude  = 0.15f,
    .frequency  = 0.8f,
    .lean       = 0.3f,
    .wavelength = 6,
    .variation  = 0.25f,
    .weight     = SwayWeight.VERTEX_ALPHA,
};
grass.fade = { .start = 30, .end = 60 };
```

`InstancedMesh.sway` bends a batch's vertices along one world direction. `InstancedMesh.fade` collapses its instances
over a band of camera distance. Both are values read by every `render_view`, like `cast_shadow`: an edit needs no mark,
uploads no record and leaves the kept node-local bound alone. Zero values, the `add_instanced_mesh` default, are off. A
scene-wide wind is the application's value, copied into its batches. Extraction checks the contract of the fields
(`InstancedMesh.validate_effects`).

| Field | Meaning and constraint |
| --- | --- |
| `sway.direction` | World direction of the bend. Non-zero when `amplitude` is above zero. |
| `sway.amplitude` | World units at bend weight 1. Finite, not negative. The batch bound grows by it. Zero turns sway off. |
| `sway.frequency` | Cycles per second of `FrameInfo.time`. Finite, not negative. An edit moves the phase at once. |
| `sway.lean` | Share of the amplitude held as a steady bend downwind, in [0, 1]. |
| `sway.wavelength` | World units between gust crests along `direction`. Finite, not negative. Zero keeps the batch in phase. |
| `sway.variation` | Cycles of phase spread over the instance seeds. Finite, not negative. |
| `sway.weight` | `SwayWeight.HEIGHT` (default) or `VERTEX_ALPHA`. |
| `fade.start`, `fade.end` | Camera distances where the first instances start to shrink and where none is drawn. `0 <= start < end` when `end` is set. Zero `end` turns fade off. |

- **Motion.** A vertex moves by `direction * amplitude * weight * (lean + (1 - lean) * swing)` in world space, after the
  instance matrix. `swing` never exceeds 1 in size, so no vertex moves further than `amplitude`. An instance's seed
  hashes its node-local position, so it holds under node motion and reordering. `FrameInfo` time 0, the `begin_frame`
  default, holds the sway still.
- **Weight.** `SwayWeight.HEIGHT` weighs a vertex by the square of its height within the instance-local bound, so the
  base stays planted. It assumes +Y up in geometry space, and a flat bound does not sway. `SwayWeight.VERTEX_ALPHA`
  takes the vertex color's alpha as the weight and consumes it: shading, masking, the depth prepass and shadows see
  vertex alpha 1, so the alpha does not cut a masked material. A geometry without colors then weighs 1 everywhere and
  sways rigidly. A custom vertex stage supplies any weight by writing `vertex.color.a` and selecting `VERTEX_ALPHA`
  ([Vertex contract](custom_shaders_reference.md#vertex-contract)).
- **Fade.** Each instance collapses toward the base center of its local bound once the view camera's distance to that
  point crosses the instance's vanish distance, hashed from its seed across the band. An instance takes a quarter of the
  band (`FADE_COLLAPSE_SHARE`) to collapse, and one before the band draws exactly as without fade. The cull pass drops
  fully collapsed instances, so they leave `instances_visible`. With instance culling off, or with
  `has_bounds_override`, collapsed instances of an opaque or masked batch still run the vertex stage as degenerate
  triangles.
- **Skipped batches.** Extraction skips a batch whose bound lies wholly past `end` from the view camera, in the view and
  in its shadow layers alike. It records no root, dispatch or draw, and `Stats.batches_faded` counts the skipped batches
  inside the frustum. The rendering that brings it back draws without object motion.
- **Passes and motion.** Shadows sway with the batch and fade from the view's camera, not the light's. The velocity pass
  uses the sway the view last drew the batch with, so a batch whose parameters change every frame keeps exact motion.
  The collapse carries no motion vector.
- **Trace.** `InstancedMesh.trace_sway` traces each instance at its swayed pose, off-camera instances included, through
  the posed slots of the [scene trace](scene_trace_reference.md#custom-trace-poses). The pose applies no fade. Rows past
  the posed capacity trace at rest, and `Stats.trace_sway_at_rest` counts their batch. The default is off.
- **Cost.** Sway and fade add no per-instance CPU work, and off they cost nothing. Each batch and view takes one
  128-byte block in the frame upload ring.

Picking's per-instance tests, CPU triangle trees and the scene trace see the rest pose and every instance. A swaying
batch traces at its rest pose and casts a still traced shadow unless `trace_sway` is set; `trace = false` keeps the
batch out ([scene trace](scene_trace.md#what-traces)); the error is bounded by the sway reach. Picking's broad phase
uses the grown bound. Normals and tangents are not bent. Amplitude neither varies per instance nor scales with it. There
is no fade for plain meshes, no per-view opt-out, no dithered or alpha fade, and no weight from `Geometry.custom_data`.

## Custom vertex stages

A custom material whose shader has a vertex stage draws a batch only when the shader also supplies the instanced pair,
`CustomVertex.instanced_shaded` and `instanced_depth`: the same source compiled with `INSTANCED`, and with `DEPTH_ONLY`
and `INSTANCED`. A stage that ends in `write_mesh_outputs` needs no source change and inherits the batch's sway and
fade. Without the pair the batch is skipped and counted in `Stats.dangling_refs`. A batch whose pair exists only in a
rejected replacement is skipped without a count ([Reload](custom_shaders.md#reload)).

`CustomVertex.instanced_velocity`, the same source compiled with `VELOCITY` and `INSTANCED`, is optional. It needs the
instanced pair and `velocity` ([Velocity form](custom_shaders.md#velocity-form)). Without it a batch's velocity uses the
built-in instanced variant and sees the undisplaced instances. Fragment-only custom materials draw batches unchanged.

## Quadtree selection

An `InstancedMesh` whose instances are the nodes of a quadtree selects, per view, which nodes draw. Terrain and water
use it. See [instance quadtrees](instancing_quadtree.md).

## Crowds

A crowd draws animated copies of one model through instanced part batches. See [crowds](crowds.md).

## Picking

`spatial::pick` tests a batch's bound, then each live instance, or each leaf of a [quadtree
batch](instancing_quadtree.md). A hit carries the batch node, `instanced = true` and `instance_index`. A `SceneIndex`
holds one entry per live instance, per leaf for a quadtree batch ([scene index](picking.md#scene-index)).

## Reference

### Culling and sorting counters

| `Stats` field | Frame | Meaning |
| --- | --- | --- |
| `cull_dispatches` | This frame | Listed ranges (culled or blended) dispatched, summed over culling passes. |
| `cull_overflows` | This frame | Ranges drawn unculled because the arena was full. |
| `sort_dispatches` | This frame | Sort steps dispatched, summed over blended ranges. |
| `sort_overflows` | This frame | Blended ranges drawn unsorted and unculled because they did not fit. |
| `instances_tested` | Read back, `FRAMES_IN_FLIGHT` frames late | Instances of listed ranges, summed over culling passes. |
| `instances_visible` | Same frame as `instances_tested` | Instances that survived, faded ones excluded. Never above `instances_tested`. |
| `indirect_draws` | This frame | Culled and unculled ranges alike. |
| `batches_faded` | This frame | View batches inside the frustum and wholly past their fade band. They list no range and record no draw. |
| `quadtree_fallbacks` | This frame | [Quadtree batches](instancing_quadtree.md) drawn at their leaves because the arena had no room for their lists. |
| `uploads`, `upload_bytes` | This frame | Record uploads and the bytes staged. |
| `instances`, `triangles` | This frame | Instances and triangles of unlisted ranges, across passes. |
| `dangling_refs` | This frame | Draws skipped because a referenced asset, device buffer or shader form is gone. |

`instances_tested` and `instances_visible` describe one earlier frame together and count listed ranges only. A blended
range reports through the culling counters and not through `instances` or `triangles`. An aborted frame reports nothing.

## Limits

- A batch holds `capacity` instances. The capacity never grows.
- A batch with mirrored instances makes two draws per pass.
- A blended batch sorts within itself only.
- A device batch has no quadtree, `LodGroup`, crowd, serialization or picking.
- Culling is frustum only.

## Run the example

`python3 scripts/build.py --example instancing` draws three colored cubes in one batch (one mirrored, one bobbing),
99,856 props in a single batch, eight pulsing spheres through a custom vertex stage and a blended glass cloud. A left
click reports the picked batch and instance index. `--fade-field` adds 4,096 fading cell batches, `--instance-edit` and
`--move-node` exercise the upload paths, and `--benchmark` runs the headless
[benchmark](benchmarking.md#instancing-benchmark). While it runs, `B` bobs one row of props, `U` switches that row
between range and whole marking, and `N` toggles the node motion.

## See also

- [Instance quadtrees](instancing_quadtree.md), [crowds](crowds.md), [whole-object LOD](lod.md),
  [billboards](billboards.md) and [ribbons](ribbons.md).
- [Custom shaders](custom_shaders.md) for the instanced vertex stages.
- [Large worlds](large_world.md) for the frame origin.
- [Picking](picking.md) and [scene trace](scene_trace.md) for the consumers of batches.
