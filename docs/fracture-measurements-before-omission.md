# Fracture kernel measurements before point omission

Historical measurements from 2026-10-07, before generated-point omission. These figures describe the earlier retained-point geometry; [current measurements](fracture-measurements.md) cover the omission implementation. Every configured call succeeded: 105 cases, one warmup and three measured repetitions per case. This is cost and capacity evidence; performance acceptance remains open. Native collision cooking, serialization, asset installation and GPU work are outside these timings.

## Reproduce

These commands describe the benchmark invocation. Reproducing these historical results requires the source snapshot identified below. The current executable measures the omission geometry.

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

[Raw measurements](measurements/fracture-kernel-before-omission-windows-o3.csv) contain all 436 phase rows, including warmups. Tables use medians of the three measured repetitions. Scratch values are maximum arena use, including the fixed arithmetic block; they are not process memory measurements. Predicate fractions count filtered decisions, not time. Exact ordering and equality checks also contribute to predicate counts. Per-patch columns are independent maxima.

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
| wall | generation | 213.216 | 15.546 | 2,484 | 64 | 572,470 | 35.06 | 76.184 | 23 | 0.00 |
| wall | decomposition | 162.483 | 2.728 | 0 | 64 | 278,472 | 42.76 | 73.531 | 21 | 63.89 |
| concave | generation | 33.399 | 0.491 | 32 | 6 | 98,886 | 35.81 | 12.644 | 23 | 0.00 |
| concave | decomposition | 21.922 | 0.391 | 0 | 6 | 40,092 | 44.17 | 9.639 | 21 | 72.78 |
| hollow | generation | 66.063 | 0.993 | 141 | 24 | 184,540 | 40.24 | 23.371 | 23 | 0.00 |
| hollow | decomposition | 71.959 | 1.115 | 32 | 40 | 146,514 | 36.75 | 31.760 | 21 | 68.84 |
| impact_local | generation | 282.527 | 9.675 | 1,599 | 64 | 720,013 | 40.37 | 104.538 | 23 | 0.00 |
| impact_local | decomposition | 258.349 | 3.774 | 0 | 64 | 431,772 | 46.45 | 114.498 | 21 | 65.33 |

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
| wall / generation | 4 | 4 | 4 | 6 | 0.013 |
| wall / decomposition | 3 | 3 | 0 | 0 | 0.000 |
| concave / generation | 11 | 6 | 6 | 35 | 0.035 |
| concave / decomposition | 3 | 3 | 0 | 0 | 0.000 |
| hollow / generation | 12 | 8 | 6 | 58 | 0.052 |
| hollow / decomposition | 6 | 6 | 0 | 0 | 0.000 |
| impact_local / generation | 7 | 7 | 7 | 105 | 0.169 |
| impact_local / decomposition | 3 | 3 | 0 | 0 | 0.000 |

Zero patch-triangulation counters mean that path was not used by the phase.

## Staircase scaling and convexity deduplication

Temporary phase timing of the original 64-step case measured 6.343 s in convexity checks and 2.355 s in the reflex-split helper. The latter included 1.330 s of candidate selection and 0.070 s of actual splitting. The remaining search work was about 0.955 s. This identified repeated convexity checks as the larger measured cost.

Convexity now tests each distinct canonical plane with its effective orientation against each distinct exact point. Exact coordinate comparisons merge points with equivalent constructions. Opposite orientations remain separate. The same side and resolution checks run after deduplication, and query storage is rewound. Cut selection and output reconstruction are unchanged.

The following paired runs used logical processor 0, one warmup and three repetitions for each implementation. [Baseline measurements](measurements/fracture-staircase-before.csv) retain all 20 original phase rows. The earlier unpinned exploratory run overlapped other work and is excluded from these medians.

| Steps | Triangles | Before ms | After ms | Speedup | Peak MiB | Splits / leaves / hulls | Predicates after | Partition % after |
| ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| 4 | 36 | 9.620 | 8.054 | 1.19× | 0.202 | 3 / 4 / 4 | 26,786 | 73.92 |
| 8 | 68 | 30.268 | 20.019 | 1.51× | 0.401 | 7 / 8 / 8 | 76,979 | 79.58 |
| 16 | 132 | 134.719 | 65.406 | 2.06× | 0.882 | 15 / 16 / 16 | 264,539 | 87.01 |
| 32 | 260 | 827.993 | 279.936 | 2.96× | 2.170 | 31 / 32 / 32 | 1,112,869 | 94.11 |
| 64 | 516 | 5818.959 | 1687.207 | 3.45× | 6.059 | 63 / 64 / 64 | 5,691,529 | 97.97 |

At 64 steps the predicate count fell from 13,366,997 to 5,691,529. Split, leaf and hull counts and peak scratch were unchanged. Smaller fixtures can perform more predicates because exact deduplication adds sorting comparisons; the measured total time is reported above.

## Rotated collision surfaces

Each row covers 12 rotations. The time median is the median of each case's three-run median; the maximum is the largest case median. Every case supplies one piece record, including the nested-shell fixture. Hull and point counts are ranges across rotations.

| Surface | Hull limit | Median ms | Maximum ms | Peak MiB | Splits | Final leaves | Hulls per piece | Points per piece |
| --- | ---: | ---: | ---: | ---: | --- | --- | --- | --- |
| rotation_box | 128 | 2.266 | 2.562 | 0.074 | 0 | 1 | 1 | 8 |
| rotation_box | 4 | 2.288 | 2.489 | 0.074 | 0 | 1 | 12 | 48 |
| rotation_l_prism | 128 | 5.196 | 5.750 | 0.142 | 1 | 2 | 2 | 18–21 |
| rotation_l_prism | 4 | 5.229 | 6.291 | 0.142 | 1 | 2 | 26–30 | 104–120 |
| rotation_hollow | 128 | 219.168 | 286.262 | 2.678 | 27–48 | 28–49 | 28–49 | 227–434 |
| rotation_hollow | 4 | 220.409 | 287.582 | 2.678 | 27–48 | 28–49 | 303–629 | 1212–2516 |
| rotation_nested | 128 | 324.512 | 486.684 | 4.310 | 41–81 | 43–83 | 43–83 | 383–785 |
| rotation_nested | 4 | 334.157 | 497.237 | 4.310 | 41–81 | 43–83 | 531–1147 | 2124–4588 |

The largest four-point output has 1,147 hulls and 4,588 point entries for one nested-shell piece. The maximum measured arithmetic demand is 23 of 24 wide temporaries across generation and 21 during decomposition. The largest measured arena demand is 15.546 MiB for wall generation; the configured 256 MiB is a caller limit, not a measured requirement.

## Verification and source identity

The separate collision exporter produced byte-identical source and hull meshes for all 96 cases before and after deduplication, with no exporter failures. Both files have SHA-256 `5dc676d2bed3967d18e08d71014dd2de8c6139ebdbb584d518e25e5e9b0c4351`. This checks output preservation for that corpus; the independent geometric and native-cooking acceptance results are recorded separately.

The focused invariant test covers equivalent point constructions, opposing constraints, scratch exhaustion and reuse. Existing chunk coverage checks rotated reflex edges, nested islands and triangle permutations. The filtered command `c3c test fracture_test --path addons/c3d_physics.c3l --test-filter collision_` passed 39 tests in each of `-O0 --safe=yes`, `-O0 --safe=no`, `-O3 --safe=yes` and `-O3 --safe=no`; each run skipped the other 159 tests. Local validation stayed within the affected collision area.

The source baseline was `ae4c956cbac905ee2fa60e208c8357bf1afb770b`, plus the integration dependencies and convexity change listed below. SHA-256 values use UTF-8 source text with LF line endings, independent of checkout newline conversion.

| File under `addons/c3d_physics.c3l/` | SHA-256 |
| --- | --- |
| `src/fracture/collision.c3` | `34307385656aad047f127b66f608ab01739ce976cea7a85ccb8f8036d5c4f953` |
| `src/fracture/collision_cover.c3` | `3410024bdc8d9efcd4801631ce6c2fb2503c5c1486c08c333fd9ec3806cd4eaa` |
| `src/fracture/collision_reconstruction.c3` | `794f509e314e43babfedc24400ed80dacd9b45bfbe2871bc4ebccb315b8644ec` |
| `src/fracture/collision_chunks.c3` | `f1ee88bfd3475fd114e765c055efcd22b1323c43f5112261abb6e4b42aecc122` |
| `src/fracture/exact.c3` | `1082c1df2dd80893203aa53631e34e8f62963499b0bde8a02664d32963a30dc3` |
| `src/fracture/workspace.c3` | `6de7486da13d40e67bbfedb9e04c162ad06ec0ce28ac2b63bfa49ae24aadace9` |
| `test/bench/kernel_fixtures.c3` | `e454bc5bf36b5a832361b8194fb8a100682c199ab8db8e82736d13ccdebbb494` |
| `test/bench/kernel_measurements.c3` | `28b39b6afcb3951fa5859a5a73cd426e2b3dc8c87793e540f48e98c4778c5b27` |
