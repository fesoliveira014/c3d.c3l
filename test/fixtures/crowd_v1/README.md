# AnimatedCrowd v1 inputs

Immutable streams from the AnimatedCrowd v1 codec. Pending and prepared exports were identical, and independent captures
produced identical bytes. The serialization tests read them (`addons/c3d_serial.c3l/test_described/crowd_v2_test.c3`).
The shared rules for compatibility sets are in [the fixtures README](../README.md#rules).

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `crowd-v1.bin` | 705 | `87917a08b42051a8c32d66a3ccec242f726aad978338970aeb9f9daaea64419d` |
| `crowd-v1.jsonc` | 3468 | `84e5fd12a9609e4af776630c6bf3efeb481c464446b03f7ad04284135aab1a5d` |

The model source is `gltf/skin.gltf` (SHA-256 `2d63048337e5b5e0e2e6ba3eac5ebe5ce9a619c8aea7c0e27a99d4c48d86a7fc`),
loaded with key `crowd_codec_reference/model`; its generated clip key is `crowd_codec_reference/model#anim/0`.

The owner has three live instances in capacity five, with captured starts `0.75`, `0.25` and `0.125`, speeds `-0.5`, `0`
and `1`, loop flags true, false and true, reflected and nonuniform placements, distinct tints, explicit pose bounds and
tracing on. The starts are authoring clocks, never sampled runtime time.
