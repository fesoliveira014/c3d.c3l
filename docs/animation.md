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
update and the final `update_world`.

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

The animation update writes node transforms and morph weights. Meshes attached
to animated nodes move with them, as `BoxAnimated` shows in the `animation`
example. Skinned meshes still render in their bind pose and morphed meshes in
their base pose: joint palettes, morph selection and the deformation shader
variants are the next animation change.

## Example

```bash
python3 scripts/build.py --example animation
./examples/build/animation path/to/model.glb --gpu-timings
```

`animation` loads the argument path, or the bundled Fox, instantiates it twice
and plays a different clip on each instance. Keys `1` to `9` cross-fade the
left instance to that clip, `Q` toggles the left action between full and
quarter weight, `SPACE` pauses and resumes every action; drag orbits, the wheel
zooms, Escape quits.
