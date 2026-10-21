# Tangent-space fixtures

`curated.input.bin` and `curated.expected.bin` hold 27 curated triangle cases: seams, mirrors, selected UV1, hard
normals, collapsed UVs, all-degenerate triangles and exact zero directions. The corpus has no quads. Analytic and seeded
meshes are authored under CC0 1.0. Both files are byte-for-byte copies of the pinned MikkTSpace corpus; no native source
or oracle is part of a repository target. The tangent generation tests (`test/src/test_tangent_space.c3` and
`test/gpu/render/test_texture_fidelity.c3`) embed them.

All values are little endian.

- **Input** (`MKP2`): `uint32` magic and case count. Each case has a vertex count, a face count and the selected UV.
  Vertices are 40 bytes: position XYZ, normal XYZ, UV0 XY, UV1 XY. Then `int32` face sizes (all 3) and `uint32` indices
  in source corner order.
- **Expected**: `uint32` magic and case count. Each case has status `1` and a corner count, then `float32` tangent XYZ
  and sign W for each source corner.
