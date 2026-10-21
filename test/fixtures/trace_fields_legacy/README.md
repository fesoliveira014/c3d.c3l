# Trace field inputs

Immutable streams from the Mesh v1, InstancedMesh v1 and LodGroup v2 codecs, written before `trace_only` and
`trace_sway` existed. A reader restores both as off. The serialization tests read them
(`addons/c3d_serial.c3l/test_described/trace_fields_test.c3`). `SHA256SUMS` records the file bytes. The shared rules for
compatibility sets are in [the fixtures README](../README.md#rules).

| Files | Component | Payload version |
| --- | --- | ---: |
| `mesh-v1.bin`, `mesh-v1.jsonc` | Mesh | 1 |
| `instances-v1.bin`, `instances-v1.jsonc` | InstancedMesh | 1 |
| `lod-v2.bin`, `lod-v2.jsonc` | LodGroup | 2 |

- The mesh has shadow casting off, shadow receiving and trace on, one morph weight `0.25`, a bounds override and
  `vertex_motion`, at `(1, 2, 3)` on layer mask 5.
- The batch has capacity four with two live placements at `(1, 2, 3)` and `(4, 5, 6)`, shadow casting off, receiving and
  trace on, a bounds override, sway amplitude `0.5` and fade band 10 to 20, under a node at `(-2, 1, 0)`.
- The LOD group is instanced with capacity three and one placement, shadow casting and trace off and receiving on, the
  same sway and fade, under a node at `(0, 4, 0)`.

The geometry key is `trace_fields/box` and the material key is `trace_fields/material`.
