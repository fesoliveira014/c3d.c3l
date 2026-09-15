# Mixamo character and animations

`examples/mixamo` loads `character.fbx`, `walk.fbx` and `run.fbx` from this directory when run
without arguments (missing animation files are skipped). Download from [Mixamo](https://www.mixamo.com):

- Character: any character, FBX Binary (.fbx), With Skin, save as `character.fbx`.
- Animations: for example Walking and Running, FBX Binary (.fbx), Without Skin, 30 frames per
  second, no keyframe reduction, save as `walk.fbx` and `run.fbx`. In Place or not; the example
  loads both root-motion variants.

Git ignores every `.fbx` file in this directory: Mixamo assets are governed by Adobe's terms and
are not redistributed with this repository.
