# AnimatedCrowd v1 compatibility inputs

These immutable inputs were emitted by the actual v1 codec before issue #351
production changes. Pending and prepared exports were identical; independent
capture processes also produced identical bytes. The frozen generator remains
under `test/crowd_codec_reference/` as a historical producer.

| Input | Bytes | SHA256 |
| --- | ---: | --- |
| crowd-v1.bin | 705 | 87917a08b42051a8c32d66a3ccec242f726aad978338970aeb9f9daaea64419d |
| crowd-v1.jsonc | 3468 | 84e5fd12a9609e4af776630c6bf3efeb481c464446b03f7ad04284135aab1a5d |

Source baseline: approved merged `093e9be` (tree equal to reviewed PR #392
`5b060f8`). Compiler: C3 0.8.3, default safe options.

The model source is `test/fixtures/gltf/skin.gltf`, SHA256
`2d63048337e5b5e0e2e6ba3eac5ebe5ce9a619c8aea7c0e27a99d4c48d86a7fc`.
Load it with model key `crowd_codec_reference/model`; its generated clip key is
`crowd_codec_reference/model#anim/0`.

The owner has three live instances and capacity five, captured starts
0.75/0.25/0.125, reverse/zero/forward speeds -0.5/0/1, loop true/false/true,
reflected and nonuniform placements, distinct tints, explicit pose bounds and
trace enabled. These starts are authoring clocks, never sampled runtime time.
