# Animated crowd acceptance

Manual Vulkan acceptance for animated crowds and animated level of detail ([crowds](../../../docs/instancing.md), [level
of detail](../../../docs/lod.md)). The tests render crowds and animated `LodGroup` objects and compare the images, depth
and readbacks with the CPU animator and with literal expectations.

| File | Covers |
| --- | --- |
| `test_native.c3` | Crowd poses against the animator: rest, endpoint and missing-weight clips, independent controls, shear, real Quaternius and morph sources, consumed root motion and shadow poses. |
| `test_lod_native.c3` | Forced and selected levels, simultaneous parent levels, offscreen shadows, stretched bounds, dangling sources and preparation of lower skin and morph variants. |
| `test_lod_indirect_native.c3` | The indirect draw path: literal counts for three levels, equal-count parity and blend sorting, near-singular parts. |
| `test_lod_temporal_native.c3` | History across parity swaps, view skips, cuts, aborts, topology replacement and culling-arena overflow. |
| `test_lod_trace_native.c3` | Traced animated levels and shared crowd poses on the software and hardware traces. |

The project reuses the fixture and frame harness of `test/gpu/render` and the recipes in `test/fixtures/`
(`animated_crowd_fixtures.c3`, `animated_lod_fixtures.c3`). The real sources are the Quaternius animation library and
`AnimatedMorphCube.glb` under `examples/assets/`; the tests check their SHA-256.

## Run

Build the repository once so `shaders/spv/` exists, copy the shaderc library next to the test executable
(`test/gpu/animated_crowd/build/`) as [development.md](../../../docs/development.md#acceptance-projects) describes,
then:

```bash
c3c test acceptance --path test/gpu/animated_crowd
```

The project does not run under `python3 scripts/build.py --test` or in CI. It creates real Vulkan devices with
validation enabled. Start a built `testrun` by hand from the project directory, because the tests open
`../../../examples/assets/...` relative to it. Hardware-trace cases need ray queries and skip otherwise.
