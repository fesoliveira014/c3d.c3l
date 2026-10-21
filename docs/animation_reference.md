# Animation reference

Types, constants, faults, blend formulas, sampling and the clip event import schema of `c3d::anim`. The usage guide is
[Animation](animation.md).

## Constants

| Constant | Value | Meaning |
| --- | --- | --- |
| `MAX_ACTIONS` | 16 | Action slots of one `Animator`; also the upper bound of a crowd's `actions_per_instance`. |
| `MAX_ANIMATION_LAYERS` | 4 | Layers folded from the authored pose upward. |
| `MAX_BLEND_SPACES` | 2 | Blend-space slots shared by 1D and 2D groups. |
| `MAX_BLEND_SPACE_ACTIONS` | 8 | Members of a 1D group. A 2D group takes 3 to 16 (3 to `actions_per_instance` on a crowd). |
| `MAX_FIRED_EVENTS` | 16 | Events one animator retains per update. |
| `DEFAULT_CROWD_ACTIONS` | 4 | Default `actions_per_instance` of a crowd. |
| `NO_ROOT_NODE` | `uint::max` | Model-local index meaning no root joint. |
| `PLAY_DESC_DEFAULT` | `{}` | Full-weight regular playback on layer 0. |
| `ANIMATION_TARGET_DEFAULT` | speed 1, weight 1, looping, playing | Default `AnimationTargetDesc`. |

## Playing

### `PlayDesc`

| Field | Default | Meaning |
| --- | --- | --- |
| `fade_in` | 0 | Seconds to fade from weight zero. Finite, nonnegative. |
| `layer` | 0 | Layer below `MAX_ANIMATION_LAYERS`. |
| `additive` | `false` | Apply the clip as a difference from its time-zero sample. |
| `mask` | null | Borrowed `JointMask`, copied at `play`. Null selects all nodes. |
| `weighted_mask` | null | Borrowed `WeightedJointMask`, copied at `play`. Not combinable with `mask`. |
| `additive_scale` | `DIFFERENCE` | `AdditiveScaleMode` of an additive action's scale tracks. |
| `root_motion` | `KEEP` | `RootMotion` mode. |
| `root_yaw` | `false` | Also extract the root's Y twist (planar path). Faults with `KEEP`. |
| `extraction` | not generalized | `RootExtractionDesc` for generalized extraction. Requires `EXTRACT`, no `root_yaw` and no `additive`. |

### `Action`

| Field | Access | Meaning |
| --- | --- | --- |
| `clip` | read | Clip the action plays. |
| `time` | read, write | Clip-local seconds. A write seeks and emits no motion or events. |
| `speed` | read, write | Clock rate; may be negative. Finite. |
| `weight` | read, write | Blend weight. Finite, nonnegative. |
| `loop` | read, write | Wrap at the clip ends. |
| `playing` | read, write | Gates the clock only; a paused action still poses. |
| `layer`, `additive`, `additive_scale`, `root_motion`, `root_yaw`, `extraction` | read | Captured at `play`; recreate the action to change them. |
| `fade_target`, `fade_rate` | read | Fade state set by `stop`, `cross_fade` and `fade_in`. |

### `Animator`

| Field | Meaning |
| --- | --- |
| `nodes` | Borrowed alias of the instance's node table; read nodes through `ModelInstance.present_node`. |
| `instance_root` | The synthetic root that carries the `ModelInstance`. |
| `root_node` | Model-local node whose motion is extracted. Keep it fixed while actions live. |
| `root_motion` | `RootMotionDelta` of the last update: `translation` and `rotation` in the instance root's frame. |
| `order`, `action_count` | Live action IDs in play order: `order[:action_count]`. |
| `events`, `event_count`, `events_dropped` | `FiredEvent` buffer of the last update and the number of dropped crossings. |
| `blend_spaces`, `blend_spaces_2d` | The two 1D slots and the two 2D slots. |

`AnimatorDesc` has one field, `inertia_enabled`, which reserves inertial storage when the animator is added.

### Functions

| Function | Returns | Meaning |
| --- | --- | --- |
| `add_animator(&scene, root, desc = {})` | `Animator*` | Add an animator to a `ModelInstance` root. One per root. |
| `Animator.play(&assets, clip, desc = PLAY_DESC_DEFAULT)` | `AnimationActionId?` | Start a clip. |
| `Animator.action(id)`, `try_action(id)` | `Action*`, `Action*?` | Borrow an action; `try_action` faults `INVALID_ID`. |
| `Animator.stop(id, fade_out = 0)` | `void?` | Remove an action, optionally after a fade. |
| `Animator.cross_fade(from, to, duration)` | `void?` | Fade `from` out while `to` reaches full weight. |
| `Animator.add_blend_space(assets:, clips:, positions:, desc:)` | `BlendSpace1D*?` | Start a 1D group. |
| `Animator.add_blend_space_2d(assets:, clips:, coordinates:, triangles:, desc:)` | `BlendSpace2D*?` | Start a 2D group. |
| `Animator.stop_blend_space(space, fade_out = 0)` | `void?` | Fade a group out or remove its members. |
| `Animator.fade_blend_space(space, target_weight, duration)` | `void?` | Fade a group to a weight. |
| `Animator.inertialize(&assets, desc)` | `AnimationTransitionResult?` | Replace playback with a decaying pose residual. |
| `Animator.cancel_inertial_transition()` | `void` | Discard the residual. |
| `Animator.inertial_status()` | `AnimationInertialStatus` | Copied enabled, active, elapsed and duration values. |
| `update(&assets, &scene, dt)` | `void` | Advance every animator. `dt` finite and nonnegative. |
| `apply_root_motion(node, delta)` | `void` | Move and turn a node by a `RootMotionDelta`. |
| `create_joint_mask(allocator, template, names, include_descendants = true)` | `JointMask?` | Boolean mask over model nodes. |
| `create_weighted_joint_mask(allocator, assets, model, names, weights)` | `WeightedJointMask?` | Weighted mask. |
| `create_feathered_joint_mask(allocator, assets, model, names, weights, depths)` | `WeightedJointMask?` | Mask whose weight ramps along descendants. |
| `destroy_joint_mask(&mask)`, `destroy_weighted_joint_mask(&mask)` | `void` | Free a mask. |

`CrowdPlayer` offers the same `play`, `action`, `try_action`, `stop`, `cross_fade`, blend-space, `inertialize` and
`cancel_inertial_transition` calls for one crowd instance, plus `base_action` and `set_root_node`. Obtain it with
`crowd.playback.instance_id(index)` and `player(id)` ([crowds](instancing.md#crowds)).

### Root extraction and events

| Type | Fields |
| --- | --- |
| `RootExtractionDesc` | `generalized`; `translation_axes` (`bool[3]`, instance-root frame); `up` (finite unit vector); `twist`. |
| `RootMotionDelta` | `translation`; `rotation`. Reset to zero and identity every update. |
| `FiredEvent` | `action`; `clip`; `id` (authored ID); `time` (clip-local seconds). |
| `ClipEvent` | `time`; `id`. |

### Transitions

| Type | Fields |
| --- | --- |
| `AnimationTransitionDesc` | `duration` (update seconds, zero switches at once); `actions` (`AnimationTargetDesc[]`); `spaces` (`AnimationTransitionSpaceDesc[]`). |
| `AnimationTargetDesc` | `clip`; `play` (`PlayDesc`); `start_time`; `speed`; `weight`; `loop`; `playing`. |
| `AnimationTransitionSpaceDesc` | `space` (`CrowdSpaceAuthoring`); `phase` (finite, `[0,1)`). |
| `CrowdSpaceAuthoring` | `kind` (`ONE_DIMENSIONAL` or `TWO_DIMENSIONAL`); `actions` (ordinals into the request's `actions`); `positions` and `parameter` (1D); `points`, `triangles` and `parameter_2d` (2D); `weight` (positive); `speed` (finite); `playing`. |
| `AnimationTransitionResult` | `actions[:count]` installed IDs in target order; `spaces[:space_count]` typed group borrows (`kind` with `one_dimensional` or `two_dimensional`). |
| `AnimationInertialStatus` | `enabled`; `active`; `elapsed`; `duration`. |

### Blend spaces

| Type | Fields |
| --- | --- |
| `BlendSpaceControl` | `count`; `weight`; `fade_target`; `fade_rate`; `phase`; `speed`; `playing`. Embedded in both kinds. |
| `BlendSpace1D` | The control; `actions`; `positions`; `parameter` (float). |
| `BlendSpace2D` | The control; `actions`; `points`; triangle and hull storage; `parameter` (`Vec2`). |
| `BlendTriangle` | `indices` (`uint[3]`) into the group's coordinates. |

## Faults

| Call | Faults |
| --- | --- |
| `play`, `add_blend_space`, `add_blend_space_2d` | `INVALID_ID` for a dead clip. `INVALID_ARGUMENT` for a clip that does not fit the instance (a target beyond the node table, a morph target outside its mesh table, a present mesh with a different morph count), an invalid layer, fade or mask, both mask types, a mask of the wrong width, a weight outside `[0,1]`, missing root configuration, `root_yaw` with `KEEP`, a non-`KEEP` additive action, an unsupported `root_yaw` basis under `EXTRACT`, generalized extraction with `root_yaw`, a mode other than `EXTRACT` or `additive`, an `EXTRACT` action whose extraction settings differ from a live `EXTRACT` action, an invalid extraction chain (nonuniform or nonpositive scale, two tracks on one node and path, zero quaternion keys) or invalid additive scale keys, and for groups, bad positions, coordinates or triangulation and nonpositive clip durations. `CAPACITY_EXCEEDED` when action or group slots are exhausted or an allocation fails. `UNSUPPORTED` for a `CUBIC_SPLINE` scale track under multiplicative additive or on a generalized extraction chain. |
| `stop`, `cross_fade` | `INVALID_ID` for a stale ID. `INVALID_ARGUMENT` for an invalid duration, a cross-fade to the same ID or an action that belongs to a blend space. |
| `stop_blend_space`, `fade_blend_space` | `INVALID_ARGUMENT` for a removed group, an invalid duration or an invalid weight. |
| `inertialize` | The `play` faults for each target. `INVALID_ARGUMENT` for a nonfinite or negative `duration`, a nonfinite `start_time`, `speed` or `weight`, a negative `weight`, an invalid group description (see `CrowdSpaceAuthoring`) or a nonpositive consumed scale. `CAPACITY_EXCEEDED` when `actions` exceeds the owner's action slots or `spaces` exceeds `MAX_BLEND_SPACES`. |
| `CrowdPlayer.cancel_inertial_transition` | `INVALID_ID` for a stale instance. |
| `create_joint_mask` | `NOT_FOUND` for a missing name. |
| `create_weighted_joint_mask`, `create_feathered_joint_mask` | `INVALID_ID` for a dead model; `INVALID_ARGUMENT` for mismatched array lengths or a weight outside `[0,1]`; `NOT_FOUND`; `CAPACITY_EXCEEDED`. |
| `AssetStore.set_clip_events` | `INVALID_ID`; `INVALID_ARGUMENT` for a nonfinite time or one outside `[0, duration]`. |

Every `CrowdPlayer` call also faults `INVALID_ID` for a stale instance. An inertial request on an owner without enabled
storage is a contract violation, not a fault.

## Blend formulas

Each channel (translation, rotation, scale and each morph weight array) blends separately against the value below it,
which is the authored baseline on layer zero.

### Regular blending

```plain text
total    = sum of effective weights for actions animating this channel
residual = max(0, 1 - total)
value    = (sum of weight * sample + residual * below) / max(1, total)
```

An action at weight 0.25 sampling translation 8 over baseline 0 yields 2. Rotations are sign-aligned to the lower pose's
hemisphere before summing and normalized afterwards. Effective weight is `action.weight`, times the weighted mask value
of the node when one applies.

### Additive blending

Each layer folds its regular actions, then applies its additive actions in play order.

| Channel | Result |
| --- | --- |
| Translation, morph weights | `below + weight * (sample - reference)`. |
| Scale, `DIFFERENCE` (default) | The same difference formula. |
| Rotation | `delta = reference.conjugate() * sample`, aligned to identity, interpolated from identity by weight, then postmultiplied onto the current rotation and normalized. A half-weight 45-degree delta applies 22.5 degrees. |
| Scale, `MULTIPLICATIVE` | `below *= (sample / reference) ^ effective_weight`, componentwise. |

The reference is the track's time-zero sample, captured at `play` (the value, not the tangents, of cubic keys). With
`MULTIPLICATIVE`, below `(2,3,4)`, reference `(2,4,8)`, sample `(8,1,32)` and weight 0.5 give `(4,1.5,8)`. A positive
sampled ratio gives a positive factor at every weight, including weights above 1. Between adjacent keys whose ratio
exceeds 2^24, a sample can round to zero, so keep scale keys within that ratio.

## Sampling

`sample_track(track, time, cursor, out)` clamps `time` to the key range. The cursor is a hint: any value is valid, a
forward sweep advances from the previous key and a backward jump re-seeks by binary search.

| Interpolation | Result |
| --- | --- |
| `STEP` | Holds the previous key. |
| `LINEAR` | Interpolates per element. Rotations take the short path and use slerp when the keys are more than 0.1 rad apart. |
| `CUBIC_SPLINE` | The glTF Hermite form, with tangents scaled by the segment duration. |

`sample_pose(&assets, clip, time, cursors, &scratch, destination)` samples one clip at one time without playback. The pose
starts from the destination's base pose, every present track writes its channel at full weight and `time` clamps to each
track's key range. It reads the store and writes only the caller's cursors, scratch and destination. The result equals
that of a single unmasked regular action of weight 1 that keeps its root motion in the pose, bit for bit. A clip with two
tracks on one node and path is the exception: an action averages them, `sample_pose` keeps the later one.

Code that reads keys goes through `Track.key_count`, `key_time` and `read_key`, because `Track.values` holds floats only
while `encoding` is `RAW` ([Compressed clips](animation_performance.md#compressed-clips)).

## Event import schema

A glTF animation reads the table from `animation.extras.c3d_events`. An FBX animation stack reads it from its string
property `c3d_events`, which holds the inner object.

```json
{"c3d_events":{"version":1,"events":[{"time":0.25,"id":7}]}}
```

For FBX the property value is `{"version":1,"events":[{"time":0.25,"id":7}]}`. Both importers read it whenever
`LoadOptions.animations` is enabled, including store-free and background loading. `fbx::load_animations` and
`fbx::load_animations_with_profile` read the same property, and an import with animations disabled reads no event
metadata. Absent metadata or an empty array produces an empty table, and replacing a clip replaces its table.

| Field | Rule |
| --- | --- |
| `version` | An integral JSON number equal to 1. Another integral version faults `UNSUPPORTED`; a nonintegral one faults `ASSET_FORMAT_ERROR`. |
| `events` | An array of objects. Required. |
| `time` | Finite clip-local seconds in `[0, duration]`, read as double and stored as float. |
| `id` | An integral JSON number from 0 through 4294967295. Repeated IDs are valid. |

- Metadata is strict JSON: no comments and no trailing commas. Integral spellings such as `1`, `1.0` and `1e0` are
  equivalent.
- Events never extend the track-derived duration. A zero-duration clip permits only time-zero markers.
- FBX times are the decoded origin after baking with `trim_start_time = true`. Author markers against the resulting clip
  times, not the stack's absolute scene times.
- Missing fields, wrong types, malformed metadata and invalid values fault `ASSET_FORMAT_ERROR`. This includes metadata
  the JSON parser rejects, such as excessive nesting, out-of-range numbers and invalid escapes. For glTF, extras the
  parser rejects fault only when their text contains `"c3d_events"`; otherwise they import no events.
- Unknown fields, extras without `c3d_events`, non-object extras and unrelated properties are ignored. A repeated key
  keeps its last value.
- A failed import leaves shared assets unchanged.

Imported events are stably sorted by time, keeping authored order at equal times. The table holds IDs and times only.

## See also

- [Animation](animation.md) for the guide.
- [Models, glTF and FBX import](models.md) for clips in the store.
- [Retargeting](animation_retargeting.md) for `RetargetOptions` and profiles.
