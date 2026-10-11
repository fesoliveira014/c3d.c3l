# Historical animation codec inputs

Frozen Animator v1 and AnimatedCrowd v2 streams, written by the registered writers at
`387d69dabc6fd023a13d8182a678d1231ec34dc1`. The codec tests read them to check that
old saves still restore:

- `animator-v1.bin`, `animator-v1.jsonc`
- `crowd-v2-pending.bin`, `crowd-v2-pending.jsonc`

The source model is `test/fixtures/gltf/skin.gltf`, loaded with key
`animation_legacy/model`; its clip key is `animation_legacy/model#anim/0`. The streams
contain keyed references, not clip payloads.

The Animator owner is named `legacy_animator`, placed at `(-4,1,6)` on layers 5,
with root node 2. Its ordered actions are a regular EXTRACT/yaw action with a
full boolean mask, a DIFFERENCE additive KEEP overlay with mask
`(false,true,true,false)`, then the two regular members of a 1D group. The base
uses speed -0.5, weight 0.6, no loop and paused playback. The overlay uses layer 1,
speed 0.75, weight 0.25 and looping playback. The group uses layer 2, positions
`(-1,2)`, parameter 0.5, weight 0.75, speed -0.25 and paused playback; member
speeds are 1 and 1.25.

The crowd is named `legacy_crowd`, placed at `(4,2,-8)` on layers 9. It has count
2, capacity 4, six action slots per instance, event capacity 0, tracing enabled
and pose bounds `[-4,4]` on each axis. Seed times are 0.125 and 0.25. Instance 0
has position `(1,2,3)`, uniform scale 2 and tint `(0.2,0.4,0.6,0.8)`. Instance 1
has position `(-2,1,4)`, scale `(-1,2,0.5)` and tint `(0.8,0.3,0.1,1)`; its
explicit empty playback permits that reflected placement without yaw extraction.
Instance 0 has root node 2, base ordinal 0 and four authored actions; instance 1
is configured with no actions. A prepared crowd writes the same bytes, because
the projection omits runtime state.

`SHA256SUMS` records the committed file hashes.
