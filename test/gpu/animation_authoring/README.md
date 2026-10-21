# Animation authoring acceptance

Manual Vulkan acceptance for animation authoring on the GPU ([animation](../../../docs/animation.md)). The tests render
animated models and compare the images with the CPU animator.

| File | Covers |
| --- | --- |
| `test_native.c3` | Nine-sample blending, a weighted upper-body mask and a ratio overlay on the Quaternius character, and complete morph weights on `AnimatedMorphCube.glb` over twenty seconds. |
| `test_motion_native.c3` | Turns, reversal, loops and interrupted requests on the Quaternius character. |
| `native_support.c3` | The renderer fixture, probe readback and image checks that the two test files use. |

The sources are the Quaternius animation library and `AnimatedMorphCube.glb` under `examples/assets/`; the tests check
their SHA-256.

## Run

Build the repository once so `shaders/spv/` exists, copy the shaderc library next to the test executable
(`test/gpu/animation_authoring/build/`) as [development.md](../../../docs/development.md#acceptance-projects) describes,
then:

```bash
c3c test acceptance --path test/gpu/animation_authoring
```

The project does not run under `python3 scripts/build.py --test` or in CI. It creates real Vulkan devices with
validation enabled. Start a built `testrun` by hand from the project directory, because the tests open
`../../../examples/assets/...` relative to it.
