# BillboardBatch v1 inputs

Immutable streams from the BillboardBatch v1 codec, written before the sprite-sheet atlas and the per-record frame
joined the authoring. The serialization tests read them (`addons/c3d_serial.c3l/test_described/core_batches_test.c3`).
The shared rules for compatibility sets are in [the fixtures README](../README.md#rules).

| File | Bytes |
| --- | ---: |
| `billboards-v1.bin` | 480 |
| `billboards-v1.jsonc` | 2335 |

`SHA256SUMS` records the file bytes. The owner is the root node `billboard_cards` at `(3, -1, 5)` on layers 5. Its batch
has capacity four, `DIRECTIONAL` facing and three live billboards. Billboard `i` sits at `(i, 0.5i, -i)` with size `(1 +
0.5i, 2)`, rotation `0.25i`, tint `(0.1(i + 1), 0.2, 0.3, 1)` and direction `(1, 0, 0)` for `i = 1`, `(0, 1, 0)`
otherwise. The material key is `billboards_v1/material`.
