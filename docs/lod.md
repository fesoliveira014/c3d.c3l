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
| `impostor_fallbacks` | Current CPU frame | Installed atlases unavailable to a group/view |
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

## Static impostors

An optional `Impostor` adds one terminal raster choice after the mesh levels.
It borrows an ordinary texture asset and stores its subject-local bounding
sphere and atlas dimensions. Core scene types do not depend on the renderer.

```c3
scene.update_world();
Impostor baked = renderer.bake_impostor(&scene, prototype)!;
scene.set_lod_impostor(
    assets: &assets,
    node: forest,
    impostor: baked,
    min_screen_size: 0.02f,
)!;
```

Call `bake_impostor` outside a frame, with current world transforms. It captures
the visible subject subtree in subject-local coordinates, using level-zero
parts of LOD groups and the current placements of instanced meshes/groups.
Bake a single prototype when the atlas will represent each forest placement.
The capture freezes wind and fade at rest, uses an isolated unlit scene, and
does not alter source components or public views. It submits and waits for each
direction; frame indices and renderer statistics advance. Authoring is
synchronous and is unsuitable for the frame loop.
Source asset edits do not update an existing atlas; rebake explicitly after
changing the captured geometry or material.

Supported sources are rigid Standard meshes with opaque or masked coverage,
zero metallic factor, no emissive contribution, and no active occlusion map.
Base color, normal and metallic/roughness asset textures are supported.
Geometry CPU positions must remain available. Blending, wireframe, disabled
depth writes/tests, Basic/Physical/custom materials, render-target texture
references, skinning and morph targets return `UNSUPPORTED`. Released CPU
positions return `ASSET_DATA_UNAVAILABLE`; dead references return `INVALID_ID`.
Invalid dimensions, an empty subject or duplicate asset key return
`INVALID_ARGUMENT`. Exhausted asset/view/target slots return
`CAPACITY_EXCEEDED`; device allocation, format and submission faults propagate.
Validation precedes capture, and atlas insertion happens only after every
direction succeeds. Temporary ownership is released on failure.

Installation validates a live atlas, an enclosing finite positive sphere and
a finite positive threshold below the preceding mesh threshold. The effective
last mesh threshold becomes this value; the terminal threshold is zero. The
mesh descriptors remain unchanged. The sphere must enclose every authored
level, including any bounds override. It participates in common bounds, so
installing a larger sphere can change projected size and the sway/fade anchor.
Nonzero vertex-alpha sway returns `UNSUPPORTED`; use HEIGHT sway while an atlas
is installed. Later effect edits retain that programming contract.

`clear_lod_impostor` removes metadata and restores the final mesh threshold to
zero. Clearing or removing the group never deletes the texture. Retiring or
changing the atlas to an incompatible shape falls back to the last mesh in
main and shadow passes and increments `impostor_fallbacks`. Cull-arena overflow
continues to use the separate level-zero fallback. Changes to terminal metadata
invalidate temporal correspondence. `prepare_scene` prepares installed live
atlases; model preparation has no scene-installed terminal metadata.

### Atlas contract

`IMPOSTOR_DESC_DEFAULT` is an 8×8 direction grid with 128×128 texels per cell,
including a one-texel duplicated gutter on each side. The usable capture is
126×126. The resulting 1024×2048 RGBA8_UNORM texture occupies 8 MiB, has one mip,
and uses linear clamped sampling. Do not generate mipmaps or convert it to sRGB.
Accepted grid sides are 2, 4, 8, 16 and 32; cells must contain at least four
texels. Device limits still apply.

The upper square stores linear RGB and coverage. The lower square stores
subject-local octahedral normal XY, roughness and normalized linear capture
depth. Coverage comes from the captured depth, never from metallic alpha.
Bake-time nearest-surface padding fills the lower square's transparent texels
within each cell. Captured surface values and the upper coverage/color region
remain unchanged. Empty cells stay empty. This supplies a depth estimate before
projected refinement reaches coverage, without making transparent pixels opaque.
Lower attributes are sampled directly; only upper RGB is divided by coverage.
Depth spans the sphere diameter, with a maximum quantization step of
`2 * radius / 255`. Normals and other channels also have eight-bit precision.
The capture near/far planes include a margin so valid surfaces cannot equal
the reverse-Z clear value. Sampling remains inside each cell's texel centers.

For sides of four or more, directions decode the inclusive octahedral lattice
`2 * (x,y) / (side - 1) - 1`; selection uses the containing grid triangle.
Duplicate seam/pole directions use the deterministic triangle tie. A 2×2
atlas uses four tetrahedral directions instead, since four octahedral corners
would all decode to the same pole. CPU and GLSL share the direction constants
and basis convention through the generated ABI.

### Drawing and limitations

Each placement emits two triangles with no geometry-buffer read. The fragment
stages reconstruct three direction samples, blend attributes by coverage,
and write reverse-Z surface depth. Forward, deferred, depth and velocity use
the same reconstruction. Shadow passes use light-relative directions while
retaining the parent view's selected level, including offscreen casters.
Reflections and nonuniform scales use the placement transform and inverse
transpose. HEIGHT sway and fade use the shared object anchor.

Stable velocity reconstructs the same local point under the previous
placement and wind time. LOD and frame-triplet changes mark affected pixels
for temporal rejection. Histories remain independent per view and instance.
Picking, tracing, physics and spatial indexing continue to use their existing
base-mesh or explicit-collider contracts.

Reconstruction starts on the front capture plane and performs two corrections
using the sampled depth gradient. If coverage or depth consistency fails, it
tries the center plane with the same two-correction limit. Shading normals do
not drive geometry reconstruction. The rest-local ray is derived once per
fragment from inverse sway/fade and its local tangent, outside the sample loop.
Thin features, occluded surfaces and hard-normal edges remain atlas
approximations. Strong nonlinear sway need not match coarse-mesh interpolation.

The 5,000-tree benchmark retains the original coarse/base comparisons and adds
a separate high-detail source-mesh replacement case. Impostors improve the
measured detailed-mesh case but remain slower than its original 12-triangle
coarse mesh comparison. See [impostor acceptance](impostor_acceptance.md) for
geometry limits, timings and the measured conservative-depth experiment.
The benchmark saves three `lod-far-*.png` comparisons and two
`lod-high-detail-*.png` comparisons after the timed rows.

`Renderer.last_impostor_bake` reports elapsed milliseconds, atlas texel bytes,
capture attachment texel bytes, mapped readback bytes and the capture scene's
peak tracked host allocation. These are explicit allocations, not process or
driver memory measurements. GPU padding, driver caches, upload rings, retained
renderer mirrors and tracking metadata are excluded. The prospective atlas
buffer transfers to the asset store on success. Padding additionally uses one
reusable `2 * cell_size * cell_size * usz::size` scratch allocation for the bake,
262,144 bytes at the default cell size on a 64-bit host; it is freed afterward
and is not included in the existing bake-stat categories.
