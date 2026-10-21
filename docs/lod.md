# Whole-object LOD

`c3d::scene::LodGroup` draws one object or a fixed-capacity set of placements. Each level holds geometry and material
parts with local transforms, and levels may have different part counts. A placement selects one whole level; its parts
share one source index, sway anchor and distance fade. Ordinary groups select on the CPU and instanced groups on the
GPU. Core owns both paths.

| Group | Descriptor | Page |
| --- | --- | --- |
| Rigid object or instanced placements | `LodDesc` | This page |
| Model instance or animated crowd | `AnimatedLodDesc` | [Animated LOD](lod_animated.md) |
| Terminal impostor after the mesh levels | `Impostor` | [Impostors](impostors.md) |

Automatic simplification, animated impostors and level crossfades are not supported. Placement uploads and per-view
history are relative to the [render origin](large_world.md); a change of the origin keeps the selection and its
hysteresis.

## Quick start

```c3
LodLevel[2] levels = {
    { .first_part = 0, .part_count = 2, .min_screen_size = 0.2f },
    { .first_part = 2, .part_count = 1, .min_screen_size = 0 },
};
LodPart[3] parts = {
    { .geometry = trunk, .material = bark, .local = maths::TRANSFORM_IDENTITY.to_mat4() },
    { .geometry = crown, .material = leaves, .local = crown_transform.to_mat4() },
    { .geometry = coarse_tree, .material = leaves, .local = maths::TRANSFORM_IDENTITY.to_mat4() },
};
LodDesc desc = { .levels = levels[..], .parts = parts[..] };
Node* tree = scene.add_lod_group(&assets, desc)!;
Node* forest = scene.add_instanced_lod_group(
    assets:     &assets,
    desc:       desc,
    capacity:   5000,
    transforms: placements,
    name:       "forest",
)!;
```

`tree` selects between the two levels as one object. `forest` holds up to 5,000 placements of the same object and
selects a level per placement on the GPU. `placements` is a `Transform[]`.

## Concepts

- **Levels and parts.** A level is a range of the flat `parts` array plus a minimum screen size. A part is a geometry, a
  material and a local matrix. Levels run from the finest to the coarsest.
- **Whole-level selection.** A placement draws all parts of one level. The parts share one source index, one sway anchor
  and one distance fade.
- **Ownership.** The scene owns a copy of the descriptor and the placements. Geometry, material and shader assets are
  borrowed from the store.

## Create a group

The creators copy descriptors and placements into one scene-owned block. `LodGroup` is pointer-sized. Removing the node
frees that block and never the borrowed assets. An ordinary group allocates no placement arrays. Descriptors and derived
state are read-only after creation.

`create_lod_group(allocator, &assets, desc, capacity)` creates an owning component for transfer through
`scene.add(node, group)`. Use the scene allocator. A capacity of zero selects ordinary mode; a positive capacity creates
an empty instanced group. `destroy_lod_group` frees a component that was not transferred to a scene. A rigid group owner
must not also carry another drawable, a `SkinBinding` or an `AnimatedCrowd`; use [animated LOD](lod_animated.md) to
combine LOD with a model or crowd owner.

| Descriptor rule | Value |
| --- | --- |
| Levels | 1 to `MAX_LOD_LEVELS` (5). |
| Parts | Each level has at least one part. A level's range starts where the previous one ended. Ranges leave no gap and no overlap. |
| Thresholds | Non-final `min_screen_size` values are positive, finite and strictly decreasing. The final value is zero. |
| Part matrices | Finite, nonsingular and affine. |
| Bounds override | Optional `has_bounds_override` with `local_bounds` covering every level and any custom displacement. |

| Fault | When |
| --- | --- |
| `INVALID_ARGUMENT` | The descriptor is malformed, or a placement is: a non-finite, singular or non-affine transform, or more colors than transforms. |
| `INVALID_ID` | A referenced asset is dead. |
| `UNSUPPORTED` | A geometry has skin or morph targets, or a custom material has a vertex stage but the descriptor lacks a bounds override (or, for an instanced group, the material lacks the instanced pair). |
| `CAPACITY_EXCEEDED` | Storage is exhausted, or the placements exceed `capacity`. |

Validation precedes scene mutation. A failure keeps the scene and the caller's ownership unchanged.

## Update placements

```c3
LodGroupState* state = scene.get(forest, LodGroup).state;
state.transforms[7].position.x += 2;
state.colors[7] = { 0.8f, 1, 0.8f, 1 };
scene.mark_lod_instances_dirty(forest);
```

| Call | Effect |
| --- | --- |
| `mark_lod_instances_dirty(node)` | Publishes element edits and keeps each logical slot's identity. |
| `set_lod_instances(node, transforms, colors)` | Replaces or reorders the records and resets their history. Faults `CAPACITY_EXCEEDED` above capacity and `INVALID_ARGUMENT` for malformed transforms or excess colors. |
| `resize_lod_instances(node, count)` | Keeps survivors. New slots, including regrown ones, get the identity transform, white and fresh history. Faults `CAPACITY_EXCEEDED` above capacity. |
| `publish_lod_instances(node, count)` | Publishes arrays an in-place producer filled. The caller supplies valid data within capacity. Resets placement identities and invalidates placement bounds and GPU records without validating or copying the arrays again. |

The capacity never grows. These setters apply to rigid instanced groups only. Calling `set_lod_instances`,
`resize_lod_instances` or `publish_lod_instances` on an animated group is a programming error. An ordinary animated
group follows its source owner's transform, and an attached crowd borrows its placements and colors from `AnimatedCrowd`
([animated LOD](lod_animated.md)).

## Effects

`set_lod_effects(node, effects)` copies sway, fade and the shadow and trace flags without replacing placement identities
or invalidating placement bounds and GPU records. Copy `state.effects`, edit it, then call the setter.

| `LodEffects` field | Meaning |
| --- | --- |
| `sway`, `fade` | The [instance sway and fade](instancing.md#sway-and-distance-fade) values, shared by all parts. |
| `cast_shadow`, `receive_shadow` | Shadow participation. On by default. |
| `trace` | Ray tracing participation. On by default for rigid groups. |
| `trace_sway` | Traces each instance at its swayed pose instead of its rest pose ([scene trace](scene_trace.md#what-traces)). |

A swaying group still traces, at its rest pose, unless `trace_sway` is set. While an impostor is installed, the effects
require HEIGHT sway or a zero amplitude ([impostors](impostors.md)).

## Selection

Selection uses the projected diameter of the [size sphere](#size-sphere) divided by the viewport height, multiplied by
`exp2(ViewDesc.lod_bias)`. The bias defaults to zero, and a positive bias adds detail. A non-finite bias is
`INVALID_ARGUMENT`. Resolution and render scale do not change the normalized size. Perspective uses the Euclidean
camera-to-center distance. Orthographic size is independent of distance.

- **Fresh selection** takes the first level whose minimum is no greater than the size.
- **With history**, selection coarsens below the current level's threshold and refines only above the finer threshold
  times `1 + LOD_HYSTERESIS` (1.1). Large changes cross several levels.
- **Extremes.** Zero size selects the last level and infinite size selects level zero. There is no final-size cull.
- **Bounds.** Bounds enclose every level and refresh on geometry revisions. An override covers one logical object before
  placement. Placements form an aggregate bound that the owner transform and the world-space sway reach expand. Custom
  vertex stages require an override and the common part and instance helpers.
- **History.** Each view keeps its own history per group incarnation and logical slot. Movement and reflection keep it.
  Replacement, regrowth, identity reuse and an incompatible bounds change select fresh. Pending values publish only
  after submission.
- **Resets.** `reset_view_history` resets LOD for a camera cut. Ordinary reconfiguration keeps hysteresis unless it
  recreates storage; reset explicitly when a fresh selection is required. A group absent from view preparation for
  longer than the renderer's instance absence grace period (`INSTANCE_ABSENCE_FRAMES`) loses its history.

Update animation, morphs and world transforms before preparing any view, depth, shadow, velocity or trace pass of the
frame.

### Size sphere

Selection sizes one sphere per object or placement. Its center is the center of the local bounds under the owner matrix,
composed with the placement for an instanced group. Its radius is the length of the vector whose components are each
half extent of those bounds, scaled by the length of the matching matrix axis, plus the group's world sway reach on that
component.

Turning the object leaves the radius unchanged. The world bounding box of a turned object grows by up to 1.41 times at
45 degrees and would change its level. A shear under-bounds the sphere, which selection tolerates. Culling, picking and
the spatial index keep world boxes.

Ordinary groups call `maths::transformed_box_sphere`. The instance-cull shader computes the same radius, and an
[instance quadtree](instancing_quadtree.md) sizes its nodes with it and no reach. A crowd group and any group with a
bounds override size by this rule. An animated `ModelInstance` group without an override sizes the smallest sphere
around its posed world bounds, because its bounds are posed per part.

## GPU drawing

One persistent record array keeps the original placement order. Each view selects all live placements before the pass
visibility tests, and its shadows reuse those selections, including offscreen casters. Views select independently.
`instance_culling = false` keeps the classification and disables frustum rejection.

- **Bins and transforms.** Each level and parity bin owns a visible source-index list shared by every part, and separate
  indirect arguments keep each part's geometry counts. The final rigid matrix is `owner.world * placement * part.local`,
  with the inverse transpose for normals. Placement and part reflections both affect front faces.
- **Blended parts.** Blended parts share a far-to-near list by object center within each level and parity bin. Triangles
  across parts and separate parity ranges do not interleave. In a view with `transparency = WEIGHTED`, a level whose
  blended parts all join the [weighted pass](transparency.md#weighted-transparency) takes no sorted list and no sort keys.
- **Motion vectors.** Fresh and incompatible LOD pixels write 1 into velocity alpha, and stable compatible pixels write
  0. Velocity xy and previous depth z keep their meaning. TAA, screen-space GI, temporal ambient occlusion and the
reflection history reject the flagged pixels without discarding view history. Custom stages that use
`write_mesh_outputs` inherit the part and velocity contracts.
- **Fallback.** A group whose lists do not fit the cull arena, or whose blended level holds more than
  `MAX_SORTED_INSTANCES` placements in one parity, uses level zero in every pass. The fallback may draw unculled and
  unsorted, drops temporal correspondence and selects fresh once classification resumes. Other groups may still fit. GPU
  allocation failures remain faults.

### Costs

- Persistent records reserve 160 bytes per instance of capacity: the 128-byte instance record, 16 bytes of slot metadata
  and aligned parity-index storage.
- Each group and view also reserves two 80-byte history records per instance of capacity.
- The cull arena reserves, for the main view and `max_shadow_layers` passes, 32 bytes per part and parity command plus
  an aligned 4-byte index per placement and level, and sort keys for a main bin with blended parts. The reservation is
  conservative and can exceed the actual use. The previous matrices are written by the classification pass, with no
  per-view upload.
- Per-frame selection and history work visit only the active groups. The persistent CPU history array is indexed by
  entity slot, so it scales with the scene's node capacity.
- An instanced group records one indirect draw per part of every level, and one for an installed impostor, for each
  occupied parity in each pass, whatever the selection.

## Animated models and crowds

`model::attach_animated_lod` attaches alternatives to a model instance or an animated crowd. See [animated
LOD](lod_animated.md).

## Static impostors

An `Impostor` adds a baked atlas as the terminal choice after the mesh levels. See [impostors](impostors.md).

## Other consumers

- **Picking, `SceneIndex`, triangle preparation and tracing** use the level-zero parts. Hits keep the source instance
  indices and identify group, part and geometry. The index counts one entry per level-zero part per placement ([scene
  index](picking.md#scene-index)); a capacity failure clears the count. The static-triangle restrictions apply to sway,
  custom displacement and released geometry. Coarse geometry edits do not change base trace signatures. The
  raster-selected level never changes the base trace representation.
- **Physics** colliders stay explicit.
- **Quadtree.** A node cannot hold both a [quadtree batch](instancing_quadtree.md) and a `LodGroup`:
  `Scene.set_instance_quadtree` faults `UNSUPPORTED`, and `render_view` does when the group is added afterwards.
- **Dead assets.** Retiring any referenced geometry, material or shader skips the whole group, and so do asset edits
  that invalidate its rigid or instanced form. Render and spatial adapters count one dangling group rather than drawing
  the remaining parts.
- **glTF.** The loader turns rigid node-level `MSFT_lod` into a group ([models](models.md#node-level-lod)). Deformable
  optional LOD keeps its highest-detail fallback, and required deformable LOD returns `UNSUPPORTED`. Author animated
  alternatives explicitly.
- **Foliage** accepts a copied [LOD descriptor](vegetation.md#whole-object-lod).

## Reference

| `Stats` field | Frame | Meaning |
| --- | --- | --- |
| `lod_objects_selected`, `lod_objects_visible` | Current CPU frame | Ordinary objects per level. |
| `lod_selected` | `lod_frame_index` | Logical placements per level, including shadow-only placements. |
| `lod_visible` | Same completed frame | Main-view placements, counted once across parts. |
| `lod_instances_tested` | Same completed frame | Placements submitted for classification or fallback. |
| `lod_fallbacks` | Same completed frame | Group and view reservations that used level zero. |
| `impostor_fallbacks` | Current CPU frame | Installed atlases unavailable to a group and view. |
| `lod_counts_valid` | Current publication | Completed counters are available. |

Views add to the same frame totals. Fallback visible counts describe submitted unculled placements. `Stats.triangles`
excludes listed indirect ranges. Multiply the completed visible counts by the authored per-level triangle counts for the
main-view LOD geometry work. The per-level arrays hold `MAX_LOD_CHOICES` (`MAX_LOD_LEVELS + 1`) entries: the mesh levels
plus the terminal impostor, which counts at the index equal to the group's level count. `Pass.INSTANCE_CULL` includes
selection, visibility and argument finalization; sorting is separate.

## Limits

- A group holds at most `MAX_LOD_LEVELS` levels, and a placement draws one whole level.
- Rigid groups reject skinned and morphed geometry. Animated alternatives use [animated LOD](lod_animated.md).
- A group does not cull by size. The last level draws until the placement is culled by the frustum.
- Placements, colors and the live count cannot exceed the capacity.
- Picking, indexing and tracing read the level-zero parts. Physics colliders stay explicit.

## Run the example

```bash
python3 scripts/build.py --example lod
./examples/build/lod --benchmark
```

The `lod` example draws 5,000 placements with three mesh levels and a terminal impostor. Buttons select the near, middle
and far waypoints. The bias and forced-base controls compare detail. `--frames 30` bounds a windowed smoke run. The
example selects the profiler add-on explicitly. `--benchmark` joins CPU, GPU and LOD counters by submission frame with
native validation on. It also runs a separate single-level high-detail group and saves `lod-far-impostor.png`,
`lod-far-mesh.png`, `lod-far-base.png`, `lod-high-detail-impostor.png` and `lod-high-detail-base.png`.

Manual GPU acceptance cases live in [test/gpu/render](../test/gpu/render/README.md).

## See also

- [Animated LOD](lod_animated.md) and [impostors](impostors.md).
- [Explicit instancing](instancing.md) for sway, fade and culling.
- [Views reference](views_reference.md#viewdesc) for `lod_bias`.
- [Vegetation](vegetation.md#whole-object-lod) for scattered LOD groups.
