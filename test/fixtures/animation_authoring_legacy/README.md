# Historical weighted and planar animation authoring

Frozen Animator v2 and AnimatedCrowd v3 streams, written by the registered writers at
`ccab31a73f6f6a2b6bd358bf64ce554e618d1674`. The motion codec tests read them to check
that old saves still restore:

- `animator-v2.bin`, `animator-v2.jsonc`
- `crowd-v3-pending.bin`, `crowd-v3-pending.jsonc`

The source is `test/fixtures/gltf/skin.gltf`, loaded with model key
`animation_authoring_legacy/model`; its clip key is
`animation_authoring_legacy/model#anim/0`. The streams contain keyed references, not
clip payloads.

The Animator has root node 2, a paused/nonlooping EXTRACT yaw base action with
speed -0.5 and weight 0.6, and three additive MULTIPLICATIVE members on layer 1.
Their copied weighted row is `(0,0.25,0.5,0.75)`. The 2D group's points are
`(-1,-1)`, `(2,-1)`, `(-1,2)`, authored triangle `(2,1,0)`, parameter `(0.5,0.25)`,
weight 0.75 and speed -0.25; it is paused.

The crowd has count 2, capacity 3, four actions per instance, event capacity 17
and tracing enabled. Instance 0 has the same base and 2D membership, root node 2,
base ordinal 0 and authored start 0.125. Its placement has positive uniform
scale 2. Instance 1 is explicitly configured with empty playback and has a
reflected, nonuniform placement. A prepared crowd writes the same bytes, because
the projection omits runtime state.

`SHA256SUMS` records the committed file hashes.
