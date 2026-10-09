# Import fidelity fixture

`tangent_streams_v1.gltf` is authored test data under CC0-1.0. It contains an embedded four-vertex XY quad, two counterclockwise triangles, +Z normals, raw UV0=(x,y), and raw UV1=(-y,x). Independent tangent expectations are +X for UV0 and -Y for UV1. The authored tangent XYZ is (2,0,0), with alternating W=2 and W=-3; retention does not require unit XYZ or W and does not reject mixed signs within a triangle.

Color, joint/weight, and named morph streams distinguish retained data. The `raise` position deltas are (0,0,0.1), (0,0,0.2), (0,0,0.3), and (0,0,0.4); absent authored morph normals become zero deltas.

Accessor indices: 0 positions, 1 normals, 2 UV0, 3 UV1, 4 colors, 5 authored tangents, 6 joints, 7 weights, 8 indices, 9 morph positions, 10 tangent W=0, 11 tangent XYZ=0, 12 tangent XYZ containing binary IEEE NaN, 13 tangent MAT2 shape, 14 tangent count=3, 15 signed normalized SHORT tangents, and 16 unsigned normalized BYTE tangents. Accessors 10-16 remain unreferenced until a test selects them.

Tests derive variants by replacing the exact `"TANGENT":5` attribute with the selected accessor, removing the exact attribute for missing-tangent cases, replacing normal `"texCoord":0` with 1, or removing exact normal/UV attributes. Quantized variants add `KHR_mesh_quantization` to extensionsRequired. Clearcoat variants add the clearcoat extension and a coat normal using the other UV set. Lookup-transform variants replace the normal TextureInfo with an explicit KHR_texture_transform override while retaining raw UV arrays.

The inline PNG is the repository's existing two-by-two RGBA fixture encoded as a data URI. It tests decoding and ownership; expected tangents are derived from the quad geometry and raw UV coordinates, independently of the tangent generator.

`authored_tangent_faults_v1.fbx` is repository-authored CC0-1.0 ASCII FBX data. It contains the same one-metre XY quad and two counterclockwise triangles, +Z normals, and UV0=(x,y), with one zero and one NaN entry in each authored tangent/binormal array. Tests replace those exact arrays to isolate zero/NaN tangents and binormals, and to establish a valid authored baseline. The valid authored XYZ=(2,0,0), B=(0,3,0) retains tangent magnitude; the FBX V flip makes its stored sign -1. Forced regeneration independently expects T=(1,0,0), sign=-1, because the converted UV is (x,1-y). No production tangent generator supplies these expected values.
