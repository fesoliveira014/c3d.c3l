# Animation deformation

The animation update writes node transforms and morph weights; the renderer turns them into deformed draws. This page
states what the renderer draws for skinned and morphed meshes, how bounds and animated LOD behave, and how compute
skinning poses meshes once per frame. Deformation lives in `c3d::render`; the switch is `Renderer.set_compute_skinning`.

## What deforms

- **Skinning.** A mesh node with a `SkinBinding` draws with a joint palette
  `inverse_affine(mesh.world) * joint.world * inverse_bind[i]`, computed once per renderer frame per binding and shared by
  the camera view and every shadow layer of that frame. Joint indices pack as four bytes per vertex, or four 16-bit
  values when the geometry stores any joint index above 255.
- **Morph targets.** A mesh with morph targets and a non-empty `Mesh.morph_weights` draws with its eight largest non-zero
  target weights by magnitude (`MAX_ACTIVE_MORPH_TARGETS`). The rest are dropped for that frame while the CPU weights stay
  complete. Deltas apply before skinning.
- **Channels.** `Geometry.channels` groups consecutive targets under one named weight. With an empty table (glTF and
  procedural geometry) each weight drives the target at the same index. Otherwise `Mesh.morph_weights`, default weights
  and `MORPH_WEIGHTS` tracks hold one weight per channel, and a channel's `full_weights` list the weight at which each
  of its targets applies fully. A channel weight between two adjacent keys (with an implicit key at zero that has no
  target) gives those two targets `1 - t` and `t`; past the first or last key it extrapolates. This is the FBX in-between
  shape rule. The selection of the eight largest targets happens after this mapping. Releasing a geometry's CPU arrays
  keeps its channels, so a released morphed mesh still maps weights.

### Bounds

Skinned meshes are culled, included as shadow casters and picked through a conservative bound. At insertion the store
retains, per joint, the bound of the vertices that joint influences and of their morph deltas per target
(`GeometryAsset.skin_bounds`). The bounds survive `release_geometry_cpu` and are rebuilt by `mark_geometry_dirty` and by
a stream mark that names positions, joints or weights while the streams are present. Each frame, every influencing
joint's bound, widened by the mesh's selected morph targets, is transformed by `joint.world * inverse_bind[joint]` and
merged. A `Mesh.local_bounds` override replaces it. A binding that addresses none of the geometry's joints falls back to
the rest bound, and a skinned geometry drawn without a live binding draws unskinned.

### Animated LOD

[Whole-object LOD](lod.md#animated-models-and-crowds) groups consume the same evaluated source pose and complete logical
morph weights. Attach copied alternatives to a `ModelInstance` or `AnimatedCrowd` owner with `model::attach_animated_lod`.
Selection never replaces playback or changes the source meshes' base geometry and material IDs.

- Skinned alternatives use the template skin; named morph channels map to level-zero logical weights and defaults.
- The renderer uses one model-space palette per owner and source across its parts, selected levels, views and shadows,
  not the ordinary mesh-local palette. A crowd's palettes and morph blocks stay resident on the GPU, and a frame uploads
  only the instances whose pose revision advanced ([crowds](instancing.md#crowds)).
- Animated rigid and morph-only parts use their sampled mesh affine.
- Complete animation and world updates before the frame's view, shadow, velocity and trace preparation.
- Ordinary animated LOD bounds use retained posed skin and morph metadata or an authored override; crowds inherit their
  authored pose envelope. Pose changes keep LOD hysteresis.
- Each view keeps compatible submitted deformation independently. Incompatible representations use the current pose and
  temporal rejection. Picking and opt-in posed tracing keep level-zero logical source and part identity.

Creation, lifetime, bind and channel admission and replacement rules are in
[Whole-object LOD](lod.md#animated-models-and-crowds).

### Instances and tracing

Generic skinned `InstancedMesh` bindings are not supported; animated crowds provide the shared-pose instanced path
([crowds](instancing.md#crowds)). Traced effects see the raster pose of a skinned or morphed mesh through a posing pass
([scene trace](scene_trace.md#posed-instances)). The velocity pass reads the view's previous palettes and, for a crowd,
its previous resident buffers. A view that skipped a submitted frame has none: a crowd part binds the current buffers and
gets no deformation motion for that frame, with node and instance motion unchanged, and an animated LOD part rejects the
history instead.

## Compute skinning

`Renderer.set_compute_skinning(true)` poses skinned and morphed meshes and crowd parts once a frame in a compute pass
instead of in the vertex stage of every draw. It is off by default and applies from the next frame.

With it on, every view, depth prepass, shadow layer and velocity pass of the frame draws the posed positions, normals and
tangents. Images match vertex skinning visually, not bit for bit. The posed normals are unnormalized and the vertex stage
normalizes them as before; a tangent keeps its handedness.

**Cost trade.** The pass replaces the vertex-stage skinning of every pass with one dispatch and one root upload per mesh
or crowd part per frame. It pays when a mesh is drawn by many passes (velocity, more views, cascades) or is heavy per
vertex. With few passes it can cost more GPU and CPU time than vertex skinning.

### Scope

- **Posed.** Ordinary meshes and crowd parts that are skinned, morphed or both.
- **Out of scope.** Animated LOD parts (of a crowd or a single model), plain and LOD instanced groups, and meshes with
  `Mesh.vertex_motion` keep vertex skinning, as do impostor draws. They are outside the scope, not fallbacks, and
  `Stats.compute_skinning_fallbacks` does not count them. A mesh or crowd part drawn by a material with a custom vertex
  stage also stays out, because that stage applies its own deformation.
- **Unclaimed.** A mesh or crowd part that no view, shadow layer or trace claims is not posed.

### Caps and cost

| Limit | Value | Effect past the limit |
| --- | --- | --- |
| `MAX_COMPUTE_SKINNING_BYTES` | 512 MiB | A mesh or crowd part that would push the resident posed bytes past it keeps vertex skinning as a whole. |
| `MAX_COMPUTE_SKINNING_MESHES` | 2,048 | Each posed mesh or crowd part takes one device allocation slot of the 4,096 the renderer shares. A part past the cap keeps vertex skinning. |

Each drawn mesh node and each drawn crowd part owns a pair of posed blocks, allocated on first use, reallocated when its
geometry's layout or the crowd's capacity changes and released after `INSTANCE_ABSENCE_FRAMES` frames without a draw.
A mesh costs up to 52 B per vertex (positions 12 B, normals 12 B, tangents 16 B and a second positions block of 12 B;
normals and tangents only when the geometry has them) plus two root blocks, in one device allocation. A crowd part is sized by the crowd's
capacity, whatever the live count: `capacity * vertex_count * 52 B`. A crowd with more sources than one dispatch can
address keeps vertex skinning as a whole. Exceeding a cap is never a fault, while a failed device allocation still is
one.

| `Stats` field | Meaning |
| --- | --- |
| `compute_skinned` | Meshes and crowd parts posed this frame. |
| `compute_skinning_bytes` | Resident bytes of the posed buffers after the frame. |
| `compute_skinning_fallbacks` | Pass claims of deformed meshes and crowd parts that a cap left on vertex skinning; a part drawn by three passes counts three. |
| `trace_poses`, `trace_poses_reused`, `trace_posed_bytes` | Pose dispatches the trace recorded, poses it took from a compute-skinning binding instead of dispatching, and bytes held by the trace's posed slots. |

### Recording and history

One `trace_pose` dispatch runs per mesh or crowd part per frame, recorded before the first raster pass of the view, depth
prepass or shadow layer that draws it. A crowd part's dispatch poses every live source, including frozen, culled and
off-screen ones, so a part costs the same whatever its draws show. Later passes and views of the frame reuse the pose.

The previous positions are the pose of the last submitted frame that drew the mesh. A view gets deformation motion only if
its own previous submitted frame produced that pose. Turning the switch on, a new mesh or crowd part, a reallocated block
and a view that missed the previous submitted frame bind the current pose as the previous one. So does a crowd after
`set_crowd`, which renews the playback identity of every part and instance. Node and instance motion remain; only
deformation motion drops for that frame. A view that renders every other frame therefore has no deformation motion, where
vertex skinning reuses the view's own older palette.

### Pipelines

With the switch on, `prepare_scene` creates the compute-skinning pipelines with the draw pipelines. Turning the switch on
afterwards compiles them on first use, in the first frame that draws a deformed mesh or crowd part.

### Tracing

A traced skinned or morphed mesh or crowd part claims its binding as a pass does, so a traced mesh no view draws is posed
once too, and its trace slot takes that pose instead of dispatching its own. The trace keeps its own dispatch with the
switch off, for a mesh with `Mesh.vertex_motion`, for animated LOD parts, for a mesh or crowd part past a cap and in a
preparation outside a frame. See [scene trace](scene_trace.md#posed-instances).

## Limits

- At most eight morph targets draw per mesh per frame.
- Compute skinning does not cover animated LOD parts, instanced groups, `Mesh.vertex_motion` meshes or custom vertex
  stages.
- Compute skinning keeps up to 52 B per vertex resident per posed mesh, capped at 512 MiB and 2,048 posed bindings.
- Generic skinned `InstancedMesh` bindings are unsupported.

## See also

- [Animation](animation.md) for playback.
- [Models, glTF and FBX import](models.md#skeletons-and-clips) for skins and morph targets in the store.
- [Whole-object LOD](lod.md#animated-models-and-crowds) and [Instancing](instancing.md#crowds).
- [Scene trace](scene_trace.md#posed-instances) for posed ray tracing.
