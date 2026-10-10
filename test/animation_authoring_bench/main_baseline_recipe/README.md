# Main measurement recipe

Run only in an untouched checkout at
`73edb0d4a24a68f8de4f3d6a0064919cfe4f5e0b`. Copy these two recipe files into
`test/animation_authoring_bench` there. The normal current-head target explicitly
compiles only its own `bench.c3`; this retained recipe is not a second target and
is outside CI.

The source asset, count4096, A4, copied feathered row, per-instance placement,
view, timers, warm4/sample12/completion2, renderer options and profiling flags
match the current measurement recipe. Main has no generalized extraction or
inertial APIs. This recipe selects legacy planar EXTRACT with Y-yaw, reserves
no history and skips inertial requests. It reports that semantic feature
difference rather than claiming identical features.

```powershell
c3c build motion_bench --path test/animation_authoring_bench -O3
```

From the recipe's project directory:

```powershell
& build/motion_bench.exe --inertia-off --count=4096
```

The runtime log, measured row, compiler and recipe hashes are recorded in the
change's `slice-c-main-baseline.md`. No main production files were modified.
