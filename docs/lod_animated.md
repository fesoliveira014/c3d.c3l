# Animated LOD

`model::attach_animated_lod(&assets, &scene, owner, desc)` attaches whole-object alternatives to a live owner that
carries exactly one of `ModelInstance` or `AnimatedCrowd`. The alternatives share the owner's playback, skin palette and
logical morph weights. Playback and the source mesh and skin components stay with the model or crowd, and the renderer
suppresses their separate base draws. Selection, hysteresis and the other group contracts are in [whole-object
LOD](lod.md); this page covers what is specific to animated owners.

## Quick start

A model with one skinned mesh, no morph channels and a compatible coarse geometry takes an explicit two-level
descriptor:

```c3
ModelTemplate* template = &assets.model(model_id).data;
ModelMesh mesh = template.meshes[0];
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
        .default_morph_weights = mesh.default_morph_weights,
    },
    {
        .draw = {
            .geometry = coarse_geometry,
            .material = mesh.material,
            .local = maths::TRANSFORM_IDENTITY.to_mat4(),
        },
        .mesh_index = 0,
        .default_morph_weights = mesh.default_morph_weights,
    },
};
AnimatedLodDesc desc = { .levels = levels[..], .parts = parts[..] };
Node* owner = model::instantiate(&assets, &scene, model_id)!;
model::attach_animated_lod(
    assets: &assets,
    scene:  &scene,
    owner:  owner,
    desc:   desc,
)!;
```

The same descriptor attaches to an ordinary model instance or to an animated crowd of that model. Attaching to a pending
[crowd](crowds.md) is allowed; the group emits no LOD draw until preparation succeeds.

## Concepts

- **Owner.** The owner carries exactly one of `ModelInstance` or `AnimatedCrowd` and no `LodGroup`. The source model has
  no imported LOD groups.
- **Copies and borrows.** The group copies the levels, parts, the template joint list, the resolved channel mappings and
  the defaults into scene-owned storage. It reads inverse binds from the template skin's skeleton, like a `SkinBinding`.
  Caller arrays may be released after attachment. The referenced model, geometry, material and skeleton assets stay
  borrowed.
- **Logical meshes.** `AnimatedLodPart.mesh_index` identifies a logical mesh in `ModelTemplate.meshes`. Each level draws
  a representation of some of them.
- **Playback owns the pose.** Animation and crowd updates write the source state on the scene side. Renderers and
  queries only read the published source.

## Descriptor rules

| Rule | Value |
| --- | --- |
| Level zero | Lists every template mesh once, in template order. Each part's geometry and material IDs equal the template mesh's. |
| Other levels | List a logical mesh at most once, in any order. |
| Local transform | Base parts and every skinned part use an identity `draw.local`. Other rigid or morph-only alternatives may have a finite, nonsingular affine local. |
| Skin | A part is skinned exactly when its geometry is skinned. A skinned logical mesh stays skinned at every representation. A rigid logical mesh cannot acquire a skin through an alternative. |
| Source skins | All source skins share identical ordered model-local joint-node lists and bitwise-identical inverse binds. Vertex and index counts and the stored joint-index width may differ. Joint subsets, remapping and per-level palettes are unsupported. |
| Morph channels | Level zero defines the logical morph weights and defaults. An alternative may omit named channels, and its weight count follows its own geometry. A named channel it keeps must match a base name exactly and have the same default bits. Each geometry keeps its own target and in-between metadata, so weights map by name, not by target position. Unnamed weights keep their indexed identity and complete width. |
| Bounds override | An ordinary owner may set `has_bounds_override` with `local_bounds` covering all alternatives. A crowd descriptor must leave it false. |

The source `Mesh` or `InstancedMesh` geometry and material IDs must remain the template's base IDs. Source nodes, skin
bindings and joint-node identities must remain live and compatible. Keep the source geometry unchanged when selecting a
coarse level; put alternatives in the descriptor.

To change the alternatives, remove the `LodGroup` with `scene.remove_component` and attach a new descriptor. The new
group is a new incarnation. Direct edits to copied descriptor or binding data are unsupported.

## Faults

| Fault | When |
| --- | --- |
| `INVALID_ID` | A source or referenced asset is dead. |
| `INVALID_ARGUMENT` | The owner already has a `LodGroup`, or carries neither or both of the source components. A source, bind, channel or layout is incompatible. Unknown or duplicate channel mappings, non-finite defaults and conflicting defaults. A crowd descriptor with a bounds override. |
| `CAPACITY_EXCEEDED` | An allocation fails or a capacity is exceeded. |
| `UNSUPPORTED` | The source model has imported LOD groups, or a custom material stage is incompatible. |

Validation precedes publication, so a fault leaves the owner without a group.

## Bounds and placements

- **Ordinary owner.** Without an override, retained skin and morph metadata supplies the current posed bounds, including
  after a supported CPU geometry release.
- **Crowd.** The group inherits the crowd's instance-local `pose_bounds`, covering every supported clip, blend, level
  and animated rigid part under all placements. The inherited envelope is transformed conservatively under mirrored and
  nonuniform placements.
- **Placements.** An ordinary animated group uses its source owner's transform. An attached crowd borrows its placement
  and color arrays and its live count from `AnimatedCrowd`. Use the crowd's placement publication and `model::set_crowd`
  to change them. The generic placement setters of a rigid group must not be called on an animated group.
- **Identity.** Pose and placement edits keep the group identity and the selection hysteresis. A crowd replacement or
  regrowth changes the source generations. Attaching a new descriptor changes the group incarnation.
- **Effects.** The group's `LodEffects` start with shadows enabled and `trace` off. A crowd group copies
  `AnimatedCrowd.trace`. Ordinary animated parts also respect the source `Mesh.trace` flag. Change the flags through
  `set_lod_effects` ([effects](lod.md#effects)).

## Source edits

An edit that changes the revision of the source model or of a referenced geometry or skeleton skips the whole group
until it is removed and attached again. A source that is removed, stale or edited incompatibly (source mesh and joint
nodes, model, bindings or channels) skips the whole group too. Removing a crowd invalidates its group's borrowed
placements and colors.

## Drawing and history

- **Palettes.** An ordinary group uploads its palette once per renderer frame, shared by all parts, levels, views and
  traced preparation. A crowd group reads its owner's resident palettes and morph blocks
  ([crowds](crowds.md#rendering)), so nothing uploads for an instance whose pose is unchanged. There is no palette per
  skin or per selected level.
- **Parts.** Animated rigid and morph-only parts compose their sampled source mesh affine with the alternative's local
  transform and keep shear. Skinned parts use one model-space palette for the source owner, with mesh and bind
  transforms applied once. Every camera view and its shadow layers consume the same source pose and parent selection,
  including offscreen casters.
- **Deformation history.** History is kept per source owner and per view. A representation whose geometry, local
  transform, binding and channel mapping match one the view submitted last frame keeps correspondence, identical aliases
  in different levels included. An incompatible level, topology, channel, binding, incarnation or crowd replacement uses
  the current pose and rejects temporal history. Ordinary pose changes alone do not reject it. A skipped or aborted view
  publishes no new observations, so a crowd group draws with rejected history for that view after a skipped frame, while
  an ordinary crowd part loses only its deformation motion.
- **Compute skinning.** [Compute skinning](animation_deformation.md#compute-skinning) leaves animated parts on vertex skinning at
  every level. One binding that poses every source at every level would undo the savings of the levels.

### Costs

- Animated binding metadata adds copied part records, channel maps and defaults, and one ordered joint list per group.
- An ordinary group retains `joints * 64` bytes of palette and 4 bytes per logical morph weight for history.
- Temporal views additionally retain `capacity * rigid_meshes * 64` bytes of rigid affines per owner, independent of the
  level count.
- Each animated part that draws with morph weights holds its own resident morph blocks. Crowd playback storage follows
  [crowd costs](crowds.md#costs).

## Other consumers

- **Picking and `SceneIndex`.** Hits identify the level-zero logical mesh and source slot, even when a different level
  or parity or sort order draws. Picking uses conservative deformed bounds, not posed triangles. Releasing CPU data
  keeps the posed bound metadata where supported.
- **Tracing.** A traced group uses level-zero geometry and distinct scene, owner, incarnation, logical-part and
  source-slot keys. Traced skinned or morphed sources consume posed slots. Rigid-only parts use the rest-geometry path
  at their sampled affine. Capacity, overflow, same-frame sharing, still-pose reuse and the software and hardware
  behavior follow [posed instances](scene_trace_reference.md#posed-instances). Untraced groups do no posed trace work.
- **glTF.** The loader does not import deformable LOD; required deformable `MSFT_lod` returns `UNSUPPORTED` and optional
  deformable LOD keeps its highest-detail fallback. Author animated alternatives explicitly.
- **Impostors.** Installing an impostor on an animated group returns `UNSUPPORTED`.

## Limits

- No automatic simplification, per-level palettes, joint subsets or joint remapping.
- Skinned alternatives must share the template skin's joints and inverse binds.
- No impostor on an animated group.
- Compute skinning does not cover animated LOD parts.

## See also

- [Whole-object LOD](lod.md) for selection, effects and drawing.
- [Crowds](crowds.md) and [animation](animation.md).
