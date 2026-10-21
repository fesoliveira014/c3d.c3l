# Animation performance

Crowd playback can run on worker threads, crowd instances that play the same clip at the same time share their track
samples, clips can be stored compressed, and each playback owner reserves fixed storage. This page states the contracts
and the costs a user plans for. It needs no feature flag; the worker pool belongs to the application or to the
[job add-on](jobs.md).

## Crowd playback on workers

`anim::crowd_update(&assets, &scene, dt)` advances and samples every prepared `AnimatedCrowd` on the calling thread and
publishes the palettes and batches ([crowds](crowds.md)). Underneath, `CrowdPlaybackState.update` is `advance`
followed by `sample_range` over every live instance. An application that wants workers calls the two steps itself:

```c3
crowd.playback.advance(&assets, dt);
// Run sample_range over disjoint ranges on the application's pool.
anim::publish_crowd_pose(&assets, &scene, crowd);
```

| Call | Thread | Effect |
| --- | --- | --- |
| `advance(&assets, dt)` | Owner thread | Steps every instance's clocks, fades and groups and writes the crowd-wide event prefix in instance order. |
| `sample_range(&assets, first, count, &scratch)` | Any thread | Blends the poses and morph weights of instances `[first, first + count)` into their own slices and extracts their root motion, inertial correction and history, writing `slot.root_motion`. |
| `publish_crowd_pose(&assets, &scene, crowd)` | Owner thread | Publishes palettes and morph weights from the sampled poses and updates the part batches. |

- Call `sample_range` once per instance after each `advance`. A repeat steps inertial history and root motion again.
- Calls on disjoint ranges may run concurrently in any order, each with its own scratch from
  `create_crowd_pose_scratch(state)`, which faults `CAPACITY_EXCEEDED` when its allocation fails; free it with
  `destroy_crowd_pose_scratch(state, scratch)`. The state's own scratch serves `update` and one serial caller.
- Nothing structural may change in the store, the crowd or its players until every call returns.
- A call allocates nothing and writes nothing shared. Each instance's output depends only on its own state, so range
  splits, order and thread count change no pose, morph weight, root motion or event, bit for bit.
- Core never imports `c3d::job`. The `job_bench --crowd COUNT` example runs this sequence on the job pool.

### Shared samples within a frame

Instances that play the same clip at the same time repeat the same track sampling. Every scratch from
`create_crowd_pose_scratch`, and the state's own, holds a `PoseCache` of `POSE_CACHE_CAPACITY` (64) entries that lets
them share it.

- **Key.** An entry is keyed on the clip ID, the clip revision and the exact bits of the action's time, and holds the
  samples of the tracks the plain blend branch sampled. A later action at the same key reads the tracks it needs and
  samples the rest, so a masked or differently present action never samples a track it would not sample alone.
- **Exact.** Poses, morph weights, root motion and events equal an uncached `update` bit for bit, for any range split,
  order and thread count. Time is assumed finite, as crowd seeds require.
- **Uncached.** The first sighting of a key only claims its slot, so a frame without repeats records nothing. Actions
  also sample uncached on the onset and generalized-motion paths, for additive actions and when the key's slot window is
  full. A scratch from a single model's animator has no cache.
- **Lifetime.** `advance` starts a new sample generation and `sample_range` empties a scratch whose generation differs.
  A cache is private to its scratch and takes no locks.
- **Small ranges.** A scratch saves from the third action on a key. With ranges of a few dozen instances, hits are rare
  and lookups can cost more than they save; give each scratch a few hundred instances.
- **Counters.** `PoseCache.lookups` counts the actions that consulted the cache and `PoseCache.hits` those that found
  samples an earlier action recorded.

Cost: an entry is `28 B + 8 B * (3 * nodes + meshes) + 4 B * (10 * nodes + morph weights)`, and a scratch holds 64 of them.

The `skinned_crowd --shared-phases` example puts instances into groups that share a clip and a time, and shows the sample
time and hit rate. `job_bench --crowd COUNT --shared-phases` times the same crowd on several worker counts.

## Compressed clips

`assets.compress_clip(clip, tolerance)` drops keys and quantizes a clip's key data once, at load or import time.

| `ClipTolerance` field | Unit |
| --- | --- |
| `translation` | metres |
| `rotation` | radians |
| `scale` | ratio |
| `weight` | weight units |

- **Storage.** Translation, scale and morph-weight tracks store 16-bit codes per component over the track's own range.
  Rotation tracks store smallest-three codes in 48 bits. Times are never quantized, and tracks of one clip whose time
  arrays are identical share one.
- **Key reduction.** Before quantizing, linear and step tracks drop every key that the kept keys reproduce within half
  of the tolerance, which leaves the other half for quantization. The reported error sits near half the tolerance.
  Cubic spline tracks keep every key, quantize values and tangents and report an analytic per-segment bound. Cubic
  rotations and empty tracks stay raw.
- **Report.** The call returns a `CompressionReport` with the largest error per path and the bytes before and after. It
  measures at every source key time, and for rotations and cubic tracks also at each segment's midpoint, so such an error
  is the larger of those samples and not a true maximum.
- **Faults.** `TOLERANCE_EXCEEDED` when an error exceeds its tolerance; `CAPACITY_EXCEEDED` on allocation failure;
  `INVALID_ARGUMENT` for invalid track data. A fault of any kind leaves the clip, its arrays and its revision unchanged.
  On success the raw arrays are freed, one block holds the packed keys and the revision moves once. A clip with no
  packable track (no keys, or only cubic rotations) stays unchanged: the report shows equal byte counts and the revision
  does not move.
- **Contract.** Compressing a compressed clip is a contract violation (`clip.data.is_compressed()`). A later
  `replace_clip_owned` installs raw tracks again.
- **Drift.** Error is bounded per key, so a looping root-motion clip's per-cycle displacement can drift by up to twice the
  translation tolerance, and the drift accumulates over cycles.
- **Reading keys.** Code that reads keys uses `Track.key_count`, `key_time` and `read_key`, because `Track.values` holds
  floats only while `encoding` is `RAW`.

Compressed tracks sample with the same cursor contract but cost more CPU to sample than raw ones, because every key read
is dequantized: compression trades sampling time for memory. The blends pick the raw or the dispatching sampler once per
clip, so raw clips pay no dequantization cost. `skinned_crowd --compress` and `job_bench --crowd COUNT --compress` compress the
model's clips with a tolerance of 1e-3 on every path and print the bytes before and after.

## Memory costs

| Storage | Cost |
| --- | --- |
| `Animator` component store | `(max_nodes + 1) * Animator::size` bytes, used or not (16,385 slots in the default scene), plus the ECS index arrays and the arrays of each live animator. |
| Mask rows | `MAX_ACTIONS * node_count` bytes per animator, allocated by `add_animator`. |
| Weighted mask | `node_count * float::size` extra bytes per masked action until it is removed. |
| Action cursors and additive references | Sized by the clip's tracks, allocated at `play`. |
| Prepared 2D storage | See below. |
| Inertial storage | Per owner when enabled, none otherwise; a crowd reserves it for its full capacity, including inactive placements. Each row holds a previous node pose, velocity and offset rows, one byte per node of scale membership and 28 bytes per logical morph component. |

Per-frame updates allocate nothing: evaluation scratch is allocated once, with the owner.

### Prepared storage

Every playback owner prepares two 2D rows even when neither is active. For action capacity `A`, each row holds `A`
action IDs, `A` coordinates, up to `max(0, 2*A - 5)` three-byte triangles and `A` two-byte hull edges. Both rows share
one allocation with the two `BlendSpace2D` controls (120 bytes each on x64, eight-byte aligned):

| Action capacity | Retained 2D bytes per playback owner |
| ---: | ---: |
| 1 | 288 |
| 2 | 320 |
| 3 | 368 |
| 4 | 416 |
| 8 | 608 |
| 9 | 656 |
| 15 | 944 |
| 16 | 992 |

An `Animator` pays 992 bytes. A crowd pays the table value for every slot of its fixed capacity, including inactive
slots. These bytes exclude the 1D rows, actions, cursors, additive references and weighted mask rows. Group updates
allocate nothing; creation allocates only the members' captured action data.

## Limits

- `sample_range` calls on overlapping ranges, or structural changes during a call, are contract violations.
- Compressed clips are for load-time use: compression is irreversible except by replacing the clip.
- The shared-sample cache saves nothing when instances rarely share a clip and time.

## See also

- [Animation](animation.md) for playback.
- [Animated crowds](crowds.md) for crowd creation and per-instance playback.
- [Jobs](jobs.md) for the worker pool.
- [Animation deformation](animation_deformation.md) for what the renderer does with the sampled poses.
