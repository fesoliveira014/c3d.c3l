# Instance quadtrees

An `InstancedMesh` whose instances are the nodes of a quadtree selects, per view, which nodes draw. Every node is an
instance. The application builds the tree once and gives each instance its parent. Terrain and water use this mode
([terrain](terrain.md), [water](water.md)); this page is for applications and custom vertex stages that build their own
trees. The batch itself is described in [explicit instancing](instancing.md).

## Quick start

```c3
uint[5] parents = { scene::QUADTREE_ROOT, 0, 0, 0, 0 };
scene.get(node, InstancedMesh).trace = false;
scene.set_instance_quadtree(node, parents[..], 96, 0.25f)!;
```

Instance 0 is the root. Instances 1 to 4 are its children. The arguments after `parents` are `split_pixels` (96) and
`hysteresis` (0.25).

## Concepts

- **Tree.** `parents` holds one parent index per live instance, `scene::QUADTREE_ROOT` for a root. A leaf is an instance
  no other instance names as parent. A chain of ancestors holds at most `MAX_QUADTREE_DEPTH` (8) instances above the
  node.
- **Selection.** A node draws when every ancestor splits and it does not. A leaf never splits.
- **Per view.** Each view selects on its own, so two views at different distances draw different levels. A view's shadow
  layers and depth prepass reuse the view's selection.
- **Metric.** `QuadtreeMetric.SPHERE_PIXELS` (the default) splits by projected size. `QuadtreeMetric.BOX_RANGES` splits
  by camera distance, so a vertex stage can morph with the same numbers that select the nodes.

## Create and tune a tree

`Scene.set_instance_quadtree(node, parents, split_pixels, hysteresis)` copies `parents` into arrays the component owns,
builds the leaf mask and counts the tree's levels in `InstanceQuadtree.depth_count`. It advances
`InstanceQuadtree.revision`, which record edits never advance. It returns the batch to the sphere rule and drops any
level bounds, because they describe one topology. Empty `parents` disable the mode.

| Fault | When |
| --- | --- |
| `INVALID_ARGUMENT` | The length differs from the live count, a parent is out of range, the parents form a cycle, an instance has more than `MAX_QUADTREE_DEPTH` ancestors, or `split_pixels` or `hysteresis` is negative or not finite. |
| `UNSUPPORTED` | The batch has `trace` set, one of its instances mirrors space, its node carries a `LodGroup`, or the batch is a [device batch](instancing.md#device-batches). |

`split_pixels` and `hysteresis` may be edited on the batch after the setter. Each view reads them at its next selection
and keeps its history. Under `BOX_RANGES` the renderer notices the edit and uploads the block again. The setter
validates its arguments; an in-place value is not validated. `validate_quadtree` checks it only when the batch uploads,
so a bad value breaks the contract and degrades the selection until it is corrected. A caller that takes the values from
files or from editable state validates them first.

## Sphere rule

- **Rule.** A leaf never splits. Any other node splits when its size exceeds `split_pixels`. A node that split in the
  view's previous rendering stays split until its size falls below `split_pixels / (1 + hysteresis)`.
- **Size.** The projected height, in pixels of the view's working extent (`render_scale` included), of the sphere that
  bounds the geometry under the instance matrix. The sphere is centered on the geometry bound's center, with the radius
  taken from the lengths of the matrix axes. Turning a node never changes its size. A shear under-bounds the sphere,
  which a size for level selection tolerates. The size is infinite at the sphere's center, so a node around the camera
  splits. A [LOD group](lod.md#size-sphere) sizes by the same sphere, with its sway reach added.
- **Sway and fade.** Both apply as for any batch ([sway and fade](instancing.md#sway-and-distance-fade)). Fade applies
  after the selection.

### Passes, history and cost

One selection dispatch per quadtree batch and view records the view's selection. It counts in `Stats.cull_dispatches`
and is timed with `Pass.INSTANCE_CULL`. The view, its depth prepass and each of its shadow layers then cull over that
selection with their own frustum, so a shadow layer casts what its view draws. A quadtree batch culls even with
`instance_culling` off or `has_bounds_override` set, with open planes.

The batch reserves its lists for the view, the depth prepass and every shadow layer from the [culling
arena](instancing.md#instance-culling). When the arena has no room, the batch draws its leaves, unculled, in every pass
of that rendering, and its history is dropped. `Stats.quadtree_fallbacks` counts it.

Each view keeps the split flags of the batch's previous and current rendering. The history stays valid while the owner
entity and generation, `quadtree.revision` and the live count are unchanged. Record edits, an ordinary `configure_view`
and an origin shift keep it. `reset_view_history` invalidates it, and a view resize or destroy frees it. A batch the
view did not select for more than `INSTANCE_ABSENCE_FRAMES` frames releases the view's history of it. A submitted frame
publishes the history and an aborted one discards it. A view without a valid history selects without hysteresis.

The renderer keeps 16 bytes per instance of capacity for the batch, shared by every view, and one 104-byte `QuadtreeGpu`
block. Each view adds 8 bytes per instance of capacity. A selection invocation reads the records of its node and of at
most `MAX_QUADTREE_DEPTH` ancestors. A change of the ranges, or an in-place edit of `split_pixels` or `hysteresis`,
uploads the block again.

## Box ranges

`QuadtreeMetric.BOX_RANGES` replaces the sphere rule with the distance rule of CDLOD. The application gives the size of
each depth in batch-local units:

```c3
QuadtreeLevel[3] levels = {
    { .extent = 4, .diagonal = 5.7f },
    { .extent = 2, .diagonal = 2.9f },
    { .extent = 1, .diagonal = 1.5f },
};
scene.set_quadtree_ranges(node, levels[..], 0.25f)!;
```

`Scene.set_quadtree_ranges(node, levels, morph_band)` takes one `QuadtreeLevel` per depth of the tree, indexed by depth
with the roots at depth 0: the horizontal `extent` of a node and an upper bound of the box `diagonal` of any node of
that depth. It advances `InstanceQuadtree.parameter_revision`, never the topology revision, so every view keeps its
history and the renderer uploads the block again. Empty `levels` return the batch to `SPHERE_PIXELS`. The [serial
add-on](serialization.md) carries the metric, band and levels.

| Fault | When |
| --- | --- |
| `INVALID_ARGUMENT` | `levels.len` differs from `depth_count`, a level is not finite and positive, the hysteresis is 1 or more, `split_pixels` is not positive, or `morph_band` is outside `[0, (1 - hysteresis) / 2]`. |

### Ranges

Notation: `s` is the view's pixel scale (see [selection camera](views.md#selection-camera)), `T` is `split_pixels`, `h`
the hysteresis, `b` the morph band, and `D` the finest depth. `e` and `g` are the extent and diagonal of a depth scaled
by the largest axis scale of the node's world matrix. The range of a depth is

```
R_D = e_D s / T
R_d = max(e_d s / T, (R_{d+1} (1 + h) + g_{d+1}) / (1 - b))    for d < D
```

- **Rule.** A node of depth `d` splits when the distance from the camera to the nearest point of its box is below `R_d`,
  or below `R_d (1 + h)` when it split in the view's previous rendering. A leaf never splits. The ancestor walk,
  history, culling and shadow reuse are those of the sphere rule.
- **No pop at a merge.** A depth-`d` node's vertices morph toward the depth-`(d - 1)` surface from 0 at
  `R_{d-1} (1 - b)` to 1 at `R_{d-1}`. The recurrence makes a parent unmorphed where it merges and its children, at
  morph 1, draw the same surface, so a split or a merge does not pop. Adjacent drawn nodes differ by at most one depth,
  so no balancing pass is needed.
- **Small and wide views.** A view too small or too wide for the natural ranges `e_d s / T` raises them to the clamp,
  which draws more detail and keeps both guarantees. `b <= (1 - h) / 2` keeps the clamp ratio `(1 + h) / (1 - b)` at or
  below 2.
- **Orthographic views.** Distance gives no level difference, so the rule becomes a size test with
  `s = working_height / ortho_height`: a node of depth `d` splits when `e_d s > T`, and stays split while
  `e_d s >= T / (1 + h)`. Every node of a depth takes the same decision, so the drawn nodes of a view share one depth
  (leaves above it aside) and the morph is 0. A stage tells with `FRAME_SELECTION_ORTHOGRAPHIC`, which a shadow layer of
  the view carries as well ([selection camera](views.md#selection-camera)).
- **Vertex stages.** Under `BOX_RANGES` a [custom vertex stage](custom_shaders.md#quadtree-morph) reads the same
  `QuadtreeGpu` block through the draw's instance-effects block and calls `quadtree_morph`.

## Vertex access

A draw of a quadtree batch sets `DRAW_QUADTREE`. The block `DrawRoot.instance_effects` points at (`InstanceEffectsGpu`)
carries two more addresses:

| Field | Contents |
| --- | --- |
| `instance_quadtree` | The batch's `QuadtreeGpu`: metric, `split_pixels`, `hysteresis`, `morph_band`, `depth_count` and the levels. |
| `instance_depths` | One `uint` per instance holding the depth of its node. |

The renderer writes the depths once per topology revision and the block once per parameter revision. A stage reads its
instance's depth by the source index `instance_source(draw)` returns, and the view's camera from
`FrameRoot.selection_camera`.

## Constraints

- The batch has no mirrored instance, because records pack unmirrored instances first and a mirrored instance would move
  the records off their parents. `Scene.set_instances` faults `UNSUPPORTED` when a new transform mirrors, before it
  changes the batch.
- `trace` stays unset: tracing walks every instance.
- `Scene.resize_instances` and `Scene.set_instances` fault `UNSUPPORTED` when they change the count of a batch with a
  quadtree. Disable the mode with empty `parents` first.
- A `LodGroup` added to the node after the quadtree was set makes `render_view` fault `UNSUPPORTED`. Two selections on
  one batch are undefined.
- `InstancedMesh.validate_quadtree` states the contract the renderer checks when it uploads the batch: well-formed
  parents, finite non-negative `split_pixels` and `hysteresis`, the range bounds under `BOX_RANGES`, `trace` unset and
  no mirrored instance. An in-place edit that breaks it breaks the contract.

Picking, `SceneIndex` and impostor baking visit the leaves only, the one view-independent set that covers the tree
without overlap. `InstancedMesh.is_leaf` and `leaf_instances` expose it. The batch bound that culling and shadow fitting
use stays the union of every instance, because the renderer draws non-leaf nodes.

## Limits

- A quadtree batch has a fixed count; changing it needs the mode disabled first.
- A batch holds at most `MAX_QUADTREE_DEPTH + 1` levels.
- Under `BOX_RANGES`, an orthographic view draws one depth for all nodes (leaves above it aside) and morphs nothing.

## See also

- [Explicit instancing](instancing.md) for batches, culling and the culling arena.
- [Views](views.md#selection-camera) for the selection camera.
- [Custom shaders](custom_shaders.md#quadtree-morph) for `quadtree_morph`.
- [Terrain](terrain.md) and [water](water.md) for the trees the landscape add-on builds.
