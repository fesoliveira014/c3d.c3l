# Whole-object LOD

`c3d::scene::LodGroup` draws one object or a fixed-capacity set of placements.
Each level contains geometry/material parts with local transforms. Levels may
have different part counts. A placement selects one whole level; its parts share
one source index, sway anchor and distance fade.

Ordinary groups select on the CPU; instanced groups select on the GPU. Core owns
both paths. Rigid groups use `LodDesc`; models and animated crowds use an explicit
`AnimatedLodDesc` attached to their existing source owner. Animated alternatives
share that owner's playback, skin palette and logical morph weights. Automatic
simplification, animated impostors and LOD crossfades are unsupported.

Placement uploads and per-view LOD history record their [render origin](large_world.md).
Reference changes preserve selection/hysteresis and map previous placements to
the previous projection's space. Rejected history retains its rejection flag
while using the current placement as its fallback. Impostor baking selects its
own capture reference; a preceding distant scene does not affect the capture.

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
`destroy_lod_group` frees a component not transferred to a scene. A rigid group
owner must not also carry another drawable, `SkinBinding` or `AnimatedCrowd`.
Use animated attachment below to combine LOD with a model or crowd owner.

One through `MAX_LOD_LEVELS` (five) levels are accepted. Each has parts. Ranges
partition the flat part array without gaps or overlaps. Nonfinal thresholds are
positive, finite and strictly decreasing; the final threshold is zero. Part
matrices are finite, nonsingular and affine.

Rigid creators report `INVALID_ARGUMENT` for malformed data, `INVALID_ID` for dead
assets, `UNSUPPORTED` for deformation or incompatible custom stages, and
`CAPACITY_EXCEEDED` for exhausted storage. Validation precedes scene mutation;
failure preserves scene and caller ownership.

## Animated models and crowds

`model::attach_animated_lod(&assets, &scene, owner, desc)` attaches alternatives
to a live owner carrying exactly one of `ModelInstance` or `AnimatedCrowd`.
The source model must have no imported LOD groups, and the owner must have no
existing `LodGroup`. Playback and source mesh/skin components stay owned by the
model or crowd; the renderer suppresses their separate base draws. The group
copies levels, parts, joint/bind data, logical channel mappings, names and
defaults into scene-owned storage. Caller arrays may be released after attachment;
referenced model, geometry, material and skeleton assets remain borrowed.

For a model with one skinned mesh, no morph channels and a compatible coarse
geometry, an explicit two-level descriptor is:

```c3
ModelTemplate* template = &assets.model(model_id).data;
ModelMesh mesh = template.meshes[0];
ModelSkin skin = template.skins[0];
LodLevel[2] levels = {
    { .first_part = 0, .part_count = 1, .min_screen_size = 0.2f },
    { .first_part = 1, .part_count = 1, .min_screen_size = 0 },
};
AnimatedLodPart[2] parts = {
    {
        .draw = {
            .geometry = mesh.geometry,
            .material = mesh.material,
            .local = maths::TRANSFORM_IDENTITY.to_mat4(),
        },
        .mesh_index = 0,
        .skin = skin,
        .default_morph_weights = mesh.default_morph_weights,
    },
    {
        .draw = {
            .geometry = coarse_geometry,
            .material = mesh.material,
            .local = maths::TRANSFORM_IDENTITY.to_mat4(),
        },
        .mesh_index = 0,
        .skin = skin,
        .default_morph_weights = mesh.default_morph_weights,
    },
};
AnimatedLodDesc desc = { .levels = levels[..], .parts = parts[..] };
Node* owner = model::instantiate(&assets, &scene, model_id)!;
model::attach_animated_lod(
    assets: &assets,
    scene: &scene,
    owner: owner,
    desc: desc,
)!;
```

The same descriptor can attach to an ordinary model instance or an animated
crowd using that model. Attachment to a pending crowd is allowed; it emits no
LOD draws until crowd preparation succeeds. `mesh_index` identifies the logical mesh in
`ModelTemplate.meshes`, independent of flat part order. Each level may contain a
logical mesh at most once; level zero contains every template mesh exactly once.
Its geometry and material IDs must equal the template mesh's IDs. Every base
part and every skinned part uses an identity `draw.local`; other rigid or
morph-only alternatives may have an additional finite nonsingular affine local.

Source `Mesh`/`InstancedMesh` geometry and material IDs must remain the template's
base IDs. Source nodes, skin bindings and joint-node identities must remain live
and compatible. Keep source geometry unchanged when selecting a coarse level;
put alternatives in the descriptor. `model::replace_animated_lod` validates and
copies a complete replacement before swapping it, preserving the old group on
failure. Replacement creates a new group incarnation; direct edits to copied
descriptor/binding data are unsupported.

All source skins and skinned alternatives share identical ordered model-local
joint-node lists and bitwise-identical inverse binds. Vertex/index counts and
stored joint-index width may differ; joint subsets, remapping and per-level
palettes are unsupported. A skinned logical mesh stays skinned at every
representation. Rigid logical meshes cannot acquire a skin through an alternative.

Level zero defines logical morph weights and defaults. Named alternatives may
omit channels. Each selected channel must match a base name exactly and have
the same default bits. Each geometry keeps its own target/in-between metadata; weights map by
name rather than target position. Unnamed weights retain their indexed identity
and complete width. Unknown/duplicate mappings, nonfinite defaults and conflicting
defaults are `INVALID_ARGUMENT` before publication.

Attachment/replacement return `INVALID_ID` for dead sources/assets,
`INVALID_ARGUMENT` for source, bind, channel or layout incompatibility,
`CAPACITY_EXCEEDED` for allocation/capacity failure, and `UNSUPPORTED` for a source
with imported LOD groups or incompatible custom stages. Rendering and spatial
queries reacquire the source through `model::sync_animated_lod`; invalid source
edits skip the whole group rather than drawing a surviving subset.

An ordinary owner may provide `has_bounds_override` and `local_bounds` covering
all its alternatives. Without an override, retained skin/morph metadata supplies
current posed bounds, including after supported CPU geometry release. A crowd
descriptor must leave `has_bounds_override` false: its group inherits the crowd's
instance-local `pose_bounds`, covering every supported clip, blend, level and
animated rigid part under all placements. The inherited envelope is transformed
conservatively under mirrored and nonuniform placements.

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

These generic placement setters apply only to rigid groups. Animated groups
reject `set_lod_instances` and `resize_lod_instances` with `INVALID_ARGUMENT`;
`publish_lod_instances` requires a nonanimated group. Attached crowds borrow
placement/color arrays and live count from `AnimatedCrowd`; use its placement
publication and `model::set_crowd` replacement operations. Ordinary animated
groups use their source owner's transform. Pose/placement edits retain group
identity and selection hysteresis; crowd replacement/regrowth changes source
generations while descriptor replacement changes group incarnation.

`set_lod_effects` copies sway, fade and shadow/trace flags without replacing
placement identities or invalidating placement bounds and GPU records. Copy
`state.effects`, edit it, then call the setter.
Shadow and trace flags start enabled for rigid and ordinary animated groups.
An attached crowd's initial group trace flag copies `AnimatedCrowd.trace`, false
by default. Edit the copied group effects through `set_lod_effects` to change
its trace participation. Ordinary animated parts also respect the source
`Mesh.trace` flag. Sway/fade follow the existing
[instancing contracts](instancing.md#sway-and-distance-fade). A swaying group still traces, at its rest
pose ([scene trace](scene_trace.md#what-traces)).

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

Animated deformation history also distinguishes logical mesh/part, source slot
generation and selected representation. Compatible unchanged geometry, local
transform, binding and channel mapping can reuse the view's previous submitted
pose, including identical aliases in different levels. An incompatible level,
topology, channel, binding or incarnation uses current-pose fallback and rejection;
ordinary pose changes alone do not reject correspondence. Skipped/aborted views
do not publish new observations. Update animation, morphs and world transforms
before preparing any view, depth, shadow, velocity or trace pass of the frame.

## GPU drawing

One persistent record array retains original placement order. Each view selects
all live placements before pass visibility tests; its shadows reuse those
selections, including offscreen casters. Views select independently.
`instance_culling = false` retains classification and disables frustum rejection.

Each level/parity bin owns a visible source-index list shared by every part.
Separate indirect arguments preserve each part's geometry counts. The final
rigid-group matrix is `owner.world * placement * part.local`; normal transforms include the
part inverse transpose. Placement and part reflections both affect front faces.
Blended parts share a far-to-near list by object center within each level/parity
bin. Triangles across parts and separate parity ranges do not interleave.

Animated rigid and morph-only parts instead compose their sampled source mesh
affine with the alternative's local transform, retaining shear. Skinned parts
use one model-space palette for the source owner, with mesh/bind transforms
applied once. Per-part parity uses the complete composed transform. Every
camera view and its shadow layers consume the same fixed source pose and parent
selection, including offscreen casters; sorting/visible lists carry logical
source indices rather than owning animation history.

Persistent records reserve 160 bytes per instance of capacity: 128-byte instance
records, 16-byte slot metadata and aligned parity-index storage. Each group/view
also reserves two 80-byte history records per instance of capacity. Deferred
retirement protects submissions. Previous matrices are written by classification,
without separate per-view uploads.

Animated binding metadata adds copied part records, channel maps/defaults and
one ordered joint/bind array per group. Current palette upload is
`live_sources * joints * 64` bytes once per group per renderer frame, reused across
parts, levels, views and traced preparation in that frame. Ordinary groups have
one source; crowd groups have one per live placement. This is shared palette data,
not a palette per skin or selected level. Morph blocks and rigid affine data are
per representation/source as needed. Temporal views additionally retain submitted
palette, morph and instance data for compatible logical representations; the
160-byte placement and paired 80-byte selection rows above exclude that storage.
Crowd playback storage follows the [crowd byte formula](instancing.md#crowds).

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

Fresh and incompatible LOD pixels write one into velocity alpha; stable compatible pixels write
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

Animated hits identify the level-zero logical mesh and source slot, even when a
different level or parity/sort order draws. Deformed picking uses conservative
bounds; it does not perform posed-triangle picking. CPU release retains posed
bound metadata where supported.

Traced animated groups use level-zero geometry and distinct
scene/owner/incarnation/logical-part/source-slot keys. Traced skinned or morphed
sources consume posed slots; rigid-only parts use the rest-geometry path at their
sampled affine. Capacity/overflow, same-frame sharing, still-pose reuse and
software/hardware behavior follow [posed instances](scene_trace.md#posed-instances).
The raster-selected coarse level never changes the base trace representation.
Untraced groups do no posed trace work.

Retiring any referenced geometry, material or shader skips the whole group.
Asset edits that invalidate its rigid/instanced form also skip it. Render and
spatial adapters count one dangling group rather than drawing remaining parts.
Animated groups also require live compatible source mesh/joint nodes, source model,
bindings and channels. Source removal or incompatible edits skip the whole group.
The glTF loader supports rigid [node-level MSFT_lod](models.md#node-level-lod);
deformable optional LOD keeps its highest-detail fallback and required deformable
LOD returns `UNSUPPORTED`. Author animated alternatives explicitly. Animated
impostor installation returns `UNSUPPORTED`.
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
