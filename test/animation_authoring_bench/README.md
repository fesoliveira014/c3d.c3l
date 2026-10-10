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
history, prepared 2D rows, weighted rows and temporary request peak reported
separately. The node/palette counts are generated output counts, not timings.
No performance thresholds apply.

The requested disabled-inertia comparison keeps generalized extraction and
all other current-head fixture/view/storage controls:

```powershell
c3c run motion_bench --path test/animation_authoring_bench -O3 -- --inertia-off --count=4096
```

The disabled row reserves no inertial history, reports its flag explicitly and
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
