# Authored lookup measurements

The reviewer independently confirmed the baseline at `113f30d` in the
[contract coverage review](https://github.com/fesoliveira014/c3d.c3l/pull/288).
These measurements characterize this workload; they are not an application budget.

## Workload and method

- Windows, Intel Core i9-14900K, C3 0.8.3, `-O3`, 2026-10-07.
- One root with direct children; every node has one fixed-size `Number` component.
- Each validator borrows the next node's decoded `Number`, wrapping at the end.
- Each size has one warm read without validation and one with validation, then
  five alternating pairs. Both paths parse identical JSONC text and attach the
  same components. Timing ends before removing the restored subtree.
- `lookup_ms` sums durations around the actual `ReadContext.authored` calls;
  it includes timer overhead. The test verifies every target and aggregate value.
- There are no timing thresholds in tests. Machine load can affect these results.

Reproduce with the explicit measurement target, excluded from `build.py --test`:

```text
c3c test serial_lookup_bench --path addons/c3d_serial.c3l -O3 --test-show-output
```

The baseline uses linear node/authoring scans and corrected depth/ID ordering
for JSON nodes. The measured source is the text-contract test slice; its
prerequisite import commit is `96a1b5f`.

## Local baseline

| Nodes | Text bytes | Median plain import (ms) | Median validated import (ms) | Median lookup total (ms) |
| ---: | ---: | ---: | ---: | ---: |
| 1,024 | 604,964 | 4.018 | 4.786 | 0.719 |
| 4,096 | 2,429,732 | 17.410 | 29.418 | 11.985 |
| 8,192 | 4,862,756 | 36.357 | 85.527 | 48.461 |

| Nodes | Sample | Plain import (ms) | Validated import (ms) | Lookup total (ms) |
| ---: | ---: | ---: | ---: | ---: |
| 1,024 | 1 | 4.119 | 4.786 | 0.707 |
| 1,024 | 2 | 3.949 | 5.281 | 1.045 |
| 1,024 | 3 | 4.083 | 4.726 | 0.738 |
| 1,024 | 4 | 4.002 | 5.629 | 0.719 |
| 1,024 | 5 | 4.018 | 4.713 | 0.713 |
| 4,096 | 1 | 17.521 | 29.565 | 12.071 |
| 4,096 | 2 | 17.410 | 29.418 | 12.085 |
| 4,096 | 3 | 16.916 | 28.839 | 11.420 |
| 4,096 | 4 | 18.264 | 29.070 | 11.810 |
| 4,096 | 5 | 17.043 | 29.737 | 11.985 |
| 8,192 | 1 | 39.625 | 83.729 | 47.386 |
| 8,192 | 2 | 36.669 | 85.527 | 48.370 |
| 8,192 | 3 | 36.357 | 86.767 | 50.097 |
| 8,192 | 4 | 35.258 | 85.766 | 49.829 |
| 8,192 | 5 | 35.965 | 84.476 | 48.461 |

For this workload, increasing nodes eightfold increases lookup time about 67-fold,
consistent with a full-document scan per lookup. Lookup time is about 57% of the
validated 8,192-node import. This supports evaluating a bounded per-record index;
the reviewer agreed a separate index bounded by document records and components.
The index described below implements that agreed document bound.

## Independently confirmed baseline

Reviewer run on the same i9-14900K at `113f30d`, C3 0.8.3 and `-O3`, using five
pairs after warm-up. These are the reviewer-reported medians:

| Nodes | Plain import (ms) | Validated import (ms) | Lookup total (ms) |
| ---: | ---: | ---: | ---: |
| 1,024 | 4.009 | 4.996 | 0.723 |
| 4,096 | 17.508 | 29.774 | 11.960 |
| 8,192 | 35.641 | 83.841 | 47.862 |

## Document-bounded index

The index stores sorted `(node index, document record)` pairs, one entry-chain
head per document record, and one next-entry index per component. A binary search
resolves a live entity to its document record; a lookup then scans only that
record's component chain. Binary and JSONC readers use the same index, including
reuse of previously decoded binary authoring during attachment.

One reader-owned acquisition holds `3 * record_count + component_count` uint
words, plus the existing acquisition header/alignment overhead. For 8,192 records
and one component each, index data is 128 KiB. Scene capacity does not enter the
allocation size. The regular tests compare identical two-record documents against
64-node and 4,096-node scene capacities and require equal allocated bytes. The
allocation-failure matrices cover the new acquisition in both readers.

The integer-key sort uses the standard library's fixed-scratch counting sort.
The private `read_node_record` helper provides the document-record lookup for
other serialization validation. No public callback or wire format changes.

## Local indexed measurements

These are the local indexed measurements; the independent confirmation follows.
They use the same host, inputs, warm-up and five alternating pairs as the baseline.
The measurement target remains outside the regular test suite.

| Nodes | Confirmed baseline lookup (ms) | Local indexed lookup (ms) | Local plain import (ms) | Local validated import (ms) |
| ---: | ---: | ---: | ---: | ---: |
| 1,024 | 0.723 | 0.035 | 3.914 | 3.977 |
| 4,096 | 11.960 | 0.141 | 17.233 | 17.151 |
| 8,192 | 47.862 | 0.293 | 34.631 | 35.278 |

| Nodes | Sample | Plain import (ms) | Validated import (ms) | Lookup total (ms) |
| ---: | ---: | ---: | ---: | ---: |
| 1,024 | 1 | 3.797 | 3.967 | 0.037 |
| 1,024 | 2 | 3.914 | 3.977 | 0.033 |
| 1,024 | 3 | 4.400 | 3.978 | 0.034 |
| 1,024 | 4 | 3.842 | 3.844 | 0.035 |
| 1,024 | 5 | 4.209 | 4.050 | 0.037 |
| 4,096 | 1 | 17.523 | 17.192 | 0.142 |
| 4,096 | 2 | 17.749 | 17.427 | 0.136 |
| 4,096 | 3 | 17.233 | 17.015 | 0.141 |
| 4,096 | 4 | 16.912 | 17.002 | 0.142 |
| 4,096 | 5 | 17.034 | 17.151 | 0.139 |
| 8,192 | 1 | 34.543 | 35.726 | 0.306 |
| 8,192 | 2 | 34.327 | 34.420 | 0.302 |
| 8,192 | 3 | 34.631 | 35.278 | 0.293 |
| 8,192 | 4 | 35.072 | 35.127 | 0.293 |
| 8,192 | 5 | 37.841 | 36.004 | 0.289 |

The indexed lookup total grows about 8.4 times for eight times the records in
this workload, compared with about 66 times for the confirmed linear-scan baseline.
Timer overhead is included, and these measurements establish no application budget.

## Independently confirmed indexed costs

The reviewer reproduced the indexed table at `38c4a4af` in the
[index review](https://github.com/fesoliveira014/c3d.c3l/pull/290), with the same
host, O3 target and five measured pairs:

| Nodes | Plain import (ms) | Validated import (ms) | Lookup total (ms) | Baseline lookup (ms) |
| ---: | ---: | ---: | ---: | ---: |
| 1,024 | 4.560 | 4.008 | 0.035 | 0.723 |
| 4,096 | 17.683 | 17.818 | 0.143 | 11.960 |
| 8,192 | 35.147 | 35.460 | 0.300 | 47.862 |

The confirmed lookup total grows 8.6 times for eight times the nodes. Variation
between plain and validated import medians includes normal timing noise; there
is no timing threshold in the correctness suite.


## Export ownership lookup

The exporter builds model/crowd ownership once inside its existing per-Scene-node
projection allocation. Each entry identifies the current live model owner and
template slot, the matching mesh baseline slot, the crowd owner and the first
absent captured model owner at that address. The absent-owner rule is the lowest
owner entity index, independent of sparse-store iteration order. The last matching
mesh baseline slot preserves the existing projection order for stored templates
with multiple mesh slots on one node.

Live entity capture, skin-pointer checks, animated morph projection and selected
model/crowd ownership checks use this table. A removed node has cleared fields,
so the skin check indexes its retained storage address. An already-dead Entity
reference returns its existing fault; only then may a scan of captured identities
fill the exact model key and template index. This diagnostic scan never runs on
a successful export and creates no second index or allocation.

The binary/JSONC formats and owner restart rules are unchanged. The repeated
slot-reuse regression keeps two absent generations at one address, reverses owner
store order, and checks exact dead-entity and first-absent-skin diagnostics in both
formats. Existing source-immutability, omission and canonical-output checks remain.

The before measurements below are the reviewer's Windows/MSVC O3 medians of three
at example head `d8c29361679544f9293f7160f70a3f17f9b1cf2c`, from
[the example review](https://github.com/fesoliveira014/c3d.c3l/pull/300).
The indexed after measurements are the reviewer's medians of three at
`8bb3a092e871065b9e1ed1d326d992e6521bc597`, from
[the export-index review](https://github.com/fesoliveira014/c3d.c3l/pull/313).
Binary write grows 1.71x, 1.88x and 2.09x per doubling; at 256 models it is
9.3x faster than the baseline. No performance budget is implied.

| Models | Nodes | Before binary write (ms) | Before JSONC write (ms) | Indexed binary write (ms) | Indexed JSONC write (ms) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 32 | 906 | 1.23 | 6.32 | 0.68 | 5.34 |
| 64 | 1,802 | 3.30 | 12.04 | 1.15 | 9.39 |
| 128 | 3,594 | 11.55 | 27.12 | 2.17 | 17.31 |
| 256 | 7,178 | 42.41 | 73.42 | 4.54 | 33.49 |

Reproduce with `c3c build serialize --path examples -O3`, then run
`serialize --cpu-only --models=<count>` three times for each row. This measurement
stays outside the regular CI test targets; the untimed correctness regression
runs in `serial_described_test`.


## Component claim lookup

The [independent combined-scene measurement](https://github.com/fesoliveira014/c3d.c3l/issues/315#issuecomment-6042658293)
confirmed 105/1,050 claim searches for 1/10 fixture copies. Adjusted search costs
were approximately 0.0003/0.0530 ms, or 0.5%/10.7% of binary export; the smaller
case was at the timer floor. This met the agreed measurement gate for a per-node
claim chain.

Each existing `NodeProjection` now holds a one-based claim head. Each claim holds
a next index instead of a node index. Indices survive claim-list growth; zero is
the empty chain. Projection, omission and component writing search only that
node's claims. There is no new allocation or public API, and no wire-format or
ownership-policy change. The interleaved regression claims two component types
on each of 100 nodes, grows the backing list, and checks both encodings, repeated
omission, source immutability and canonical output. Existing conflict and fault
checks remain unchanged.

### Reproducible target

`serial_claims_bench` is a permanent CPU-only measurement executable outside
`build.py --test`. It reuses the combined fixture with all 37 authored and 13
transient policies. Source preparation and snapshot replication occur before
measurement; the destination uses normal owner preparation and physics/nav sync.
All sizes use 8,192 node slots, 512 geometry/material slots and 128 nav agents.
The earlier confirmed 1/10-copy probe used 64 agent slots; the larger fixed limit
allows the 100-copy case. No GPU device is created.

```powershell
c3c build serial_claims_bench --path addons/c3d_serial.c3l -O3
foreach ($copies in 1,10,100) {
    foreach ($run in 1,2,3) {
        & ./addons/c3d_serial.c3l/build/serial_claims_bench.exe "--copies=$copies" "--run=$run"
    }
}
```

CSV columns: copies, run, live nodes, live components, retained nodes, serialized
records, claims, bytes, preparation ms, collection ms, component-write ms, total
binary-export ms. The process first warms a canonical export. Preparation covers
selection, owner collection and final projection; collection is its measured
subset. Component time sums sizing and filling, excluding output allocation.
Those phases are timed directly through private helpers. A separate ordinary
`write_subtree` call measures the complete export and must equal the warm output;
the separately written component chunk must also match. There are no timers in
production export paths and no performance assertions in CI.

### Local before/after results

Windows/MSVC, i9-14900K, C3 0.8.3, `-O3`, 2026-10-07; medians of three fresh
processes per row. Both versions use the permanent target, identical capacities
and the same asset-key paths. The baseline uses the pre-chain `context.c3` from
`0f547a5`; all other measured code is identical. Thus these totals are distinct
from the earlier confirmed probe, which timed phases inside one export.

| Copies | Live nodes | Live components | Retained nodes | Records | Claims | Bytes |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 35 | 74 | 31 | 46 | 13 | 12,741 |
| 10 | 341 | 740 | 301 | 460 | 130 | 113,109 |
| 100 | 3,401 | 7,400 | 3,001 | 4,600 | 1,300 | 1,116,789 |

Asset keys contain checkout paths, so byte counts can differ across machines.

| Copies | Preparation before / after (ms) | Collection before / after (ms) | Component writes before / after (ms) | Binary export before / after (ms) |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 0.0092 / 0.0097 | 0.0020 / 0.0020 | 0.0469 / 0.0447 | 0.0757 / 0.0800 |
| 10 | 0.0337 / 0.0306 | 0.0133 / 0.0104 | 0.4141 / 0.3367 | 0.6262 / 0.4714 |
| 100 | 0.4471 / 0.2563 | 0.3143 / 0.1407 | 9.1391 / 3.6811 | 10.4506 / 4.6484 |

At 100 copies the local binary-export median is 2.25 times faster. Increasing
copies from 10 to 100 increases indexed export 9.86 times. The 1-copy totals are
noisy; no improvement is claimed there.

A separate instrumented executable times only the three claim-search loops.
Its totals are not used as the primary export measurement. Per-run estimates
subtract that run's measured empty clock-pair cost (17.1–20.7 ns) for every
search and clamp negative estimates to zero. The table divides median adjusted
search time by the corresponding uninstrumented export median.

| Copies | Search calls | Raw search before / after (ms) | Adjusted before / after (ms) | Estimated export share before / after |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 105 | 0.0023 / 0.0020 | 0.000428 / 0.000193 | 0.57% / 0.24% |
| 10 | 1,050 | 0.0723 / 0.0202 | 0.054045 / 0.002124 | 8.63% / 0.45% |
| 100 | 10,500 | 5.0792 / 0.2055 | 4.877401 / 0.017970 | 46.67% / 0.39% |

Indexed scan estimates are below 0.5% and close to clock overhead. They establish
no precise per-search cost or speedup at that scale. These are local results;
independent phase measurements follow.


### Independently confirmed claim-chain measurements

The [claim-chain review](https://github.com/fesoliveira014/c3d.c3l/pull/322#pullrequestreview-5445826352)
confirmed head `e6672b0e` using `serial_claims_bench` on the same Windows/MSVC,
i9-14900K machine, C3 0.8.3 O3 and three fresh processes per size. Every canonical
comparison passed. These are reviewer-reported medians in milliseconds.

| Copies | Nodes | Claims | Preparation | Collection | Component writes | Binary export |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 35 | 13 | 0.0081 | 0.0018 | 0.0440 | 0.0717 |
| 10 | 341 | 130 | 0.0341 | 0.0135 | 0.3374 | 0.4500 |
| 100 | 3,401 | 1,300 | 0.2712 | 0.1369 | 3.4804 | 4.3939 |

The independently confirmed 10-to-100-copy export increase is 9.76 times.
The reviewer also passed all 72 shared and both combined tests at default and
O3, plus the 23 legacy serialization tests. The search-overhead table above
remains local profiling evidence; these independently confirmed timings do not
claim a separately measured per-search cost.
