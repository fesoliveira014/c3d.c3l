# Animator v2 and AnimatedCrowd v3 inputs

Frozen Animator v2 and AnimatedCrowd v3 streams. The motion codec tests
(`addons/c3d_serial.c3l/test_described/test_animation_motion_codec.c3`) read them to check that old saves still restore.
`SHA256SUMS` records the file bytes. The shared rules for compatibility sets are in [the fixtures
README](../README.md#rules).

| File | Holds |
| --- | --- |
| `animator-v2.bin`, `animator-v2.jsonc` | An Animator component |
| `crowd-v3-pending.bin`, `crowd-v3-pending.jsonc` | An AnimatedCrowd before preparation |

The source model is `gltf/skin.gltf`, loaded with key `animation_authoring_legacy/model`; its clip key is
`animation_authoring_legacy/model#anim/0`. The streams hold keyed references, not clip payloads.

- The Animator has root node 2, a paused, nonlooping EXTRACT yaw base action (speed -0.5, weight 0.6), three additive
  MULTIPLICATIVE members on layer 1 with the weighted row `(0, 0.25, 0.5, 0.75)`, and a paused 2D group with three
  points, an authored triangle and a parameter.
- The crowd has two instances in capacity three, four actions per instance, event capacity 17 and tracing on. Instance 0
  repeats the base action and 2D membership with a positive uniform scale of 2. Instance 1 has empty playback and a
  reflected, nonuniform placement.
- A prepared crowd writes the same bytes, because the stream omits runtime state.
