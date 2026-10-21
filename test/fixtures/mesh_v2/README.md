# Mesh v2 inputs

Immutable streams from the Mesh v2 codec, written before `trace_facing` joined the component. The serialization tests
read them (`addons/c3d_serial.c3l/test_described/trace_fields_test.c3`). `SHA256SUMS` records the file bytes. The shared
rules for compatibility sets are in [the fixtures README](../README.md#rules).

| File | Bytes |
| --- | ---: |
| `mesh-v2.bin` | 306 |
| `mesh-v2.jsonc` | 1142 |

The owner is the root node `mesh` at `(1, 2, 3)` on layers 5. Its mesh has shadow casting off, shadow receiving, trace
and `trace_only` on, one morph weight `0.25`, a bounds override from `(-1, -2, -3)` to `(3, 2, 1)` and `vertex_motion`.

The geometry key is `mesh_v2/box` and the material key is `mesh_v2/material`.
