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
returns. It holds a list of actions, one per playing clip.

```c3
Node* left = model::instantiate(&assets, &scene, model)!;
Node* right = model::instantiate(&assets, &scene, model)!;
ClipId[] clips = scene.get(left, ModelInstance).clips;

Animator* left_animator = anim::add_animator(&scene, left);
left_animator.play(&assets, clips[0])!;

Animator* right_animator = anim::add_animator(&scene, right);
Action* run = right_animator.play(&assets, clips[1])!;
run.speed = 1.5f;
```

`play` binds the clip's model-local targets through the instance's node table
once and returns the new action at time zero, weight one, looping. It faults
`INVALID_ID` for a dead clip and `INVALID_ARGUMENT` for a clip that does not
fit the instance (a target beyond the node table, or a morph track whose node
has no mesh or a different morph count). `stop(action)` removes the action;
`stop(action, seconds)` fades it out first. `cross_fade(from, to, seconds)`
fades one action out while the other fades to full weight. `play(clip, seconds)`
starts an action at weight zero and fades it in.

Action and animator pointers are borrows. `play` may move the action list and
removal shifts it; `add_animator` on another node may move the component
store. Reacquire through `scene.get(root, Animator)` and the action index after
either. `Action.time`, `speed`, `weight`, `loop` and `playing` are plain fields
the application may set at any time; `playing` gates only the clock, so a
paused action keeps contributing its pose.

While an animator exists it owns the pose of its instance: every update writes
every instance node's local transform and every instance mesh's morph weights.
The synthetic root is not an instance node and stays under application control,
so moving or spinning an instance as a whole is unaffected. Removing the root
removes the animator and its arrays through the ordinary component hook; the
shared clips stay in the store.

## Blending

Each channel (translation, rotation, scale, and each morph weight array) is
blended separately from the authored baseline copied at instantiation:

```plain text
total    = sum of weights of the actions whose clip animates this channel
residual = max(0, 1 - total)
value    = (sum of weight * sample + residual * baseline) / max(1, total)
```

A lone action at weight 0.25 sampling translation 8 over baseline 0 yields 2.
A rotation-only clip leaves translation and scale at their authored values. Two
actions at weight 1 average. Rotations are sign-aligned to the baseline
hemisphere before summing and normalized afterwards. Weighted averaging is the
only blend mode.

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

Compute skinning, previous deformed poses for temporal effects and skinned
instanced meshes are not part of this.

## Retargeting

Root-motion handling keeps the source interpolation. `STRIP_XZ` pins the hip x and z to the first
key and zeroes the x and z tangents of a cubic track; `EXTRACT` copies the hip track onto the root
with rest y, the first key's x and z as origin, zero y tangents and the source x and z tangents.

`c3d::anim::retarget` rebinds a clip authored against one set of node names
onto another model's template:

```c3
AnimationClip walk = retarget::retarget_by_name(
    allocator:    assets.allocator,
    source:       &baked,
    source_nodes: source_template.nodes,
    target:       &assets.model(hero).data,
    options:      { .root_motion = RootMotion.STRIP_XZ, .root_node = retarget::NO_ROOT_NODE },
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
([Models, glTF and FBX import](models.md)). Rest-pose differences between rigs
are not corrected.

## Inverse kinematics

`c3d::anim::ik` bends existing joint nodes toward targets after the animator
has written its pose. Three types cover limbs, feet and heads:

- `IkChain`: three joints (root, middle, end) solved analytically so the end
  reaches `target`. `pole` picks the side the middle joint bends toward; without
  one, the incoming bend is kept. `weight` blends from the incoming rotations
  (0) to the solve (1). Only the root and middle local rotations are written, so
  bone lengths never change. A target beyond reach straightens the limb toward
  it.
- `FootIk`: a leg `IkChain` whose target follows the ground under the ankle.
- `LookAt`: turns one node's `forward` axis toward a target, at most
  `max_angle` from the incoming pose, without adding roll.

`create_scene` registers the three as components so the inspector and
`DebugDraw.ik` find them. Nothing solves them for you: the application calls
`solve`, `place`, `release` and `align` in its own order. Joints, targets and
poles are borrowed nodes and must outlive the component that names them.

Solvers read world matrices and write locals. A chain whose joints or target
descend from a joint another solve writes needs an `update_world` between the
two solves. Legs, arms and the head of one humanoid are independent once the
pelvis has moved:

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
foreach (foot : feet) foot.leg.solve();
arm.solve();
scene.update_world();
foreach (foot : feet) foot.align();
head.solve();
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

### Limits

`IkChain.limits[0]` and `limits[1]` bound the root and middle rotations
relative to `reference`, a local rotation, usually the rest pose; `hinge_limit`
and `cone_limit` build them.

- `HINGE` keeps only the twist about `axis`, clamped to `[min_angle, max_angle]`.
  A knee or elbow has one degree of freedom, so a pole off the hinge plane can
  leave the end short of the target.
  A hinge referenced to the rest pose also drops any twist the clip gives the
  joint. Rigs whose clips twist a joint about its bone axis (Rigify `DEF-shin`)
  set `reference` to the joint's incoming local rotation before each solve, so
  the hinge bounds the correction from the clip pose; the `ik` example does this
  for both knees.
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

`ik` stands the Quaternius Mannequin on a height-field terrain: both feet follow
the ground with knee hinges, the right hand reaches an orbiting sphere and the
head follows the camera.

```bash
python3 scripts/build.py --example ik
```
