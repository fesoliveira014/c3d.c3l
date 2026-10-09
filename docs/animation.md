# Animation

`c3d::anim` plays the clips a model import stored onto a model instance. The
application owns the update sequence; nothing in the scene graph or the
renderer advances an animation.

## Update sequence

```c3
anim::update(&assets, &scene, dt);
scene.update_world();
renderer.render(&scene, camera_node)!;
```

`anim::update` advances every action, samples its clip and writes the local
transforms of the instance nodes and the morph weights of the instance meshes.
`Scene.update_world` turns the locals into world matrices. The renderer reads
the pose it finds. Physics and IK, when present, run between the animation
update and the final `update_world` ([Inverse kinematics](#inverse-kinematics)).

## Animator and actions

An `Animator` is a component on the synthetic root that `model::instantiate`
returns. It owns a fixed pool of 16 actions, addressed by `AnimationActionId`.
The pool header, live-ID order, events, blend spaces and model-sized mask rows
live in one per-animator heap block. The scene component contains only pointers,
counts and the last motion delta (152 bytes on x64).

The fixed component store reserves a slot for every possible scene node,
including unused slots. At the default 16,385 slots (16,384 nodes plus the scene
root), Animator values occupy 2,490,520 bytes, about 2.375 MiB per scene. ECS
index arrays and allocations for live animators are additional.

```c3
Node* left = model::instantiate(&assets, &scene, model)!;
Node* right = model::instantiate(&assets, &scene, model)!;
ClipId[] clips = scene.get(left, ModelInstance).clips;

Animator* left_animator = anim::add_animator(&scene, left);
left_animator.play(&assets, clips[0])!;

Animator* right_animator = anim::add_animator(&scene, right);
AnimationActionId run = right_animator.play(&assets, clips[1])!;
right_animator.action(run).speed = 1.5f;
```

`play` validates the clip's model-local targets and returns its ID at time zero,
weight one, looping. It faults
`INVALID_ID` for a dead clip and `INVALID_ARGUMENT` for a clip that does not
fit the instance (a target beyond the node table, a morph target outside its
mesh table, or a present mesh with a different morph count), or an invalid
layer, fade or mask.
`CAPACITY_EXCEEDED` means all 16 action slots are live. `stop(action)` removes the action;
`stop(action, seconds)` fades it out first. `cross_fade(from, to, seconds)`
fades one action out while the other fades to full weight. Use
`play(&assets, clip, { .fade_in = seconds })` to start at zero and fade in.
Both stop and cross_fade return optionals: stale IDs fault `INVALID_ID`, invalid
durations or a cross-fade to the same ID fault `INVALID_ARGUMENT`. They validate
before changing either action. This includes IDs whose fade-out already ended.

IDs survive other plays/removals and are meaningful only with the animator that
issued them. A removed generation never resolves to its replacement while that
animator lives. Destroying/recreating the animator starts a new owner; discard
its old IDs.
`try_action(id)` faults `INVALID_ID`; `action(id)` borrows a known-live action.
Retain IDs and reacquire action pointers after structural action operations;
reacquire Animator pointers after component-store changes. Iterate
`order[:action_count]` for live IDs in play order.

`Action.time`, `speed`, `weight`, `loop` and `playing` are runtime controls;
numeric values must be finite and weight nonnegative. `playing` gates only the
clock, so paused actions still pose. Clip, layer, additive mode, masks and
reference arrays are captured/library-owned. Recreate an action to change them.
Clip tracks, duration and target mappings must remain unchanged and live during
playback. Root mode/yaw and sampling data are captured too. Blend-space members
are read-only; their space controls playback.

While an animator exists it owns the pose of its instance: every update writes
every present instance node's local transform and every present instance mesh's
morph weights.
The synthetic root is not an instance node and stays under application control,
so moving or spinning an instance as a whole is unaffected. Removing the root
removes the animator and its arrays through the ordinary component hook; the
shared clips stay in the store.

## Replacing clips and models

A clip replacement keeps its track layout (see [Models](models.md#replacing-geometry-skeletons-and-clips)), so animators
re-seek on the next update. A model replacement may grow the template's clip list. A prepared crowd sized its cursors from
the longest clip it saw at `prepare_crowd`; `set_crowd` faults with `INVALID_ARGUMENT` for a clip with more tracks than
that, and the crowd must be removed and added again.

## Removed instance nodes

`ModelInstance.present_node(template_index)` borrows the original node or returns
null after removal. Each pointer has a captured `Entity` identity; slot reuse
cannot bind a template index to the replacement node. The captured identities,
node table, authored baselines and mesh indices retain their original extents.
They are library-owned and must not be rebound. Use the accessor before reading
a template node; `Animator.nodes` is only a borrowed alias of the pointer table.
The identity check follows the scene's generational-ID lifetime assumption:
a stale identity must not survive generation wrap and become equal again.

Animation skips tracks for absent nodes and morph tracks for removed `Mesh`
components. A missing root-motion target contributes no motion. Actions retain
their clips, modes, masks and playback state, and surviving tracks continue.
Reparenting a live template node outside the instance subtree preserves its
identity and animation membership.

`SkinBinding.joints` remains a borrowed array of live joint nodes. Every joint
must stay live while its binding is used for skinning, bounds or joint search.
Remove dependent bindings before removing their joints; the model accessor
does not make dead skin joints recoverable.

## Layers and masks

`PlayDesc.layer` selects one of four layers, folded in ascending index. Layer 0
starts from the authored baseline; upper layers start from the result below.
Play order does not change the order of layers. A channel with no contribution
on a layer retains its lower result.

Masks address model-local nodes, including morph-bearing mesh nodes. Their
storage is sized once from the model; there is no 512-node limit. The caller
owns a `JointMask`, and play copies it into one of the animator's preallocated
mask rows. A null mask selects all nodes; an all-false mask selects none.

Inside a fallible function, after adding the animator, with a live model and
an overlay clip targeting that model:

```c3
String[1] names = { "mixamorig:Spine1" };
JointMask upper = anim::create_joint_mask(mem, &assets.model(model).data, names[..])!;
defer anim::destroy_joint_mask(&upper);

AnimationActionId overlay = animator.play(&assets, overlay_clip, {
    .fade_in = 0.2f,
    .layer = 1,
    .mask = &upper,
})!;
animator.action(overlay).weight = 0.5f;
```

Use the model's actual names. Every exact match is selected; descendants are
included by default. Pass `include_descendants: false` for only matching nodes.
A missing name faults `NOT_FOUND` before allocation. Repeated requested names
are harmless and an empty name list produces empty membership. Play rejects a
mask with a different node count. Reuse a mask only with instances of the model
whose indices it describes. Destroying/editing the input mask after play does
not alter existing actions.

### Regular blending

Each channel (translation, rotation, scale, and each morph weight array) is
blended separately against the lower layer's value (the authored baseline on
layer zero):

```plain text
total    = sum of weights of the actions whose clip animates this channel
residual = max(0, 1 - total)
value    = (sum of weight * sample + residual * below) / max(1, total)
```

A lone action at weight 0.25 sampling translation 8 over baseline 0 yields 2.
A rotation-only clip leaves translation and scale at their authored values. Two
actions at weight 1 average. Rotations are sign-aligned to the lower pose's
hemisphere before summing and normalized afterwards.

## Additive actions

Set `PlayDesc.additive = true`. Play captures each track's sample at time zero
once, including the value rather than tangent fields of cubic keys. Each layer
first folds regular actions, then applies its additive actions in play order.

Translation, scale and morphs add `weight * (sample - reference)`. Rotation uses
`reference.conjugate() * sample`, aligns that delta to identity, interpolates
from identity by weight, then postmultiplies the current rotation and normalizes.
Additive order matters for noncommuting rotations. A time-zero action adds
nothing; a half-weight 45-degree delta applies 22.5 degrees. Scale is additive,
not multiplicative. Masks apply to every channel.

An additive action keeps the reference pose it sampled at `play` until it is played again. After
`replace_clip_owned`, running actions re-seek on the new tracks, but an additive action's reference pose and
the root-motion state stay as sampled from the old clip until the action is played again.

Animation owns the final pose until later physics/IK writers run. There is no
scheduler or automatic motion consumption. Root motion and events are outputs for
the application to consume. Per-frame
scratch remains in the existing temporary allocator; captured masks, reference
samples and cursors retain their resource lifetimes.

## Root motion

`PlayDesc.root_motion` defaults to `RootMotion.KEEP`. Runtime `STRIP_XZ` pins
root X/Z at the clip's first sample and retains vertical motion. `EXTRACT` pins
the same channels and publishes `Animator.root_motion`; animation never moves
the instance root. Import clips with `RootMotion.KEEP` to retain this data.
The enum and `NO_ROOT_NODE` now belong to `c3d::anim`, including when used in
`RetargetOptions`.

```c3
animator.play(&assets, walk, { .root_motion = RootMotion.EXTRACT })!;
anim::update(&assets, &scene, dt);
anim::apply_root_motion(instance_root, animator.root_motion);
scene.update_world();
```

The selected root is the first skin's first joint whose parent is outside that
skin. An unskinned model defaults to `NO_ROOT_NODE`; set `animator.root_node` to
a model-local index before playing to override it. Keep the selection fixed
while actions live. Root and intermediate ancestors use `PARENT` transform
space. Ancestors between the joint and instance root must retain their authored
transforms; their basis is captured at play. The instance root itself may use
either transform space.

`root_yaw = true` additionally removes the root rotation's Y twist and emits
the turn; tilt remains in the pose. Extraction requires upright, positive,
uniform scale through the captured basis and instance root, retained throughout
playback. Arbitrary-up motion and animated root ancestors are unsupported.
Missing root configuration, unsupported yaw basis, yaw with KEEP, and non-KEEP
additive actions fault `INVALID_ARGUMENT` before allocating an action.

Deltas are planar transforms in the instance root's frame. The helper applies
translation through the node's authored rotation/scale, then postmultiplies the
turn. Apply each delta once; it resets to zero translation and identity rotation
every update. Reverse and multi-loop updates compose cycle transforms. A single
action's consumed path is invariant under subdivision within sampling tolerance.
Masks and regular layer weights apply to motion as to pose; KEEP/STRIP root
channels contribute zero motion with their weight. A half-weight extractor
therefore emits half displacement. Yaw contributions use signed shortest turns;
mixing actions does not promise subdivision-invariant blended trajectories.

`Action.time` edits seek to a new starting sample. The seek itself emits no
motion or events; the subsequent clock step does. Internal double clocks retain
subframe precision independently of the public float sampling time. `dt` is
finite and nonnegative, speed may be negative, and clocks must remain finite
and representable. Paused, zero-step and zero-duration actions emit no movement.

## Clip events

```c3
ClipEvent[2] footsteps = {
    { .time = 0, .id = 1 },
    { .time = assets.clip(walk).data.duration * 0.5f, .id = 2 },
};
assets.set_clip_events(walk, footsteps[..])!;
```

The setter copies and stably sorts events by time. IDs are application-defined;
no callback or importer event parser is installed. Invalid times (nonfinite or
outside `[0,duration]`) fault `INVALID_ARGUMENT`; a dead clip faults `INVALID_ID`.
Failure leaves the old table intact. Replacing a table between updates is valid.
`add_clip_owned` instead takes ownership of an already sorted valid table.
Retargeting copies events into independent owned arrays.

After update, read `animator.events[:animator.event_count]`. Each `FiredEvent`
contains action ID, clip ID, authored ID and time. Every retained advancing
action reports, including zero-weight blend-space members. Fully faded actions
are removed before publication. Delivery follows action play order, then time
crossing order within each action; equal-time markers keep their authored order.
Applications can filter by current action weight, as the Mixamo example does.

Forward intervals include the starting instant and exclude the ending instant;
reverse intervals do the opposite. Terminal endpoints are included when a
non-looping action stops. At a loop seam, the closing marker (duration forward,
zero backward) fires on arrival; the opening marker fires on continuing into
the next cycle. A step spanning both delivers closing before opening. Reverse
playback from zero starts at the equivalent duration boundary. Pauses and seeks
alone fire nothing. The fixed buffer retains the first 16 crossings per update;
`events_dropped` counts the rest, saturating at `uint::max`. Both counts reset
every update. Large time steps count crossings without iterating elapsed loops.

## One-dimensional blend spaces

```c3
ClipId[2] locomotion = { walk, run };
float[2] positions = { 0, 1 };
BlendSpace1D* space = animator.add_blend_space(
    assets: &assets,
    clips: locomotion[..],
    positions: positions[..],
    desc: { .root_motion = RootMotion.EXTRACT },
)!;
space.parameter = 0.5f;
```

An animator owns two fixed space slots, each with 2–8 actions. Positions must be
finite and strictly ascending, and clip durations finite and positive. Dead
clips fault `INVALID_ID`, invalid inputs/configuration fault `INVALID_ARGUMENT`,
and exhausted space/action slots fault `CAPACITY_EXCEEDED`. Creation rolls back
all new actions on failure.

The parameter clamps to the authored range. Only its two neighbors receive
weights, summing to `space.weight`. All members share a normalized double phase
advanced by `dt * speed / weighted_duration`; group weight does not affect speed.
Set `playing = false` to pause the phase while still adjusting the blend. Keep
parameter/speed/phase finite, phase in `[0,1)`, and weight in `[0,1]`.

The space owns member time, weight, loop, playing and fade fields. Members are
looping with `playing = false`; root motion and events use their shared clock.
Independent stop/cross_fade faults `INVALID_ARGUMENT`. Use
`stop_blend_space(space, fade_out)` or
`fade_blend_space(space, target_weight, duration)` instead. Fade-to-zero removes
every member. Pointers are short-lived borrows: reacquire through
`animator.blend_spaces[slot]` after animator-store changes and discard after
removal/reuse. The inspector exposes group controls and displays member state.

## Layered example and CPU measurements

`mixamo` shows a regular masked wave on the left and an additive wave on the
right, both over locomotion. The wave is authored at setup from the loaded
model's rest pose and `Spine1`/`LeftArm`/`LeftForeArm` names; missing joints disable
that demonstration with a message. No extra animation download is required.
`W`/`S` adjust the left walk/run blend; `R` toggles applying its extracted motion.
`G` and `A` toggle the waves, `1`–`9` cross-fade the right in-place clip, `Q` changes
the space weight and Space pauses. Authored footsteps from the dominant member
print to the console. The Scene panel's animator inspector shows clip IDs, layer,
mode, mask count and playback controls; stop is applied after traversal.

The animation, IK and Mixamo examples accept `--frames=100 --acceptance` for a
bounded validation run that exercises playback changes. Mixamo additionally
accepts `--capture=path` for a 1440x900 RGBA8 scene capture.

```powershell
c3c build mixamo --path examples -O3 --lib c3d_profile -D C3D_PROFILE_CPU -D C3D_PROFILE_INTERNAL
examples/build/mixamo.exe --benchmark
```

The CPU-only benchmark reads the existing `anim.update` capture scope for one
Mixamo instance. It warms 300 updates and measures 5,000 at a fixed 60 Hz step;
loading, mask creation and reference sampling are outside the measured interval.

The benchmark also prints `animator,component_bytes,152`: about 2.375 MiB of
Animator values at the default scene capacity, compared with 1.125 MiB for the
72-byte component before runtime motion. The inline motion value and output
slices are retained for direct access; event and blend-space arrays remain in
the per-animator heap block.

Windows x64, i9-14900K, C3 0.8.3 `-O3`, CPU+INTERNAL profiling; medians of three
run means:

| Case | Nodes | Tracks | Actions | CPU mean |
| --- | ---: | ---: | ---: | ---: |
| Single action before runtime motion | 69 | 105 | 1 | 0.001157 ms |
| Single action with runtime support | 69 | 105 | 1 | 0.001191 ms |
| Base plus masked regular wave | 69 | 312 | 2 | 0.002727 ms |
| Base, masked regular and additive waves | 69 | 519 | 3 | 0.006146 ms |
| Two-clip space with extracted motion | 69 | 210 | 2 | 0.002320 ms |
| Equivalent three base actions plus masked layer, before | 69 | 522 | 4 | 0.003476 ms |
| Three-clip space with motion plus masked layer | 69 | 522 | 4 | 0.003745 ms |

The comparison baseline is `b103615`. The three-clip workload uses walk, run and
a repeated walk slot, parameter 0.5: neighbor weights 0.5/0.5 and an inactive
third neighbor, plus the masked wave. The baseline uses the same clips/weights
with independent clocks; it has no space or runtime extraction. This compares
the equivalent pose workload before and after adding phase and motion work.
Single-action run means ranged 0.001150–0.001180 ms before and
0.001186–0.001346 ms after; four-action means ranged 0.003421–0.003558 ms before
and 0.003631–0.003759 ms after. These measurements do not justify an executor.
They do not establish performance at crowd scale. WSL verification is build/CPU
only.

The benchmark also consumes ten walk loops at 60 Hz (a shortened final step),
then compares displacement with ten clip cycles. This rig travels 17.695213 m
with 0.000017166 m drift, below the 0.001 m limit. This is a CPU motion check;
no GPU timing is included. The default example separately runs with Vulkan
validation on Windows.

![Extracted walk/run motion on the left and the in-place comparison on the right](images/animation_motion.png)

## Sampling

`sample_track` clamps to the key range, steps forward from the previous key
through the action's cursor and re-seeks by binary search after any backwards
jump, so wraps, seeks and negative speeds cost one search. `STEP` holds the
previous key; `LINEAR` interpolates per element, with rotations taking the
short path and using slerp when the keys are more than 0.1 rad apart;
`CUBIC_SPLINE` evaluates the glTF Hermite form with tangents scaled by the
segment duration.

## What deforms

The animation update writes node transforms and morph weights; the renderer
turns them into deformed draws:

- A mesh node with `SkinBinding` draws with a joint palette
  `inverse_affine(mesh.world) * joint.world * inverse_bind[i]`, computed once
  per renderer frame per binding and shared by the camera view and every
  shadow layer of that frame. Joint indices pack as four bytes per vertex, or
  four 16-bit values when a skin addresses more than 256 joints.
- A mesh with morph targets and a non-empty `Mesh.morph_weights` draws with
  its eight largest non-zero target weights by magnitude; the rest are dropped
  for that frame while the CPU weights stay complete. Deltas apply before
  skinning.
- `Geometry.channels` groups consecutive targets under one named weight. When
  the table is empty (glTF and procedural geometry), each weight drives the
  target at the same index. Otherwise `Mesh.morph_weights`, default weights and
  `MORPH_WEIGHTS` tracks hold one weight per channel, and a channel's
  `full_weights` list the weight at which each of its targets applies fully.
  A channel weight between two adjacent keys (with an implicit key at zero that
  has no target) gives those two targets `1 - t` and `t`; past the first or
  last key it extrapolates. This is the FBX in-between shape rule. Selection of
  the eight largest targets happens after this mapping. CPU release of a
  geometry keeps its channels, so a released morphed mesh still maps weights.
- Skinned meshes are culled, included as shadow casters and picked through a
  conservative bound: at insertion the store retains, per joint, the bound of
  the vertices that joint influences and of their morph deltas per target
  (`GeometryAsset.skin_bounds`, one allocation, kept through
  `release_geometry_cpu`, rebuilt by `mark_geometry_dirty` while the streams
  are present). Each frame every influencing joint's bound, widened by the
  mesh's selected morph targets, is transformed by `joint.world *
  inverse_bind[joint]` and merged; a `Mesh.local_bounds` override replaces it.
  A binding that addresses none of the geometry's joints falls back to the
  rest bound, and a skinned geometry drawn without a live binding draws
  unskinned.

Compute skinning for drawing and skinned instanced meshes are not part of this. Traced effects see the raster
pose of a skinned or morphed mesh through a posing pass ([scene trace](scene_trace.md#posed-instances)); the
velocity pass reads the view's previous palettes.

## Retargeting

Root-motion handling keeps the source interpolation. `STRIP_XZ` pins the hip x and z to the first
key and zeroes the x and z tangents of a cubic track; `EXTRACT` copies the hip track onto the root
with rest y, the first key's x and z as origin, zero y tangents and the source x and z tangents.

`c3d::anim::retarget` rebinds a clip authored against one set of node names
onto another model's template:

```c3
RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
options.root_motion = RootMotion.STRIP_XZ;
AnimationClip walk = retarget::retarget_by_name(
    allocator:    assets.allocator,
    source:       &baked,
    source_nodes: source_template.nodes,
    target:       &assets.model(hero).data,
    options:      options,
)!;
```

Every animated source node is matched to a destination template node by its
canonical name: the text after the last `:` (so `mixamorig:Hips` and `Hips`
agree), compared case-insensitively. `RetargetOptions.name_map` pairs exact
source and destination names and takes precedence. A source node with tracks
and no match fails with `ASSET_FORMAT_ERROR` unless `allow_partial` skips it; a
destination name shared by two nodes is ambiguous and also fails.

Rotation, scale and morph-weight tracks are copied for every matched node.
Translation tracks are copied only for source roots (nodes without a parent,
`Hips` on a Mixamo rig) so bone lengths come from the destination's rest pose;
`copy_translations` keeps them all. Interpolation, key times and the clip
duration are preserved.

`RootMotion` acts on the root translation tracks: `KEEP` copies them,
`STRIP_XZ` pins every key's horizontal position to the first key's (an
in-place clip), and `EXTRACT` strips them and adds one linear translation track
on `options.root_node`, a destination template node, holding that node's rest
position plus the horizontal displacement since the first key. `EXTRACT`
without a root node is `INVALID_ARGUMENT`; a Mixamo template has no node above
`Hips`, so it offers `KEEP` and `STRIP_XZ` only.

`fbx::load_animations(allocator, assets, path, model, options)` parses an FBX
animation file privately, bakes every stack, retargets it onto the model and
stores the clips under `<path>#anim/<k>#<model key>#<keep|strip_xz|extract>`,
returning their ids in the caller's allocator; the file's own nodes never
enter the store, and a fault removes every clip the call inserted
([Models, glTF and FBX import](models.md)). With `rest_pose = CORRECT` the key
gains `#rest`, so both variants of one file can live in one store.

### Rest-pose correction

`RetargetOptions.rest_pose` chooses how rotation keys reach the destination.
`COPY` (the default) copies them verbatim, which is right only when both rigs
share their rest orientations. `CORRECT` transfers motion in model space: for
each source joint it takes the rotation the joint made away from its own rest,
and applies that same model-space rotation to the destination joint's rest.
At the source's rest pose the destination therefore shows its own rest pose
exactly, whatever the two rigs' joint orientations are.

A corrected clip is baked:

- Every mapped destination joint gets a `LINEAR` rotation track on one shared
  cadence of `bake_rate` keys per second (`BAKE_RATE_DEFAULT` is 30). The last
  key lands on the clip duration. A source authored at another rate is
  resampled, so pass the source rate when it is known. Cubic tangents are not
  carried over.
- Every source node that resolves by name is bound, animated or not, so a
  joint without its own track still follows its parents. Unmapped destination
  joints keep their rest locals.
- The root translation is transferred in model space: the source root's
  displacement from its rest, times `root_translation_scale`, is applied to the
  destination root from its own rest, so the destination keeps its own standing
  height. `STRIP_XZ` and `EXTRACT` split that displacement into horizontal and
  vertical parts in model space before it is written into the destination's
  local frames. This assumes the destination root's ancestors are not mapped.
- Non-root translations are never emitted; scale and morph tracks are copied as
  under `COPY`.
- A corrected clip transfers one root: a source with more than one animated
  root translation faults `ASSET_FORMAT_ERROR` in every root mode.

`root_translation_scale` has two meanings. Under `COPY` it multiplies every
root translation key. Under `CORRECT` it multiplies the displacement from the
source rest. With the ratio of the two rigs' hip heights
(`rest_world_position(nodes, hips).y`) both give the same standing height. A
zero `root_translation_scale` or `bake_rate` stands for its default, so an
options literal that omits them keeps the `COPY` behaviour.

Correction transfers motion, not proportions or poses: both rigs must face the
same model axis and rest in the same kind of pose (both T or both A). A
T-pose source on an A-pose destination keeps the arms offset by the difference
for the whole clip. Foot contact and sliding follow from the rigs' proportions.
The optional `retarget --mixamo` mode plays a Mixamo walk on the Quaternius rig
with both modes.

### Calibrated profiles

`create_retarget_profile(allocator, source_nodes, target, desc)` prepares an
owned source/target pair. `RetargetProfileDesc` selects unique name mapping or
authoritative `NodeIndexMapping` rows, required per-node source and target
calibration rotations, motion nodes, a reserved carrier and a proper Y-up yaw
facing matrix. Reflection, shear or scale in the facing matrix is invalid.
The profile copies its inputs into one allocation; destroy it with
`destroy_retarget_profile` after its last bake.

`retarget_with_profile` borrows the current templates and profile and produces
an independently owned `AnimationClip`. Node counts and per-index names,
parents and authored locals must match the prepared pair. A mismatch returns
`INVALID_ARGUMENT` with the first differing index in `RetargetDiagnostic`.
`RetargetProfile.validate_templates` checks that pair without baking a clip.
Explicit mapping conflicts are format errors; ambiguous name matches are
rejected rather than selecting an arbitrary node.

The bake composes source motion through animated ancestors, applies calibration
and facing, and solves destination locals through their actual parent frames.
Target bone translations retain their proportions outside motion chains.
Animated nonuniform scale or shear on a consumed ancestor is `UNSUPPORTED`.
`RetargetBakeOptions` defaults to `KEEP`, a 60 Hz endpoint-inclusive linear
cadence and root translation scale 1. Zero duration has one key; positive
duration includes both endpoints. Copied non-motion scale, morph and event
data retain independent ownership.

`STRIP_XZ` removes the selected horizontal displacement. `EXTRACT` writes it
once on the reserved static carrier and compensates every child branch. Select
that carrier as `Animator.root_node`, leave `root_yaw` false, and consume its
root motion once through `apply_root_motion`. Runtime extraction uses the
existing Animator contract. Destroying the profile does not invalidate clips
already baked or published.

The default `retarget` example uses repository-authored T/A, facing, animated
ancestor and carrier rigs, with expected and profiled poses shown side by side.
It requires no external animation assets. `F` changes the fixture family,
Space pauses, `A` toggles automatic family cycling and `I` toggles diagnostic
lines. The carrier family shows `KEEP`, `STRIP_XZ` and `EXTRACT` over
forward/reverse playback.
`--acceptance` samples between bake keys and completes every family;
`--capture-dir=PATH` writes scene PNGs and `retarget-profile.csv` into an
existing directory, and `--telemetry=PATH` selects a separate CSV.

## Inverse kinematics

`c3d::anim::ik` bends existing joint nodes toward targets after the animator
has written its pose. Three types cover limbs, feet and looking:

- `IkChain`: three joints (root, middle, end) solved analytically so the end
  reaches `target`. `pole` picks the side the middle joint bends toward; without
  one, the incoming bend is kept. `weight` blends from the incoming rotations
  (0) to the solve (1). Only the root and middle local rotations are written, so
  bone lengths never change. A target beyond reach straightens the limb toward
  it.
- `FootIk`: a leg `IkChain` whose target follows the ground under the ankle.
- `LookAt`: turns the `forward` axis of the last of up to eight joints toward a
  target, at most `max_angle` from the incoming pose, without adding roll. The
  turn is split over the joints by `weights`; `look_at` fills shares that grow
  toward the tip and sum to 1, so one joint takes the whole turn and a spine,
  neck and head chain turns mostly at the head. A second internal pass corrects
  the tip's own swing about the lower joints.

`create_scene` registers the three as components so the inspector and
`DebugDraw.ik` find them. Nothing solves them for you: the application calls
`solve`, `place`, `release` and `align` in its own order. Joints, targets and
poles are borrowed nodes and must outlive the component that names them.

The first joint of an `IkChain` or `LookAt` may use `TransformSpace.WORLD`.
Every later joint must use `PARENT`, because the solvers articulate descendants
by rotating their ancestors. Their validity predicates reject a `WORLD`
interior joint. Targets, poles and the pelvis may use either transform space;
foot placement and pelvis lowering convert through their selected basis.
See [scene transforms](scene.md#authored-and-published-transforms).

Solvers read world matrices and write locals. A chain whose joints or target
descend from a joint another solve writes needs an `update_world` between the
two solves. On a humanoid the arms hang off the upper spine, so a spine look-at
solves before them; legs and arms are then independent:

```c3
anim::update(&assets, &scene, dt);
scene.update_world();
// physics.update(dt); physics.update_ragdolls(); scene.update_world();
foreach (foot : feet) {
    Ray ray = foot.ground_ray();
    if (try hit = query_ground(ray, foot.ray_length)) {
        foot.place(hit, floor_height);
    } else {
        foot.release();
    }
}
ik::lower_pelvis(hips, feet[..]);
scene.update_world();
look.solve();
scene.update_world();
foreach (foot : feet) foot.leg.solve();
arm.solve();
scene.update_world();
foreach (foot : feet) foot.align();
scene.update_world();
```

### Feet

The application owns the ground query. `ground_ray` returns a downward ray from
`ray_height` above the ankle; the application casts it through physics or reads
a height field and calls `place(hit, floor_height)` on a hit or `release()` on a
miss. `floor_height` is the world height the clip's feet were authored on,
usually the character root's height.

The target keeps the clip's ankle motion and moves it by the ground's offset
from the floor under the ankle. On flat ground at floor height the solve
changes nothing, and a swinging foot keeps its arc. `align` tilts the ankle by
the rotation from world up to the ground normal, faded out over `lift_fade` as
the ankle rises above `foot_height`. `lower_pelvis` lowers the pelvis by the
largest downhill offset of the grounded feet so the lower foot can reach its
target. Stance feet are not locked: on a slope a planted foot follows the
terrain height under it as the body moves.

### Retained foot contacts

Use `begin_contact(hit, support)` to capture a stance anchor and
`update_contact(support, dt)` to follow it. The application chooses the hit,
support identity and timing. `FootSupport` carries an opaque caller identity
and a proper rotation, translation and finite positive uniform scale.
`foot_support_from_mat4` validates an affine frame; nonuniform scale,
reflection, shear, zero or nonfinite input returns `INVALID_ARGUMENT` with
optional `FootDiagnostic` context. Changing the identity requires an explicit
new capture.

`FootIk.plant` defaults to 0.12 seconds of acquisition, 0.20 seconds of release
and ankle-local sole axes +Y/-Z. Set the axes for the rig's authored ankle
orientation. Settings and `foot_height` are captured at each begin; the height
remains in scene metres while the support-local sole point follows changing
scale. The normal and heading follow the support's proper rotation.

Call `end_contact(support)` to blend into the fresh incoming swing pose, or
`reset_contact()` for an immediate caller-authorized reset. Replanting captures
the currently requested correction. Zero `dt` freezes transition clocks while
external support movement still carries the contact. Start each update from
the fresh animation pose; choose either retained contact or `place/release`
for that update.

Order contact updates after animation and a world refresh, before optional
`lower_pelvis`. Refresh worlds after pelvis movement, solve dependent IK and
the legs, refresh, call `align_contact`, then refresh before `contact_result`.
The result reports phase, actual target residual and normal/heading errors as
`NO_TARGET`, `REACHED` or `MISSED`. Reach clamps, limits and partial leg weight
may leave a miss; the anchor is retained without stretching or automatic release.

Standalone `FootContact` uses the same lifecycle with an explicit incoming
`Transform`. During rebasing, call `Scene.shift_foot_contacts` after the scene
world refresh, or `FootContact.shift_origin` for standalone states. Each state
has one shift owner. See [large_world.md](large_world.md) for the full order.

### Limits

`IkChain.limits[0]` and `limits[1]` bound the root and middle rotations
relative to `reference`, a local rotation, usually the rest pose; `hinge_limit`
and `cone_limit` build them.

- `HINGE` keeps the rotation about `axis`, clamped to `[min_angle, max_angle]`,
  and drops the rest. A knee or elbow has one degree of freedom, so a pole off
  the hinge plane can leave the end short of the target.
  Rigs whose clips twist a joint about its bone axis (Rigify `DEF-shin`) pass
  that axis as `twist_axis`, unit and perpendicular to `axis`. The hinge then
  splits the rotation into a swing and a twist about the bone, clamps the
  swing's angle about `axis` and keeps the twist unbounded, so the limit stays
  referenced to the rest pose and bounds the real joint angle. The kept twist is
  the twist of the solved rotation; it equals the clip's twist when the solve's
  correction turns about an axis perpendicular to the bone, as a planar knee
  does. The `ik` example references both knees to the rest pose with the twist
  on the shin's local Y; flexion on that rig is positive about X, so the range
  is `[0, KNEE_FLEX_LIMIT]`.
- `CONE` clamps the angle between the rotated `axis` and `axis` to `max_angle`
  and keeps the twist.

Any clamped joint may leave the end short of the target: the middle joint is
solved against the unlimited root.

## Example

```bash
python3 scripts/build.py --example animation
./examples/build/animation path/to/model.glb --gpu-timings
```

`animation` loads the argument path, or the bundled Fox, instantiates it twice
and plays a different clip on each instance; `AnimatedMorphCube.glb` shows
morph targets. Keys `1` to `9` cross-fade the
left instance to that clip, `Q` toggles the left action between full and
quarter weight, `SPACE` pauses and resumes every action; drag orbits, the wheel
zooms, Escape quits.

`ik` shows two instances of the CC0 Quaternius mannequin on a moving support.
Caller-authored cues acquire, plant, release and replant each foot while the
support translates, yaws, tilts and changes uniform scale. The panel reports
contact phase, residual, sole-axis errors and reach margins. The example
poses the incoming legs above the support before contact updates, with a smooth
caller-timed swing arc. It preserves local bone positions, scales and the fresh
ankle orientation. Default contact mode uses unconstrained legs for the reachable
retention demonstration; `L` or
`--limits` enables the authored knee hinges and displays constrained misses.
`--legacy` retains height-field placement with those hinges. The spine, neck
and head follow the camera and the right hand reaches an orbiting sphere.

```bash
python3 scripts/build.py --example ik
```

`C` switches contact/legacy placement, Space pauses contact and animation clocks
while the support continues to move, and `R` shifts the origin explicitly.
`W` switches walk/idle, `[`/`]` change IK weight, `I` toggles debug lines, and
mouse drag/wheel orbit and zoom.

`ik.exe --acceptance --capture-dir=PATH` runs for at least 20 wall and simulation
seconds and exports completed rendered frames and `ik-contact.csv` to an
existing directory. `--telemetry=PATH` selects a separate CSV. The CSV reports
each final foot pose, phase/status, errors, reach margins, limit mode, support
scale, incoming and final sole clearance, pause/rebase events and capture index.
An early `--frames=N` limit does
not satisfy the bounded run. Vulkan validation is enabled.
