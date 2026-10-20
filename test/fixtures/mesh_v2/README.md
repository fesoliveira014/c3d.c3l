# Mesh v2 compatibility inputs

These immutable inputs were emitted by the Mesh v2 codec at
`613e1f77db017d03ce27e51983716ba55116fa8f`, before `trace_facing` joined the
component. Compiler: C3 0.8.3, default safe options. The binary and JSONC
outputs were captured from the unmodified tree before the codec changed; two runs
wrote identical files. `SHA256SUMS` records the exact file bytes.

| Input | Bytes |
| --- | ---: |
| mesh-v2.bin | 306 |
| mesh-v2.jsonc | 1142 |

The owner is the root node `mesh` at `(1,2,3)` with layers 5. Its mesh has shadow
casting off, shadow receiving, trace and `trace_only` on, one morph weight `0.25`,
a bounds override from `(-1,-2,-3)` to `(3,2,1)` and `vertex_motion`.

Both use geometry key `mesh_v2/box` and material key `mesh_v2/material`.
The read tests preload those assets and embed the old files directly. They never
regenerate the inputs during a test.
