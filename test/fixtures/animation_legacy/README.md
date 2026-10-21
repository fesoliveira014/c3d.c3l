# Animator v1 and AnimatedCrowd v2 inputs

Frozen Animator v1 and AnimatedCrowd v2 streams. The codec tests
(`addons/c3d_serial.c3l/test_described/animation_authoring_codec_test.c3` and `test_animation_motion_codec.c3`) read
them to check that old saves still restore. `SHA256SUMS` records the file bytes. The shared rules for compatibility sets
are in [the fixtures README](../README.md#rules).

| File | Holds |
| --- | --- |
| `animator-v1.bin`, `animator-v1.jsonc` | An Animator component |
| `crowd-v2-pending.bin`, `crowd-v2-pending.jsonc` | An AnimatedCrowd before preparation |

The source model is `gltf/skin.gltf`, loaded with key `animation_legacy/model`; its clip key is
`animation_legacy/model#anim/0`. The streams hold keyed references, not clip payloads.

- The Animator is named `legacy_animator`, with root node 2. Its ordered actions are a regular EXTRACT yaw action with a
  full boolean mask, a DIFFERENCE additive KEEP overlay with a partial mask, and the two regular members of a 1D group.
- The crowd is named `legacy_crowd`, with two instances in capacity four, six action slots per instance, no event
  capacity, tracing on and pose bounds `[-4, 4]` on each axis. Instance 0 has four authored actions and root node 2.
  Instance 1 has no actions, which permits its reflected placement without yaw extraction.
- A prepared crowd writes the same bytes, because the stream omits runtime state.
