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
No index implementation is included in this evidence slice.

## Independently confirmed baseline

Reviewer run on the same i9-14900K at `113f30d`, C3 0.8.3 and `-O3`, using five
pairs after warm-up. These are the reviewer-reported medians:

| Nodes | Plain import (ms) | Validated import (ms) | Lookup total (ms) |
| ---: | ---: | ---: | ---: |
| 1,024 | 4.009 | 4.996 | 0.723 |
| 4,096 | 17.508 | 29.774 | 11.960 |
| 8,192 | 35.641 | 83.841 | 47.862 |
