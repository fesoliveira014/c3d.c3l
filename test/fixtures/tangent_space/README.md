# Pinned tangent-space fixtures

Analytic and seeded meshes are authored under CC0-1.0. The input and expected payloads are byte-for-byte copies of the pinned MikkTSpace corpus. No native source or oracle is part of a repository target.

Input (`MKP2`, little endian): uint32 magic/count; each case has vertex count, face count, selected UV; 40-byte vertices contain position XYZ, normal XYZ, UV0 XY, UV1 XY; int32 face sizes; uint32 indices in source corner order.

Expected: uint32 magic/count; each case has status=1 and corner count, then float32 tangent XYZ and sign W for each source corner. Stages (`STG2`): magic/count; triangle count and good count; encoded welded int32 corner IDs; each good triangle has 12 int32 values: original face, output offset, original corner numbers, welded IDs, neighbors and flags.

The curated corpus covers seams, mirrors, selected UV1, hard normals, collapsed UVs, all-degenerate and exact zero directions.
