# Historical animation codec inputs

Run this standalone recipe in the verified `387d69dabc6fd023a13d8182a678d1231ec34dc1`
checkout. It uses the unchanged registered Animator v1 and AnimatedCrowd v2 writers.
The version guard refuses newer writers. The source model is the existing
`test/fixtures/gltf/skin.gltf`, SHA-256
`2d63048337e5b5e0e2e6ba3eac5ebe5ce9a619c8aea7c0e27a99d4c48d86a7fc`.

From `C:/tmp/c3d-lod-v1-freeze`, in the compiler's default safe mode:

```powershell
c3c run animation_legacy_freeze --path test/animation_legacy_freeze -- C:/tmp/c3d-lod-v1-freeze C:/tmp/c3d-issue-353/test/fixtures/animation_legacy
```

The identical recipe is retained here and in the old checkout's
`test/animation_legacy_freeze`. This manual target is outside the normal test
sequence. It prints SHA-256 and byte counts for all six outputs:

- `animator-v1.bin`, `animator-v1.jsonc`
- `crowd-v2-pending.bin`, `crowd-v2-pending.jsonc`
- `crowd-v2-prepared.bin`, `crowd-v2-prepared.jsonc`

Load the source model with key `animation_legacy/model`. Its clip key is
`animation_legacy/model#anim/0`. Inputs contain keyed references, not clip payloads.
Capture hashes and execution receipts belong in the change evidence.

The Animator owner is named `legacy_animator`, placed at `(-4,1,6)` on layers 5,
with root node 2. Its ordered actions are a regular EXTRACT/yaw action with a
full boolean mask, a DIFFERENCE additive KEEP overlay with mask
`(false,true,true,false)`, then the two regular members of a 1D group. The base
uses speed -0.5, weight 0.6, no loop and paused playback. The overlay uses layer 1,
speed 0.75, weight 0.25 and looping playback. The group uses layer 2, positions
`(-1,2)`, parameter 0.5, weight 0.75, speed -0.25 and paused playback; member
speeds are 1 and 1.25. Nonzero action times and group phase are deliberately
excluded by the historical authoring projection.

The crowd is named `legacy_crowd`, placed at `(4,2,-8)` on layers 9. It has count
2, capacity 4, six action slots per instance, event capacity 0, tracing enabled
and pose bounds `[-4,4]` on each axis. Seed times are 0.125 and 0.25. Instance 0
has position `(1,2,3)`, uniform scale 2 and tint `(0.2,0.4,0.6,0.8)`. Instance 1
has position `(-2,1,4)`, scale `(-1,2,0.5)` and tint `(0.8,0.3,0.1,1)`; its
explicit empty playback permits that reflected placement without yaw extraction.

Instance 0 has root node 2 and base ordinal 0. Its four authored actions match
the historical rich-crowd regression: regular EXTRACT/yaw base at speed -0.5,
weight 0.6, paused and nonlooping; additive KEEP layer-1 overlay at speed 0.75,
weight 0 and looping playback; regular full-mask member at speed 1; additive
KEEP layer-2 partial-mask member at speed 1.25 and no loop. The last two actions
form a 1D group with positions `(-1,2)`, parameter 0.5, weight 0.75, speed -0.25
and paused playback. Instance 1 is explicitly configured with no actions,
spaces, root node or base action. The prepared capture follows genuine crowd
preparation and a 0.25-second update; runtime clocks remain excluded.

The recipe has been authored but must be executed and its output hashes
verified before claiming capture completion.
