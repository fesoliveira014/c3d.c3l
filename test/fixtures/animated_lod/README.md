# Animated mannequin LOD fixtures

These CC0 geometry fixtures are derived from the unmodified Quaternius Universal Animation Library, AnimationLibrary_Godot.glb. Source SHA256: 272d5c1e2c27f566595ece27b6985935d42dcee1dacee1b320af9f0c40d5c97c. See the original [source notice](../../../examples/assets/quaternius/README.md) and [CC0 license](../../../examples/assets/quaternius/License.txt). Level zero remains that original source, not a copied fixture.

## Deterministic derivation

Generator: [the manual C3 tool](../../animated_lod_derivation/README.md), format version 1, derivation version 1. Source mesh primitives retain their ModelTemplate.meshes order. Level 1 selects original face ordinals 0, 2, 4, ...; level 2 selects 0, 4, 8, ... . Both derive directly from the original, not from the preceding level. Within each selected face, corner order is unchanged. Compact vertex order follows first reference while traversing those selected faces; every retained attribute is copied from the corresponding original vertex.

The tool reads the source once, verifies its SHA256 before decoding, and uses the public glTF loader with animations, lights, cameras and tangent generation explicitly disabled. This preserves loaded authored streams without pinning importer-generated tangents. Both primitive geometries contain positions, normals, UV0, UV1, ushort joint vectors and float weight vectors (stream mask 219); tangents, colors and custom data are absent. No coordinates, normals, weights, UVs, joints or inverse-bind values are interpolated, normalized or recomputed by the derivation.

Run from the repository root using C3 0.8.3 and the repository's pinned dependencies:

    c3c build animated_lod_derivation --path test/animated_lod_derivation
    test/animated_lod_derivation/build/animated_lod_derivation.exe examples/assets/quaternius/AnimationLibrary_Godot.glb test/fixtures/animated_lod

The caller creates the output directory. To check exact regeneration, use a different output directory and pass test/fixtures/animated_lod as the third argument. The tool verifies coherent selected corners, strict triangle reduction, every serialized stream value, the complete ordered 53-joint list and bitwise inverse binds; the optional expected directory requires exact file equality. It emits SHA256SUMS itself. This manual target stays outside scripts/build.py --test. No Python mesh processing or external tool is used.

## Counts and hashes

Loaded model: 57 template nodes; source primitive 0 is mesh node 2 and primitive 1 is mesh node 3. Both retain all 53 ordered joint-node entries and identical inverse-bind matrices. The original packed joint width is 8 bits; files explicitly store four 16-bit joint components per vertex, matching Geometry.joints.

| Primitive | Level | Source vertices / triangles | Derived vertices | Derived indices | Derived triangles | Bytes |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 1 | 3389 / 5732 | 3297 | 8598 | 2866 | 273808 |
| 0 | 2 | 3389 / 5732 | 2858 | 4299 | 1433 | 221028 |
| 1 | 1 | 5157 / 8012 | 4781 | 12018 | 4006 | 392960 |
| 1 | 2 | 5157 / 8012 | 4150 | 6009 | 2003 | 318004 |

SHA256 values are also in [SHA256SUMS](SHA256SUMS):

| File | SHA256 |
| --- | --- |
| primitive_0_lod_1.bin | 58991acb0d453c09449e297bd69c71c1611a1f3a1bbe10e80739594c41179ee6 |
| primitive_0_lod_2.bin | 9bcc79c0ffb4108bb0672681b64a125bcb0a546151868b38f7c1c655f1730b11 |
| primitive_1_lod_1.bin | 284453c09e7d9119a363c6f4cf86b37b74ae8b87b6b956f60dafd4e9c8d366bd |
| primitive_1_lod_2.bin | dfd6032d9e00f383094da0c6150d2a6e551f0f2b51c41e22eb64cd87483e90f0 |

## Binary format

All integers and IEEE float words are little-endian. No pointers, handles or structure padding are dumped. The fixed header contains 24 u32 words:

| Word | Meaning |
| --- | --- |
| 0 | ALOD magic, 0x444f4c41 |
| 1–3 | Format version 1, derivation version 1, endian marker 0x01020304 |
| 4–6 | Source primitive index, level, source face stride |
| 7–8 | Loaded template-node count, source mesh template-node index |
| 9–11 | Source vertex count, source index count, source triangle count |
| 12–14 | Compact vertex count V, derived index count I, selected face count T |
| 15 | Joint count J, including unused joints |
| 16–17 | Source packed joint bits; file joint component bits, always 16 |
| 18 | Retained stream mask |
| 19 | Custom bytes per vertex |
| 20–22 | Target count, channel count, default morph weight count; all zero for this source |
| 23 | Header word count, 24 |

Header bytes are followed by the 32 raw source SHA256 bytes, then six f32 words for source rest bounds (min xyz, max xyz). Those bounds are conservative for the retained source vertices and are not an animated crowd envelope.

Next arrays, in order:

1. J ordered model-template joint-node indices, u32.
2. J inverse-bind matrices, 16 f32 words each in column-major m00,m10,m20,m30,m01,...,m33 order.
3. T selected original face ordinals, u32.
4. V original vertex indices in compact order, u32.
5. I compact corner indices, u32.
6. Each present vertex stream in the order below, stream by stream over the compact vertices.

Stream bits and element layouts: bit 0 positions (3 f32), bit 1 normals (3 f32), bit 2 tangents (4 f32), bit 3 UV0 (2 f32), bit 4 UV1 (2 f32), bit 5 colors (4 f32), bit 6 joints (4 u16), bit 7 weights (4 f32), bit 8 custom data (header[19] uninterpreted bytes). Every present ordinary stream has V elements. There is no hidden alignment or trailing data.

## Consumption and limits

Load level zero from the original source. Validate the fixture's source digest, primitive/mesh-node mapping, joint list and inverse-bind words against that loaded model. Reconstruct ordinary Geometry arrays using the compact counts and stream layouts, with TRIANGLES topology and the serialized rest bounds. Keep the source part's material, model-node transform, skeleton and complete joint mapping. The original face/vertex maps support exact retained-attribute checks; they are provenance, not runtime joints.

This is deterministic face selection, not surface simplification. Dropped triangles produce holes and incomplete surfaces; normals retain original smoothing. It supplies real reduced triangle geometry for deformation, selection and history checks, but does not establish production LOD quality, visual preservation or a performance improvement. Comparison images must use ordinary reference rendering of the same selected geometry. No runtime LOD descriptor, impostor, crossfade, palette remapping or selected-level trace policy is encoded.
