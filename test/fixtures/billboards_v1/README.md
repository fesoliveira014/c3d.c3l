# BillboardBatch v1 compatibility inputs

These immutable inputs were emitted by the BillboardBatch v1 codec at
`98643f93`, before the sprite-sheet atlas and the per-record frame joined the
authoring. The serial sources were the ones on that commit. Two runs wrote
identical binary and text files. `SHA256SUMS` records the exact file bytes.

| Input | Bytes |
| --- | ---: |
| billboards-v1.bin | 480 |
| billboards-v1.jsonc | 2335 |

The owner is the root node `billboard_cards` at `(3,-1,5)` with layers 5. Its
batch has capacity four, `DIRECTIONAL` facing and three live billboards. Billboard
`i` sits at `(i,0.5i,-i)` with size `(1+0.5i,2)`, rotation `0.25i`, tint
`(0.1(i+1),0.2,0.3,1)`, and direction `(1,0,0)` for `i = 1` and `(0,1,0)` otherwise.

Both use material key `billboards_v1/material`. The read tests preload that
asset and embed the old files directly. They never regenerate the inputs during
a test.
