# Whole-object LOD

`c3d::scene::LodGroup` draws one rigid object or a fixed-capacity set of placements.
Each level contains geometry/material parts with local transforms. Levels may
have different part counts. A placement selects one whole level; its parts share
one source index, sway anchor and distance fade.

Ordinary groups select on the CPU; instanced groups select on the GPU. Core owns
both paths. Existing `Mesh` and `InstancedMesh` behavior stays unchanged. Skins,
morphs, animated crowds and automatic simplification are outside this API.

## Creation and ownership

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
    assets: &assets,
    desc: desc,
    capacity: 5000,
    transforms: placements,
    name: "forest",
)!;
```

The creators copy descriptors and placements into one scene-owned block.
`LodGroup` is pointer-sized. Removal frees that block, never the borrowed assets.
Ordinary groups allocate no placement arrays. Descriptors and derived state are
read-only after creation.

`create_lod_group(allocator, &assets, desc, capacity)` creates an owning component
for transfer through `scene.add(node, group)`. Use the scene allocator. Capacity
zero selects ordinary mode; positive capacity creates an empty instanced group.
`destroy_lod_group` frees a component not transferred to a scene. A group owner
must not also carry another drawable, `SkinBinding` or `AnimatedCrowd`.

One through `MAX_LOD_LEVELS` (five) levels are accepted. Each has parts. Ranges
partition the flat part array without gaps or overlaps. Nonfinal thresholds are
positive, finite and strictly decreasing; the final threshold is zero. Part
matrices are finite, nonsingular and affine.

Creators report `INVALID_ARGUMENT` for malformed data, `INVALID_ID` for dead
assets, `UNSUPPORTED` for deformation or incompatible custom stages, and
`CAPACITY_EXCEEDED` for exhausted storage. Validation precedes scene mutation;
failure preserves scene and caller ownership.

## Updates and selection

```c3
LodGroupState* state = scene.get(forest, LodGroup).state;
state.transforms[7].position.x += 2;
state.colors[7] = { 0.8f, 1, 0.8f, 1 };
scene.mark_lod_instances_dirty(forest);
```

Dirty marking publishes element edits while retaining logical slot identity.
`set_lod_instances` replaces or reorders records and resets their history.
`resize_lod_instances` preserves survivors; new slots get identity/white and
fresh history, including regrown slots. Both fault `CAPACITY_EXCEEDED` above
capacity. The setter rejects malformed transforms and excess colors with
`INVALID_ARGUMENT`. Capacity never grows.

An in-place producer can fill the owned transform/color arrays and call
`publish_lod_instances(node, count)`. The caller must supply valid data within
capacity. Publication resets placement identities and invalidates placement
bounds and GPU records without validating or copying the arrays again.

`set_lod_effects` copies sway, fade and shadow/trace flags without replacing
placement identities or invalidating placement bounds and GPU records. Copy
`state.effects`, edit it, then call the setter.
Shadow and trace flags start enabled. Sway/fade follow the existing
[instancing contracts](instancing.md#sway-and-distance-fade).

Selection uses projected sphere diameter divided by viewport height, multiplied
by `exp2(ViewDesc.lod_bias)`. Bias defaults to zero; positive bias adds detail.
Nonfinite bias is `INVALID_ARGUMENT`. Resolution and render scale do not affect
normalized size. Perspective uses the existing Euclidean camera-to-center
distance; orthographic size is independent of distance.

Fresh selection takes the first level whose minimum is no greater than size.
History coarsens below the current threshold and refines only above the finer
threshold times `1 + LOD_HYSTERESIS` (1.1). Large changes cross several levels.
Zero size selects the last level; infinite size selects level zero. There is no
final-size cull.

Bounds enclose every level and refresh on geometry revisions. An override bounds
one logical object before placement and includes every level/custom displacement.
Placements form an aggregate bound; owner transforms and world-space sway reach
expand it for extraction. Custom vertex stages require an override and the
common part/instance helpers.

Each renderer view owns its history, keyed by scene, entity, group incarnation,
bounds revision and logical slot. Movement and reflection retain it. Replacement,
regrowth, identity reuse and incompatible bounds changes select fresh. Pending
values publish only after submission. `reset_view_history` resets LOD for a
camera cut. Ordinary reconfiguration retains hysteresis unless it recreates
storage; explicitly reset when fresh selection is required. Groups absent from
view preparation beyond the renderer's instance absence grace period lose their
history. Per-frame selection and history processing visit active groups, while
the persistent CPU history array remains indexed by entity slot.

## GPU drawing

One persistent record array retains original placement order. Each view selects
all live placements before pass visibility tests; its shadows reuse those
selections, including offscreen casters. Views select independently.
`instance_culling = false` retains classification and disables frustum rejection.

Each level/parity bin owns a visible source-index list shared by every part.
Separate indirect arguments preserve each part's geometry counts. The final
matrix is `owner.world * placement * part.local`; normal transforms include the
part inverse transpose. Placement and part reflections both affect front faces.
Blended parts share a far-to-near list by object center within each level/parity
bin. Triangles across parts and separate parity ranges do not interleave.

Persistent records reserve 160 bytes per instance of capacity: 128-byte instance
records, 16-byte slot metadata and aligned parity-index storage. Each group/view
also reserves two 80-byte history records per instance of capacity. Deferred
retirement protects submissions. Previous matrices are written by classification,
without separate per-view uploads.

The existing cull arena preflights nonempty parities for every level across the
main view plus `max_shadow_layers` passes. Each pass reserves 32 bytes per
part/parity command plus an aligned four-byte index per placement/level, using
the actual count in each parity. A main bin with blended parts adds
`8 * pow2(parity_count)` bytes of sort keys. Depth and color
reuse the main bin. This conservative reservation can exceed actual frame usage.

A group that cannot fit uses level zero in every pass. Persistent parity lists
preserve source indices and front faces. Fallback may draw unculled and unsorted,
invalidates temporal correspondence, and selects fresh when classification
resumes. Other groups may still fit. GPU allocation failures remain faults.

Fresh and changed LOD pixels write one into velocity alpha; stable pixels write
zero. Velocity xy and previous depth z retain their meaning. TAA and screen-space
GI reject those pixels without discarding view history. Custom stages using
`write_mesh_outputs` inherit the part and velocity contracts.

## Other consumers

Picking, `SceneIndex`, triangle preparation and software/hardware tracing use
level-zero parts. Hits preserve source instance indices and identify group,
part and geometry. Index capacity counts base parts times placements; capacity
failure clears the count. Existing static-triangle restrictions apply to sway,
custom displacement and released geometry. Coarse geometry edits do not change
base trace signatures. Physics colliders remain explicit.

Retiring any referenced geometry, material or shader skips the whole group.
Asset edits that invalidate its rigid/instanced form also skip it. Render and
spatial adapters count one dangling group rather than drawing remaining parts.
The glTF loader supports [node-level MSFT_lod](models.md#node-level-lod).
Foliage accepts a copied [LOD descriptor](vegetation.md#whole-object-lod).

## Counters and example

| Stats fields | Frame | Meaning |
| --- | --- | --- |
| `lod_objects_selected`, `lod_objects_visible` | Current CPU frame | Ordinary objects per level |
| `lod_selected` | `lod_frame_index` | Logical placements per level, including shadow-only placements |
| `lod_visible` | Same completed frame | Main-view placements, counted once across parts |
| `lod_instances_tested` | Same completed frame | Placements submitted for classification/fallback |
| `lod_fallbacks` | Same completed frame | Group/view reservations using level zero |
| `lod_counts_valid` | Current publication | Completed counters are available |

Views add to the same frame totals. Fallback visible counts describe submitted
unculled placements. `Stats.triangles` excludes listed indirect ranges. Multiply
completed visible counts by authored per-level triangle counts for main-view LOD
geometry work. `Pass.INSTANCE_CULL` includes selection, visibility and argument
finalization; sorting is separate.

```powershell
python scripts/build.py --example lod
examples/build/lod.exe --benchmark
c3c test acceptance --path test/gpu/render --test-filter test_lod_
```

The example selects the profiler add-on explicitly. Buttons select near, middle
and far waypoints; bias and forced-base controls compare detail. `--frames 30`
bounds an interactive smoke run. The benchmark joins CPU, GPU and LOD counters
by submission frame and keeps native validation enabled. See
[recorded acceptance](lod_acceptance.md) for measurements and limitations.
