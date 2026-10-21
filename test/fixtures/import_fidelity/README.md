# Import fidelity fixtures

Two specimens for tangent import, both authored for this repository under CC0 1.0 (`LICENSE.txt`). Tests derive variants
in memory by replacing exact attribute text (`test/src/test_import_fidelity.c3`, `test_import_fidelity_fbx.c3`). Tangent
expectations come from the quad geometry and the raw UV coordinates, never from the production tangent generator.

## `tangent_streams_v1.gltf`

An embedded four-vertex XY quad with two counterclockwise triangles, +Z normals, UV0 `(x, y)` and UV1 `(-y, x)`. The
expected tangents are +X for UV0 and -Y for UV1. The authored tangent XYZ is `(2, 0, 0)` with alternating W of `2` and
`-3`: retention needs neither unit XYZ nor a unit W, and mixed signs within a triangle are accepted. Color, joint,
weight and named morph streams (`raise`, position deltas `(0, 0, 0.1)` to `(0, 0, 0.4)`; absent morph normals become
zero deltas) make retained data distinguishable. The inline PNG is the 2 x 2 RGBA fixture `rgba.png` as a data URI.

| Accessors | Hold |
| --- | --- |
| 0 to 9 | positions, normals, UV0, UV1, colors, authored tangents, joints, weights, indices, morph positions |
| 10 to 16 | unreferenced tangent variants: W 0, XYZ 0, XYZ with a NaN, a MAT2 shape, count 3, signed normalized SHORT, unsigned normalized BYTE |

Quantized variants add `KHR_mesh_quantization` to `extensionsRequired`. Clearcoat variants add the clearcoat extension
and a coat normal on the other UV set. Lookup-transform variants give the normal texture an explicit
`KHR_texture_transform` while the raw UV arrays stay.

## `authored_tangent_faults_v1.fbx`

ASCII FBX with the same one-metre quad, +Z normals and UV0 `(x, y)`, and one zero and one NaN entry in each authored
tangent and binormal array. Tests replace those arrays to isolate zero and NaN tangents and binormals, and to set a
valid baseline. The valid authored XYZ `(2, 0, 0)` and B `(0, 3, 0)` keep their magnitude, and the FBX V flip makes the
stored sign `-1`. Forced regeneration expects T `(1, 0, 0)` and sign `-1`, because the converted UV is `(x, 1 - y)`.
