# Mixamo character and animations

`examples/mixamo` loads `character.fbx`, `walk.fbx` and `run.fbx` from this directory when run
without arguments (missing animation files are skipped). Download from [Mixamo](https://www.mixamo.com):

- Character: any character, FBX Binary (.fbx), With Skin, save as `character.fbx`.
- Animations: for example Walking and Running, FBX Binary (.fbx), Without Skin, 30 frames per
  second, no keyframe reduction, save as `walk.fbx` and `run.fbx`. In Place or not; the example
  loads both root-motion variants.

Git ignores every `.fbx` file in this directory: Mixamo assets are governed by Adobe's terms and
are not redistributed with this repository.

`examples/retarget` needs `eve_j_gonzales.fbx` and `walk.fbx` here: a Mixamo character with skin and
a Walking animation without skin, both FBX Binary at 30 frames per second. Public copies exist in the
`Alex-DG/threejs-character-controls` repository under `static/models/girl/`. The target rig,
`examples/assets/quaternius/AnimationLibrary_Godot.glb`, ships with the repository.
