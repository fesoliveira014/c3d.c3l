# Quaternius Universal Animation Library

`AnimationLibrary_Godot.glb` is the Godot export of the Universal Animation Library by
[Quaternius](https://quaternius.com), unmodified. License: CC0 1.0 (see `License.txt`).

- One skinned mesh (`Mannequin`) with a 53-joint Rigify skin (`DEF-hips`, `DEF-spine.001` to
  `.003`, `DEF-neck`, `DEF-head`, arms, legs, fingers, feet). Every node has unit scale.
- 127 clips, including `Idle_Loop`, `Walk_Loop`, `Jog_Fwd_Loop`, `Hit_Chest` and `Death01`.

Loaded by the `ik`, `retarget`, `skinned_crowd` and `animation_authoring` examples, the physics package's `cloth`
example, the physics inspector example (`physics_inspector`), the job package's crowd benchmark (`job_bench --crowd`),
and the GPU acceptance and benchmark projects under `test/gpu/`. SHA-256
`272d5c1e2c27f566595ece27b6985935d42dcee1dacee1b320af9f0c40d5c97c`.
