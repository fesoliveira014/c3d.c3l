# Animation retargeting

`c3d::anim::retarget` rebinds a clip authored against one set of node names onto another model's template, and
`fbx::load_animations` does it for every stack of an FBX animation file. Three levels cover the cases: a name match that
copies keys, rest-pose correction for rigs with different joint orientations, and calibrated profiles for exact
mapping, facing and a motion carrier. Retargeting is CPU work done once at load time and needs no feature flag.

## Quick start

Load a Mixamo animation file for a character you already imported, in place (root motion stripped):

```c3
import c3d::anim;
import c3d::anim::retarget;
import c3d::asset::fbx;

RetargetOptions options = retarget::RETARGET_OPTIONS_DEFAULT;
options.root_motion = RootMotion.STRIP_XZ;
ClipId[] clips = fbx::load_animations(
    allocator: mem,
    assets:    &assets,
    path:      "mixamo/walk.fbx",
    target:    hero,
    options:   options,
)!;
defer alloc::free(mem, clips.ptr);
animator.play(&assets, clips[0])!;
```

`load_animations(allocator, assets, path, target, options)` parses the file privately, bakes every animation stack,
retargets it onto the model's template and stores the clips. The file's own nodes never enter the store. The returned
IDs live in the caller's allocator and the clip data belongs to the store. A dead model faults `INVALID_ID`. On any fault
the call removes every clip it inserted. `target` names the model whose template receives the clips; its instances play
them.

## Concepts

### Clip keys

Each stack of the file becomes one clip keyed `<path>#anim/<k>#<model key>#<keep|strip_xz|extract>`. With
`rest_pose = CORRECT` the key gains `#rest`, so both variants of one file can live in one store. A key already in the
store faults `INVALID_ARGUMENT`.

### Name matching

Every animated source node matches a destination template node by its canonical name: the text after the last `:`,
compared case-insensitively, so `mixamorig:Hips` and `Hips` agree. `RetargetOptions.name_map` pairs exact source and
destination names and takes precedence.

- Under `COPY` only source nodes with tracks are resolved; under `CORRECT` every source node is. A resolved node with
  tracks and no match faults `ASSET_FORMAT_ERROR` unless `allow_partial` skips it.
- A canonical destination name shared by two nodes is ambiguous and faults `ASSET_FORMAT_ERROR` when a source node
  reaches it. `allow_partial` does not suppress this fault.
- A `name_map` destination matches exactly, and the first node with that name wins. A name that does not exist faults
  `ASSET_FORMAT_ERROR`.

### What is copied

Rotation, scale and morph-weight tracks are copied for every matched node, keeping interpolation, key times and the
clip duration. Translation tracks are copied only for source roots (nodes without a parent, `Hips` on a Mixamo rig), so
bone lengths come from the destination's rest pose. Set `copy_translations` to keep them all. Clip events are copied
into independent arrays.

### Root motion

`RootMotion` acts on the root translation tracks.

| Mode | Result |
| --- | --- |
| `KEEP` | Copies the root translation. |
| `STRIP_XZ` | Pins every key's horizontal position to the first key's, giving an in-place clip. Cubic tracks also lose their horizontal tangents, as the stripped root does under `EXTRACT`. |
| `EXTRACT` | Strips the root's horizontal (X and Z) translation, keeping its height, and adds one translation track on `options.root_node`, a destination template node, holding that node's rest position plus the horizontal displacement since the first key. The new track keeps the source interpolation, and on a cubic track its vertical tangents are zero. Without an animated root translation it adds no track. |

`EXTRACT` without a root node faults `INVALID_ARGUMENT`. `root_node` must be `NO_ROOT_NODE` or a node of the destination,
and `bake_rate` and `root_translation_scale` must not be negative; breaking either is a contract violation. A Mixamo template has no node above `Hips`, so it offers `KEEP`
and `STRIP_XZ` only. Play the extracted clip with `RootMotion.EXTRACT` and `Animator.root_node` set to that node
([Root motion](animation.md#root-motion)).

### Direct retargeting

`retarget_by_name(allocator, source, source_nodes, target, options)` retargets a clip you already hold. `source`
indexes `source_nodes`, which carry the source rig's names and parents, and the returned `AnimationClip` is owned by
the allocator. Add it to a store with `AssetStore.add_clip_owned`, which requires arrays allocated with the store's
allocator (`assets.allocator`).

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

## Rest-pose correction

`RetargetOptions.rest_pose` chooses how rotation keys reach the destination. `COPY` (the default) copies them verbatim,
which is right only when both rigs share their rest orientations. `CORRECT` transfers motion in model space: for each
source joint it takes the rotation the joint made away from its own rest and applies that same model-space rotation to the
destination joint's rest. At the source's rest pose the destination shows its own rest pose exactly, whatever the two
rigs' joint orientations are.

A corrected clip is baked:

- Every mapped destination joint gets a `LINEAR` rotation track on one shared cadence of `bake_rate` keys per second
  (`BAKE_RATE_DEFAULT` is 30). The last key lands on the clip duration. A source authored at another rate is resampled,
  so pass the source rate when it is known. Cubic tangents are not carried over.
- Every source node that resolves by name is bound, animated or not, so a joint without its own track still follows its
  parents. Unmapped destination joints keep their rest locals.
- The root translation is transferred in model space: the source root's displacement from its rest, times
  `root_translation_scale`, is applied to the destination root from its own rest, so the destination keeps its own
  standing height. `STRIP_XZ` and `EXTRACT` split that displacement into horizontal and vertical parts in model space
  before writing it into the destination's local frames. This assumes the destination root's ancestors are not mapped.
- Non-root translations are never emitted; scale and morph tracks are copied as under `COPY`.
- A corrected clip transfers one root: a source with more than one animated root translation faults
  `ASSET_FORMAT_ERROR` in every root mode. Under `COPY` the same fault applies only with `EXTRACT`.

`root_translation_scale` has two meanings. Under `COPY` it multiplies every root translation key. Under `CORRECT` it
multiplies the displacement from the source rest. The ratio of the two rigs' hip heights
(`rest_world_position(nodes, hips).y`) gives the same standing height in both. In `RetargetOptions`, a zero
`root_translation_scale` or `bake_rate` stands for its default, so an options literal that omits them keeps the defaults.

Correction transfers motion, not proportions or poses. Both rigs must face the same model axis and rest in the same kind
of pose (both T or both A); a T-pose source on an A-pose destination keeps the arms offset by the difference for the
whole clip. Foot contact and sliding follow from the rigs' proportions.

## Calibrated profiles

A profile prepares an owned source and target pair once and bakes any number of clips through it. Use it when the rigs
need an exact mapping, calibration rotations, a facing change or a carrier node that receives root motion.

```c3
Quat[] source_calibration = alloc::new_array(mem, Quat, source_nodes.len);
Quat[] target_calibration = alloc::new_array(mem, Quat, target.nodes.len);
// Fill one calibration rotation per node. For two T-pose rigs facing +Z, use each node's rest rotation.

RetargetProfileDesc desc = retarget::RETARGET_PROFILE_DESC_DEFAULT;
desc.name_map = name_map;
desc.source_calibration = source_calibration;
desc.target_calibration = target_calibration;
desc.source_motion_node = hips_source;
desc.target_motion_node = hips_target;
desc.target_carrier = carrier;

RetargetProfile profile = retarget::create_retarget_profile(
    allocator:    mem,
    source_nodes: source_nodes,
    target:       target,
    desc:         desc,
)!;
defer retarget::destroy_retarget_profile(&profile);

RetargetBakeOptions bake = retarget::RETARGET_BAKE_OPTIONS_DEFAULT;
bake.root_motion = RootMotion.EXTRACT;
ClipId[] clips = fbx::load_animations_with_profile(
    allocator: mem,
    assets: &assets,
    path: "mixamo/walk.fbx",
    target: hero,
    profile: &profile,
    variant: "t_pose",
    options: bake,
)!;
```

### `RetargetProfileDesc`

| Field | Default | Meaning |
| --- | --- | --- |
| `mapping_mode` | `BY_NAME` | `BY_NAME` for unique name matching with `name_map`, or `BY_INDEX` for authoritative `index_map` rows. `BY_INDEX` with a `name_map`, or `BY_NAME` with an `index_map`, faults `ASSET_FORMAT_ERROR`. |
| `index_map`, `name_map` | empty | Node correspondences. |
| `source_calibration`, `target_calibration` | required | One unit rotation per node of each template. |
| `source_motion_node`, `target_motion_node` | `RETARGET_NO_NODE` | The nodes whose motion is consumed. Leave both unset for no motion chain; when set, they must map to each other. |
| `target_carrier` | `RETARGET_NO_NODE` | Optional reserved destination node that receives extracted motion. Every mapped node, mesh, LOD group and skin joint must descend from it, and it and its ancestors must stay upright. |
| `facing` | identity | A proper Y-up yaw matrix with no translation. Reflection, shear or scale is invalid. |

### Ownership and validation

`create_retarget_profile(allocator, source_nodes, target, desc)` copies its inputs into one allocation and returns an
owner; destroy it with `destroy_retarget_profile` after its last bake. Destroying the profile does not invalidate clips
already baked.

- `retarget_with_profile` borrows the current templates and the profile and returns an independently owned
  `AnimationClip`. `RetargetProfile.validate_templates` checks the pair without baking.
- `create_retarget_profile` requires nonempty templates in which every parent index is lower than its node's index and
  every authored local has a finite position, a unit rotation and a positive uniform scale, and unit calibration
  rotations, otherwise `INVALID_ARGUMENT`.
- Node counts and the per-index names, parents and authored locals must match the prepared pair; a mismatch returns
  `INVALID_ARGUMENT`. Explicit mapping conflicts are format errors, and ambiguous name matches are rejected rather than
  resolved arbitrarily.
- `RetargetBakeOptions` defaults to `KEEP`, 60 keys per second (`PROFILE_BAKE_RATE_DEFAULT`) with both endpoints, and
  root translation scale 1; it also has `allow_partial`. Unlike `RetargetOptions`, a zero or nonfinite `bake_rate` or
  `root_translation_scale` is `INVALID_ARGUMENT`, not a default. `STRIP_XZ` and `EXTRACT` need a `target_motion_node`,
  `EXTRACT` needs a `target_carrier`, and a clip longer than `2^24` keys at the bake rate faults `CAPACITY_EXCEEDED`.
  A zero-duration clip has one key.
- Animated nonuniform scale or shear on a consumed ancestor faults `UNSUPPORTED`.

The bake composes source motion through animated ancestors, applies calibration and facing, and solves destination locals
through their actual parent frames. Target bone translations keep their proportions outside motion chains. Copied
non-motion scale, morph and event data keep independent ownership.

### Motion carrier

`STRIP_XZ` removes the selected horizontal displacement from the branch that holds the motion node: the carrier's child
on the motion node's path, or the motion node's root when there is no carrier. Other branches keep their placement.
`EXTRACT` writes that displacement and the motion node's world Y twist on the reserved carrier and compensates that branch
alone; the carrier's other children move and turn with it. The carrier turns in place about its authored reference
position, stays upright and keeps its authored scale. Its yaw is relative to time zero and unwrapped through the clip.

Select the carrier as `Animator.root_node` and consume its root motion once through `apply_root_motion`. With
`root_yaw = true`, extraction removes both translation and yaw from the mesh; with `root_yaw = false`, the turn stays in
the mesh.

### Profiled FBX loading

`fbx::load_animations_with_profile(allocator, assets, path, target, profile, variant, options)` borrows a prepared profile,
a target model and an explicit nonempty variant name. It validates the animation file's actual imported template against
the profile, including files with no animation stacks. A profiled clip is keyed
`<path>#anim/<k>#<model key>#<mode>#profile/<byte length>:<variant>`, with no `#rest`. Distinct variant names keep
calibrations separate; reusing a name under the same root-motion mode faults before publication. Failure while baking or
inserting any stack removes every clip that call inserted.

## Run the example

```bash
python3 scripts/build.py --example retarget
```

`retarget` plays a Mixamo walk on the Quaternius rig with `COPY`, `CORRECT`, profiled `STRIP_XZ` and profiled `EXTRACT`,
and shows the rest pose. It needs the Mixamo files listed in `examples/assets/mixamo/README.md`.

## Limits

- Rigs must face the same model axis; correction does not fix proportions or pose style.
- A corrected or profiled clip bakes its rotation and translation tracks as `LINEAR` keys on a fixed cadence; copied
  scale and morph tracks keep their interpolation.
- Fault summary: `ASSET_FORMAT_ERROR` for an unmatched, ambiguous or missing mapped node, more than one animated root
  and invalid mapping modes; `INVALID_ARGUMENT` for `EXTRACT` without a root node, invalid profile or bake inputs, a
  mismatched template pair, a duplicate key or an empty variant; `UNSUPPORTED` for animated nonuniform scale on a
  consumed ancestor; `INVALID_ID` for a dead model; `ASSET_IO_ERROR` and `CAPACITY_EXCEEDED` from file loading.

## See also

- [Animation](animation.md#root-motion) for consuming root motion.
- [Animation reference](animation_reference.md) for `RootMotion` and clip types.
- [Models, glTF and FBX import](models.md#fbx-import) for FBX import.
