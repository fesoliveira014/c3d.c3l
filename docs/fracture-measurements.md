# Fracture kernel measurements

Measured on 2026-10-07 with generated-point omission enabled. Every configured call succeeded: 105 cases, one warmup and three measured repetitions per case. [The historical report](fracture-measurements-before-omission.md) retains the earlier geometry, its cost measurements and the separate convexity-deduplication comparison. This is cost and capacity evidence; performance acceptance remains open. Native collision cooking, serialization, asset installation and GPU work are outside these timings.

## Reproduce

```powershell
c3c build kernel_bench --path addons/c3d_physics.c3l/test/bench -O3
addons/c3d_physics.c3l/test/bench/build/kernel_bench.exe all --single-pass
addons/c3d_physics.c3l/test/bench/build/kernel_bench.exe all > kernel-measurements.jsonl
```

The executable accepts `all`, `kernel`, `wall`, `concave`, `hollow`, `impact_local`, `staircase` or `rotations`. `--single-pass` disables warmup and runs one measurement. Failed calls retain their counters and named fault, stop repetitions of that case, continue remaining cases and produce exit code 1. Invalid arguments or workspace setup failure produce exit code 2. The target is manual and is not part of the ordinary build or test suite.

The reported final run pinned the process to logical processor 0 to control scheduling changes. After building, reproduce that setting with:

```powershell
$run = Start-Process -FilePath "$PWD/addons/c3d_physics.c3l/test/bench/build/kernel_bench.exe" `
    -ArgumentList "all" -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput "$PWD/kernel-measurements.jsonl"
$run.ProcessorAffinity = [IntPtr]1
$run.WaitForExit()
```

Host: Intel Core i9-14900K, 24 physical cores and 32 logical processors; Windows 11 Pro 10.0.26200. Compiler: C3 0.8.3, commit `1d155ee04d3b607261b99aa15ed5eefd6d7db284`, LLVM 22.1.8, Windows x64. Target `fp-math` is `strict`; `-O3` uses the compiler default of disabled runtime safety checks. No Linux or cross-machine timing is claimed.

Workspace limits: 256 MiB scratch, 1,048,576 output vertices, 1,048,576 output triangles, 256 pieces, 64 sites, 65,536 hulls and resolution 0.0001 m. The fixed arithmetic block is 24,888 bytes and has 24 wide temporaries. Generation fixtures and staircases use a 64-point hull limit; rotation cases use 128 and 4.

Fixture construction, workspace allocation and borrowed-source copying occur outside the measured calls. Generation includes `create_voronoi_fracture`; decomposition includes `create_fracture_collision`, including their owned output allocations. Destruction and JSON formatting are outside the timers. Counters are captured immediately after each public call, before workspace reuse. Times include instrumentation overhead.

[Raw measurements](measurements/fracture-kernel-windows-o3.csv) contain all 436 phase rows, including warmups. Tables use medians of the three measured repetitions. Scratch values are maximum arena use, including the fixed arithmetic block; they are not process memory measurements. Predicate fractions count filtered decisions, not time. Exact ordering and equality checks also contribute to predicate counts. Per-patch columns are independent maxima.

## Fixtures

| Fixture | Surface | Sites |
| --- | --- | --- |
| Wall | Box from (−4, −2, −0.125) to (4, 2, 0.125) m; 12 triangles | 4 × 4 × 4 regular cell centers; 64 sites |
| Concave | Unit-depth L prism over (0,0), (2,0), (2,1), (1,1), (1,2), (0,2); 20 triangles | 2 × 2 × 2 cell centers over its bounding box; 8 sites |
| Hollow | Outer box ±2 m, reversed inner box ±1.5 m; 24 triangles | 2 × 2 × 2 cell centers over the outer box; 8 sites |
| Impact local | Same wall | 32 centers in (0.25, −0.75, −0.125)–(1.75, 0.75, 0.125), plus 32 over the complete wall; both 4 × 4 × 2 |
| Staircase | Unit-depth extrusion of n unit steps; 4n + 4 vertices and 8n + 4 triangles | Collision only; n = 4, 8, 16, 32, 64 |
| Rotations | Unit box, L prism, outer ±3 / cavity ±1 box, outer ±3 / cavity ±2 / island ±1 nested boxes | Collision only; 12 rotations per surface and two hull limits |

Rotation sample i uses a double-precision quaternion about normalized (1, 2+i, 3), with angle 0.1 + 0.37i radians, followed by one conversion to float positions. This matches the collision acceptance fixtures. Sites are Voronoi partition coordinates and may lie outside material: the concave fixture has two sites in the notch, and the hollow fixture has sites in its cavity.

## Generation and decomposition

| Fixture | Phase | Median ms | Peak MiB | Splits | Final leaves | Predicates | Filtered % | Exact ms | Wide peak | Partition % |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| wall | generation | 216.932 | 15.546 | 2,484 | 64 | 572,470 | 35.06 | 79.074 | 23 | 0.00 |
| wall | decomposition | 165.254 | 2.703 | 0 | 64 | 278,472 | 42.76 | 77.595 | 21 | 63.70 |
| concave | generation | 36.052 | 0.491 | 32 | 6 | 98,886 | 35.81 | 13.941 | 23 | 0.00 |
| concave | decomposition | 23.153 | 0.388 | 0 | 6 | 40,092 | 44.17 | 10.652 | 21 | 71.96 |
| hollow | generation | 66.867 | 0.993 | 141 | 24 | 184,540 | 40.24 | 24.151 | 23 | 0.00 |
| hollow | decomposition | 73.553 | 1.109 | 32 | 40 | 146,514 | 36.75 | 33.602 | 21 | 67.55 |
| impact_local | generation | 292.716 | 9.675 | 1,599 | 64 | 720,013 | 40.37 | 109.561 | 23 | 0.00 |
| impact_local | decomposition | 272.213 | 3.737 | 0 | 64 | 431,772 | 46.45 | 121.848 | 21 | 64.61 |

Splits count actual cell splits across a call. Final leaves count material cells before publication; pieces count connected published fragments. The hollow case therefore has 24 generation leaves and eight pieces. Decomposition reports no output render triangles because it produces hull point sets.

| Fixture | Input triangles | Published vertices | Published triangles | Triangle ratio | Pieces | Hulls | Hull points | Points per piece |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| wall | 12 | 1,536 | 768 | 64.00 | 64 | 64 | 512 | 8 |
| concave | 20 | 176 | 104 | 5.20 | 6 | 6 | 64 | 10–11 |
| hollow | 24 | 336 | 192 | 8.00 | 8 | 40 | 256 | 32 |
| impact_local | 12 | 1,944 | 1,072 | 89.33 | 64 | 64 | 664 | 8–15 |

The CSV retains hull and point counts for every piece in piece-index order. All output counts and non-timing counters were identical across the three measured repetitions.

| Fixture / phase | Max planar segments | Max planar points | Max patch vertices | Max patch predicates | Median of maximum patch ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| wall / generation | 4 | 4 | 4 | 6 | 0.010 |
| wall / decomposition | 3 | 3 | 0 | 0 | 0.000 |
| concave / generation | 11 | 6 | 6 | 35 | 0.036 |
| concave / decomposition | 3 | 3 | 0 | 0 | 0.000 |
| hollow / generation | 12 | 8 | 6 | 58 | 0.052 |
| hollow / decomposition | 6 | 6 | 0 | 0 | 0.000 |
| impact_local / generation | 7 | 7 | 7 | 105 | 0.131 |
| impact_local / decomposition | 3 | 3 | 0 | 0 | 0.000 |

Zero patch-triangulation counters mean that path was not used by the phase.

## Staircase scaling

Current costs include point-retention certification. The earlier convexity optimization and its original paired timing remain in the historical report; those timings describe the geometry before omission.

| Steps | Triangles | Median ms | Peak MiB | Splits / leaves / hulls | Hull points | Predicates | Exact ms | Partition % |
| ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |
| 4 | 36 | 8.857 | 0.202 | 3 / 4 / 4 | 32 | 26,786 | 3.338 | 76.58 |
| 8 | 68 | 20.464 | 0.401 | 7 / 8 / 8 | 64 | 76,979 | 7.859 | 79.42 |
| 16 | 132 | 67.242 | 0.882 | 15 / 16 / 16 | 128 | 264,539 | 22.810 | 85.10 |
| 32 | 260 | 300.352 | 2.170 | 31 / 32 / 32 | 256 | 1,112,869 | 83.551 | 93.68 |
| 64 | 516 | 1740.343 | 6.059 | 63 / 64 / 64 | 512 | 5,691,529 | 379.442 | 97.93 |

Staircase split, leaf, hull and point counts are unchanged by omission. The CSV retains every measured phase and the corresponding scratch, predicate and timing counters.

## Rotated collision surfaces

Each row covers 12 rotations. The time median is the median of each case's three-run median; the maximum is the largest case median. Every case supplies one piece record, including the nested-shell fixture. Hull and point counts are ranges across rotations.

| Surface | Hull limit | Median ms | Maximum ms | Peak MiB | Splits | Final leaves | Hulls per piece | Points per piece |
| --- | ---: | ---: | ---: | ---: | --- | --- | --- | --- |
| rotation_box | 128 | 2.364 | 2.430 | 0.074 | 0 | 1 | 1 | 8 |
| rotation_box | 4 | 2.396 | 2.482 | 0.074 | 0 | 1 | 12 | 48 |
| rotation_l_prism | 128 | 5.257 | 5.543 | 0.142 | 1 | 2 | 2 | 16 |
| rotation_l_prism | 4 | 5.415 | 6.114 | 0.142 | 1 | 2 | 24 | 96 |
| rotation_hollow | 128 | 216.735 | 283.262 | 2.678 | 27–48 | 28–49 | 28–49 | 160–269 |
| rotation_hollow | 4 | 216.610 | 283.878 | 2.678 | 27–48 | 28–49 | 190–303 | 760–1212 |
| rotation_nested | 128 | 326.765 | 501.237 | 4.310 | 41–81 | 43–83 | 43–83 | 266–507 |
| rotation_nested | 4 | 333.058 | 498.882 | 4.310 | 41–81 | 43–83 | 338–649 | 1352–2596 |

The largest current four-point output has 649 hulls and 2,596 point entries for one nested-shell piece. The maximum measured arithmetic demand is 23 of 24 wide temporaries during generation and 24 during decomposition. The largest measured arena demand is 15.546 MiB for wall generation; the configured 256 MiB is a caller limit, not a measured requirement.

## Before and after omission

The comparison uses identical fixture positions, site layouts, resolution, output limits and piece ordering. Generated-point omission changes collision hull contents. The four generation fixtures and all staircases retain their prior hull and point counts. Counts change in all 72 non-box rotation cases; none of the 243 supplied pieces increases its hull or point count.

[Per-piece comparison](measurements/fracture-omission-per-piece.csv) records every case and piece. [Earlier raw measurements](measurements/fracture-kernel-before-omission-windows-o3.csv) preserve the complete pre-omission snapshot. The ranges below combine pieces and rotations within each row.

| Fixture | Hull limit | Hulls per piece before | Hulls per piece after | Points per piece before | Points per piece after |
| --- | ---: | --- | --- | --- | --- |
| wall | 64 | 1 | 1 | 8 | 8 |
| concave | 64 | 1 | 1 | 10–11 | 10–11 |
| hollow | 64 | 5 | 5 | 32 | 32 |
| impact_local | 64 | 1 | 1 | 8–15 | 8–15 |
| staircase | 64 | 4–64 | 4–64 | 32–512 | 32–512 |
| rotation_box | 128 | 1 | 1 | 8 | 8 |
| rotation_box | 4 | 12 | 12 | 48 | 48 |
| rotation_l_prism | 128 | 2 | 2 | 18–21 | 16 |
| rotation_l_prism | 4 | 26–30 | 24 | 104–120 | 96 |
| rotation_hollow | 128 | 28–49 | 28–49 | 227–434 | 160–269 |
| rotation_hollow | 4 | 303–629 | 190–303 | 1212–2516 | 760–1212 |
| rotation_nested | 128 | 43–83 | 43–83 | 383–785 | 266–507 |
| rotation_nested | 4 | 531–1147 | 338–649 | 2124–4588 | 1352–2596 |

For nested-shell rotation 10 at the four-point limit, the prior maximum falls from **1,147 to 649 hulls** and **4,588 to 2,596 point entries**, a 43.4% reduction in both counts. At the 128-point limit, the same case keeps 83 hulls and reduces point entries from 785 to 507. Each point count sums hull-array entries; a position shared by multiple hulls is counted in each hull.

## Verification and source identity

The current omission snapshot completed the manual 105-case benchmark through one warmup and three measured repetitions. The convexity invariant passed under both `-O4` with the target's strict math setting and `-O4 --fp-math=fast`, using `c3c test fracture_test --path addons/c3d_physics.c3l --test-filter test_collision_chunk_convexity_`; each invocation ran one test and skipped 188. These tests cover equivalent point constructions, opposing constraints, scratch exhaustion and reuse. Wider collision and native-cooking acceptance belongs to the integrating change.

The historical report's byte-identical export comparison applies only to the convexity-deduplication change before omission. It does not describe current collision output. The per-piece comparison above records the current output changes explicitly.

The source baseline was `5f0c528e02bd27b5ddc77d5cf757dd194908ea0b`, plus the omission integration snapshot below. Legacy `collision_cells.c3` and `collision_surface.c3` were absent. SHA-256 values use the measured UTF-8 source text with LF line endings, independent of checkout newline conversion. The witness helper subsequently gained compile-time bit-bound constants and assertions; its executable function bodies were unchanged.

| File under `addons/c3d_physics.c3l/` | SHA-256 as measured |
| --- | --- |
| `src/fracture/collision.c3` | `6f924e9f8a1aaba038343a696ffb69ba8d54c8bbb2e6b79b0fc193dc8d46ca93` |
| `src/fracture/collision_cover.c3` | `3410024bdc8d9efcd4801631ce6c2fb2503c5c1486c08c333fd9ec3806cd4eaa` |
| `src/fracture/collision_reconstruction.c3` | `10c786cce601797f5cbcc131abf15cd3edb9f16ce30f34f0ce777ca58839fbb5` |
| `src/fracture/collision_retained.c3` | `66b7795faecdaff2003fbe18de5126e91dead94866258eb09304b1766313ddaf` |
| `src/fracture/collision_validation.c3` | `249114f1bd646da0d285339d8d0bd056e79e77c5d2bedc1ba3b2ae2dcc2bc96c` |
| `src/fracture/collision_witness.c3` | `6e99a34426bf4b06a36e084182d477256a4ea91e9a3d6a7302673c9ac6b7efa6` |
| `src/fracture/collision_chunks.c3` | `f1ee88bfd3475fd114e765c055efcd22b1323c43f5112261abb6e4b42aecc122` |
| `src/fracture/exact.c3` | `1082c1df2dd80893203aa53631e34e8f62963499b0bde8a02664d32963a30dc3` |
| `src/fracture/workspace.c3` | `6de7486da13d40e67bbfedb9e04c162ad06ec0ce28ac2b63bfa49ae24aadace9` |
| `test/bench/kernel_fixtures.c3` | `e454bc5bf36b5a832361b8194fb8a100682c199ab8db8e82736d13ccdebbb494` |
| `test/bench/kernel_measurements.c3` | `28b39b6afcb3951fa5859a5a73cd426e2b3dc8c87793e540f48e98c4778c5b27` |
