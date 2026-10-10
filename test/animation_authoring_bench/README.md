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
