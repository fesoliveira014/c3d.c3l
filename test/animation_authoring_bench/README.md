# Bounded animation authoring measurements

Manual target, outside `scripts/build.py --test`. The program emits exactly
three rows of scenario measurements: 64, 512 and 4096 Quaternius instances,
one view, enabled generalized extraction and inertial storage, four prepared
action slots and a copied weighted row per instance. It warms four frames,
collects twelve updates plus two completion frames, then measures one public
inertial request for every instance. No scenario combinations or readbacks run.

```powershell
c3c --version
c3c run motion_bench --path test/animation_authoring_bench -O3
```

The run command selects `test/animation_authoring_bench` as the working
directory. The producer reports adapter/driver and the source asset hash. Record the
machine, compiler and actual optimization command with its output. Validation
is explicitly off. This is measurement-only evidence; correctness uses the
separate safe, validation-on native acceptance target.

CPU update includes pose evaluation and palette publication. CPU record also
includes frame-slot waits. GPU values sum completed pass intervals and report
the number available; zero samples mean unavailable, not zero work. Palette
stream bytes are the exact generated matrix payload per frame, while the
renderer upload counter covers asset uploads. No readback work is included.
Retained bytes cover scene-owned allocations tracked by the allocator, with
inertial storage, prepared 2D rows, weighted rows and temporary request peak reported
separately. The node/palette counts are generated output counts, not timings.
No performance thresholds apply.

The requested disabled-inertia comparison keeps generalized extraction and
all other current-head fixture/view/storage controls:

```powershell
c3c run motion_bench --path test/animation_authoring_bench -O3 -- --inertia-off --count=4096
```

The disabled row reserves no inertial storage, reports its flag explicitly and
skips request measurement because `inertialize` requires enabled storage. It
still prepares four action slots and copied weighted masks. The separate main
baseline uses the closest supported planar EXTRACT/Y-yaw path, so its labels
state a feature difference; it is not a strict comparison of identical features.

For the same supported extraction feature as the retained main recipe:

```powershell
c3c run motion_bench --path test/animation_authoring_bench -O3 -- --inertia-off --legacy-planar --count=4096
```

This current-head row uses the exact legacy `PlayDesc` from main: weighted mask,
`EXTRACT`, `root_yaw=true`, and an empty generalized extraction descriptor. It
keeps the same corpus, A4, times/speeds, placements, view, renderer options and
measurement protocol. The generalized/off row remains a separate feature path.

One optional diagnostic split uses the same public update boundaries as
`anim::crowd_update`, with one additional timestamp between them:

```powershell
c3c run motion_bench --path test/animation_authoring_bench -O3 -- --inertia-off --legacy-planar --count=4096 --phase-times
```

`evaluation` times `CrowdPlaybackState.update`; `palette_batch_publication`
times `publish_crowd_pose`, including joint worlds/palettes and batch dirtying.
It advances playback once per frame and preserves the same corpus/control
sequence. These two medians need not sum to the total-update median, because
medians are taken independently. The retained original main witness remains
unchanged; a private diagnostic main recipe can add the same timestamps.

Every run prints compiler-derived layout sizes before its scenario rows.
Retained fields are captured after the measured updates and before transition
requests. Allocation sizes count requested bytes, including explicit block
padding; they exclude the backing allocator's bookkeeping. Asset-store and
renderer allocations use separate allocators and are outside `retained_bytes`.

| Fields | Meaning |
| --- | --- |
| `action_capacity_slots`, `action_slots_bytes` | Every reserved slot: crowd capacity times actions per instance times `Action::size`, including unused slots. |
| `slot_records_bytes` | All `CrowdPlaybackSlot` records, including their embedded generalized state. |
| `embedded_generalized_bytes` | The generalized subset of `slot_records_bytes`; do not add it again. |
| `scene_component_capacity`, `scene_animator_records_bytes`, `scene_crowd_records_bytes` | Eagerly reserved scene component records, even when no ordinary Animator is live. Scene capacity includes its root node. |
| `pool_metadata_bytes`, `boolean_masks_bytes` | Action generations, free lists, order arrays and reserved boolean mask rows. |
| `one_d_bytes`, `two_d_bytes` | Reserved group storage, including copied 2D points, topology and member arrays. |
| `cursor_bytes`, `reference_bytes`, `weighted_bytes` | Arrays owned by the actions live at the retained snapshot. |
| `capture_total_bytes` | Live generalized captures: headers, chain nodes, model layout, copied name bytes and scale sums. |
| `capture_headers_bytes` | The `CapturedMotionChain` records. Their headers include the scale-sums slice; the pointer itself is already in the reserved `Action`. |
| `capture_scale_sums_bytes` | Double scale rows prepared for generalized playback without derivative scratch: model nodes times `double[<3>]::size` per retained capture. |
| `channel_sums_bytes` | Shared legacy `ChannelSums` rows; these contain no double scale values. |
| `derivative_scratch_bytes` | Shared opt-in analytic scratch, including its header and scale values. `derivative_scale_values_bytes` is a subset. |
| `inertial_storage_bytes` | The complete capacity-sized inertial block. This includes row headers, pose/morph payload and header/alignment padding. |
| `inertial_row_headers_bytes`, `inertial_payload_bytes`, `inertial_header_padding_bytes` | Disjoint parts of `inertial_storage_bytes`; these are not additional allocations. |
| `attributed_playback_bytes` | The disjoint categories above plus the playback-state and pose-storage headers and scene animation component records. Embedded subsets are counted once. |
| `other_scene_bytes` | `retained_bytes` minus the attributed categories: remaining scene, pose, palette, batch and component allocations. |
| `request_peak_extra` | Peak tracked bytes above the retained snapshot while requests run. |

The retained decomposition attributes bytes; it does not identify a timing cost.
The private current/baseline layout probes supply the `Action` and slot-size
comparison. Their receipts and measured timings belong in change evidence.
