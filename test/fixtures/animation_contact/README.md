# Profile animation fixture

`profile_animation_v1.fbx` is repository-authored ASCII FBX 7.4 under the repository MIT license. It contains numeric
transforms and animation data only; no third-party asset data was copied. Units are metres (UnitScaleFactor 100) and Y
is up. One second is 46186158000 FBX ticks.

The imported template omits the implicit root: Carrier (template root at the origin), Hip (child of Carrier at
`(0, 1, 0)`) and Foot (child of Hip at `(0, -1, 0)`), all with identity rotation and unit scale.

- Stack `Translate` moves Carrier X from 0 to 1 over one second.
- Stack `Scale` changes Hip X scale from 1 to 2, which calibrated profile baking rejects as unsupported.

`test/src/test_fbx.c3` derives its clean, renamed-source and stackless inputs from these bytes in memory.
