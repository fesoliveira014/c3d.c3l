# Animated LOD fixture loader

This manual CPU target loads the unchanged CC0 Quaternius model and four committed lower-detail geometries. It creates no renderer, GPU device or scene binding. The reusable [fixture module](../fixtures/animated_lod_fixtures.c3) publishes assets into a caller's AssetStore and returns `AnimatedLodFixtures`: the original ModelId, GeometryIds indexed `[primitive][level]`, and existing `render::GeometryLayout` values. Level zero is the source geometry; levels one and two are the derived files.

The loader checks the source SHA256 and each frozen fixture hash before decoding. It verifies all 24 little-endian header words, exact source rest-bound bits, all 53 ordered joint-node entries and every inverse-bind float word. Face/vertex maps must reproduce the deterministic stride and first-use compact order, and every compact corner must name its original source corner. Every retained position, normal, UV, joint and weight component must match the source bitwise. Byte decoding writes aligned ordinary C3 arrays; it performs no typed reads through byte-buffer pointers, interpolation, normalization or tangent generation.

All four derived geometries are staged in the original store-free ModelDocument before its single publication. The original template nodes, meshes, materials, skins, joint ordering and 127 clips are retained. No replacement model template, skeleton or binding is synthesized. The caller owns the returned assets through its AssetStore; the fixture view owns no separate storage. Repeated loading into the same store uses the same keys and returns the ordinary duplicate-key fault.

The format, counts, licences and SHA256 inventory are in the [derived fixture README](../fixtures/animated_lod/README.md). These face-subset levels have holes and incomplete surfaces; they establish reproducible reduced geometry, not production LOD quality or a performance improvement. Their serialized rest bounds are not animated crowd envelopes. This module defines no runtime LOD descriptor or selected-level tracing policy.

Run from the repository root with the pinned C3 0.8.3 environment:

```text
c3c build animated_lod_fixture_loader --path test/animated_lod_fixture_loader
test/animated_lod_fixture_loader/build/animated_lod_fixture_loader.exe REPOSITORY_ROOT
```

The target stays outside `scripts/build.py --test`. Successful loading exits 0 and reports the original and reduced counts. Invalid data or an operational failure exits 1; invalid arguments exit 2. Compilation and runtime validation are separate evidence and are not claimed by this source checkpoint.
