# Pinned tangent-space fixtures

Analytic and seeded meshes are authored under CC0-1.0. The source and expected/stage payloads are byte-for-byte copies of the repaired, accepted pinned corpus; `provenance.json` records the hashes, compiler and commands. No native source or oracle is part of a repository target.

Input (`MKP2`, little endian): uint32 magic/count; each case has vertex count, face count, selected UV; 40-byte vertices contain position XYZ, normal XYZ, UV0 XY, UV1 XY; int32 face sizes; uint32 indices in source corner order.

Expected: uint32 magic/count; each case has status=1 and corner count, then float32 tangent XYZ and sign W for each source corner. Stages (`STG2`): magic/count; triangle count and good count; encoded welded int32 corner IDs; each good triangle has 12 int32 values: original face, output offset, original corner numbers, welded IDs, neighbors and flags.

The seven individual input/expected/stage triples retain the locally minimal missing-tail-edge case, finite midpoint overflow/nonoverflow welding and four internal quad paths. `manifest.json` preserves their frozen original hashes. The curated corpus additionally covers seams, mirrors, selected UV1, hard normals, collapsed UVs, all-degenerate and exact zero directions.
