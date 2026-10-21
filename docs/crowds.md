# Animated crowds

A crowd draws animated copies of one model with independent playback, in one draw per mesh part, parity and pass.
Skinned, rigid and morph-only parts share one logical instance identity. `c3d::model` creates a crowd (`add_crowd`),
`c3d::anim` plays it (`crowd_update`) and `c3d::render` draws its parts through [instanced batches](instancing.md). The
component, `AnimatedCrowd`, lives in `c3d::scene`.

This page covers creating, preparing and drawing a crowd. [Animation](animation.md) owns playback: actions, layers,
masks, blend spaces, root motion semantics and event delivery.

## Quick start

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

`instances` is a `CrowdInstance[]`: a placement, a `CrowdPose` seed (`clip`, `time`, `speed`, `loop`) and a tint
(`color`) for each live instance. `pose_bounds` is an instance-local box that covers every pose of one instance.

## Concepts

- **Owner and parts.** `add_crowd` creates an `AnimatedCrowd` owner and one child `InstancedMesh` per template mesh.
  Part nodes keep an identity local transform and are removed only with the crowd node. The crowd's model must stay in
  the store while the crowd lives.
- **Instances.** Each instance has a placement, a seed pose and a tint. The instance index is the position in the
  arrays. Playback addresses an instance by a generational `CrowdInstanceId`.
- **Pose bounds.** `pose_bounds` must cover every pose of one instance. Culling and shadow fitting use nothing else.
- **Fixed capacity.** Placements, tints and playback storage allocate once, at `capacity`. The crowd holds at most
  `capacity` live instances.

## Create a crowd

`add_crowd` combines attachment and preparation. It faults `INVALID_ID`, `INVALID_ARGUMENT`, `CAPACITY_EXCEEDED` or
`UNSUPPORTED`, and a failed call leaves no crowd node.

| Argument | Meaning |
| --- | --- |
| `capacity` | Live instances the crowd can hold. |
| `pose_bounds` | Instance-local box covering every pose. |
| `instances` | Initial instances. |
| `trace` | Opt every part batch into ray tracing (default false). |
| `actions_per_instance` | Concurrent actions per instance, fixed at preparation. Default `anim::DEFAULT_CROWD_ACTIONS` (4); in `[1, 16]`. Blend-space members consume these slots. |
| `event_capacity` | Event entries across the whole crowd, fixed at preparation. Default `anim::DEFAULT_CROWD_EVENT_CAPACITY` (1024). |
| `authoring` | Optional per-instance actions, masks and spaces, captured for preparation. |

- **Admission.** Skin-free templates are valid. Every skin must have identical ordered joints and bitwise equal inverse
  binds. Distinct skeleton IDs with the same data are accepted. Incompatible bindings, invalid morph defaults and more
  instances than capacity give `INVALID_ARGUMENT`. Any live clip compatible with the captured node and morph layout may
  play. Membership in the template's clip list is not required.
- **Attach and prepare separately.** `model::attach_crowd` attaches authoring to an existing node. It copies
  capacity-sized placements, seed poses and colors, and keeps the pose bounds and the initial part trace flag. It
  creates no part nodes, palettes or assets. `model::prepare_crowd(assets, scene, node)` installs all runtime arrays and
  part batches atomically. `model::prepare_crowd_subtree(assets, scene, root = null)` attempts every pending crowd under
  `root` (null selects the whole scene), returns the first fault and keeps the owners that prepared. A failed owner
  keeps its authoring for retry. Preparing a prepared crowd is a no-op. Pending and prepared rules are in the [owner
  readiness table](owner_readiness.md).
- **Pending crowds.** `AnimatedCrowd.is_prepared()` reports readiness. A pending crowd produces no draw, and
  `crowd_update` skips it.
- **Replace instances.** `model::set_crowd(assets, scene, node, instances)` replaces the instances and the live count of
  every part atomically. Replacement, shrink, regrowth and reorder give fresh source and action generations, so old
  handles never name replacements. Placement, tint and root-motion helper edits keep playback and identity.

## Play and update

`attach_crowd` and `set_crowd` copy each input pose and its start `time` to `AnimatedCrowd.seeds`. The seed is a base
action, not writable runtime storage. Control playback through the crowd's playback state:

1. `crowd.playback.instance_id(index)` returns the `CrowdInstanceId` of a live instance, or faults `INVALID_ID`.
2. `player(id)` borrows a `CrowdPlayer`.
3. `base_action()` returns the seed action, or faults `INVALID_ID` after the application removed it. `play`, `action`,
   `stop`, `cross_fade` and the 1D and 2D blend-space controls are shared with `Animator`.

Reacquire player, action and space borrows after structural changes. Runtime time edits leave the captured start time
unchanged.

- **Update.** `anim::crowd_update` advances and samples every live instance once, restores authored defaults for missing
  tracks and publishes palettes, complete logical morph weights and affine part matrices. Mesh and bind transforms apply
  once. Sampling can run on workers over disjoint ranges ([performance](animation.md#crowd-playback-on-workers)).
- **Layers and spaces.** Regular and additive layers, boolean or weighted masks, fades, and phase-synchronized 1D and 2D
  spaces use the same evaluator as `Animator` ([animation](animation.md#two-dimensional-blend-spaces)).
  `CrowdPlayer.add_blend_space_2d` accepts 3 to `actions_per_instance` members; the 1D limit is 2 to 8. Creation faults
  atomically, and updates allocate nothing.
- **Root motion.** A crowd publishes each instance's delta in `crowd.playback.slots[index].root_motion`. Call
  `scene.apply_crowd_root_motion(crowd)` once after an update to consume each live delta. Movement stays
  application-controlled.
- **Events.** One crowd-wide buffer, `crowd.playback.events`, holds `event_count` entries. Each entry names the instance
  (slot and generation) and the fired event. The order is source slot, action order, then crossing order. A zero
  `event_capacity` drops every event. A smaller buffer keeps the fitting prefix. `events_dropped` saturates, and both
  counters reset on every advance.

## Rendering

- **Parts.** Skinned parts share one logical palette per source. Rigid and morph-only parts use their own animated mesh
  transform and keep shear under composed nonuniform scale. Morph weights are per instance and part. No per-skin palette
  or joint remapping is allocated.
- **Batch marks.** `crowd_update` marks every part batch whose records can change. Rigid and morph-only part records
  upload every frame (128 bytes per instance per part) because they follow the pose. A skinned part's records hold the
  placement and color alone, so `crowd_update` marks only the changed span with `mark_instances_range_dirty`, or nothing
  when no placement or color changed. A change of the live count marks every part whole.
- **Resident pose.** The renderer keeps each crowd's palettes and morph blocks in its own GPU memory, in logical source
  order, and every part, view, shadow layer, animated LOD part and trace pose reads them. `publish_crowd_pose` (so
  `crowd_update`) advances `AnimatedCrowd.pose_revisions[i]` when instance `i`'s palette or morph weights differ
  bytewise from its last publish. A frame uploads only the instances whose revision changed, so a paused, frozen or
  culled instance uploads nothing. `Stats.upload_bytes` counts the staged bytes.
- **Resident limit.** `RendererDesc.max_resident_crowds` (default 64, `DEFAULT_MAX_RESIDENT_CROWDS`) bounds the crowds
  holding buffers. Past it `render_view` faults `CAPACITY_EXCEEDED`. A crowd that no view, shadow layer or trace draws
  for more than `INSTANCE_ABSENCE_FRAMES` frames releases its buffers.
- **Velocity.** The velocity pass reads the previous buffers of the resident pair. A crowd part has no deformation
  history when the view did not render in the previous submitted frame, or when the crowd is new or was released. The
  frame then shows no deformation motion, while node motion and the per-instance transform history are unchanged. A view
  rendered less often than every frame therefore shows no crowd deformation motion. An animated LOD part rejects its
  history instead ([animated LOD](lod_animated.md)).
- **Compute skinning.** With [compute skinning](animation.md#compute-skinning) on, a skinned or morphed crowd part poses
  all its live sources in one dispatch per frame. Frozen and culled instances are posed too, so the dispatch costs the
  same whatever the draws show. Animated LOD parts keep vertex skinning.
- **Custom materials.** A fragment-only custom material draws with the built-in skinned instanced stage. A custom
  instanced vertex pair skins a crowd when compiled with the deformation defines ([Vertex
  contract](custom_shaders.md#vertex-contract)). Compiled without them, the crowd draws at the bind pose. Under compute
  skinning such a part keeps that vertex skinning.

## Ray tracing

Crowds enter the ray tracing paths (shadows, ambient occlusion, reflections, probes, path tracing) only through
`add_crowd(trace: true)`, which sets `trace` on every part batch. A part batch's `trace` can be edited afterwards like
any other. The default is untraced. Raster shadows and temporal views work either way.

- Instances of a traced skinned or morphed part with byte-identical palette and morph inputs share one posed trace slot
  (`Stats.trace_posed_shared`). Rigid-only parts keep the rest-geometry path.
- Raise `RendererDesc.max_posed_trace_instances` past the posed slots a scene needs. Placements beyond it are left out
  of the trace and counted in `Stats.trace_posed_overflow`.
- A slot costs the posed streams, a refit copy and a bottom level of its part, so memory scales with the number of
  distinct poses per part batch. See [posed instances](scene_trace.md#posed-instances) and [animated
  crowds](scene_trace.md#animated-crowds).

## Costs

| Storage | Cost |
| --- | --- |
| Playback payload per capacity slot | `N * Transform::size + W * float::size + M * float[]::size + A * (Action::size + AnimationActionId::size + 2 * uint::size + N * bool::size) + MAX_BLEND_SPACES * BlendSpace1D::size + CrowdPlaybackSlot::size`, where `N` is the node count, `M` the mesh count, `W` the complete logical morph width and `A` the `actions_per_instance`. |
| Two-dimensional blend rows | Reserved for every capacity slot, even with no active group ([prepared storage](animation.md#prepared-storage)). |
| Owner scratch | Copied model baselines and one pose scratch block. Each concurrent `sample_range` caller adds one from `create_crowd_pose_scratch`. Event output and crossing scratch cost `event_capacity * (CrowdEvent::size + EventBookmark::size)`. |
| Placements, tints, seeds, parts, palettes | Separate arrays; the palettes take `capacity * joints * Mat4::size`. |
| Cursors, additive references, masks | Allocated at play, sized by the clip. A captured weighted mask adds `N * float::size` per masked action. |
| Part records | 128 bytes per instance of capacity per part, on the device ([instancing](instancing.md#uploads-and-residency)). |
| Resident pose | `2 * capacity * (joints * 64 + morph_parts * 80)` bytes of device memory, where `morph_parts` counts the crowd parts and animated LOD parts that draw with morph weights. |
| Compute skinning | `capacity * vertex_count * 52` bytes per posed part; see [caps and cost](animation.md#compute-skinning). |

Allocator alignment and metadata add overhead outside these figures. Buffers allocate on first use and again when the
capacity, the joint count or a morph layout changes.

## Limits

- A crowd holds at most `capacity` instances. The capacity, `actions_per_instance` and `event_capacity` never grow.
- A view that skips frames gets no crowd deformation motion for the frame it returns.
- Compute skinning does not cover animated LOD parts.
- A crowd owner must not carry a rigid `LodGroup`. Attach [animated LOD](lod_animated.md) instead.

## Run the example

`python3 scripts/build.py --example skinned_crowd` plays 512 instances of the committed character through six of its
clips. `B` switches to 512 `Animator` instances of the same model for comparison. Options include `--baseline`,
`--compute-skinning`, `--traced-shadows` (add `--ray-queries` for the hardware kind), `--compress`, `--frozen-percent=P`
and `--compare`. `F` freezes every other instance. The panel shows resident crowd bytes, per-frame upload bytes, root
displacement and event counts.

## See also

- [Animation](animation.md) for playback, blend spaces, root motion and events.
- [Explicit instancing](instancing.md) for the part batches.
- [Whole-object LOD](lod_animated.md) for animated alternatives.
- [Scene trace](scene_trace.md) for posed trace slots.
- [Custom shaders](custom_shaders.md) for the instanced vertex stages.
