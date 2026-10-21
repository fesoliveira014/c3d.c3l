# InstancedMesh v3 inputs

Immutable streams from the InstancedMesh v3 codec, written before the box-range metric joined the authoring. The
serialization tests read them (`addons/c3d_serial.c3l/test_described/core_batches_test.c3`). `SHA256SUMS` records the
file bytes. The shared rules for compatibility sets are in [the fixtures README](../README.md#rules).

| File | Bytes |
| --- | ---: |
| `instances-v3.bin` | 822 |
| `instances-v3.jsonc` | 4398 |

The owner is the root node `quadtree_instances` at `(3, -1, 5)` on layers 5. Its batch has capacity six and five live
instances. Instance `i` sits at `(i, 0, -i)` with tint `(0.1(i + 1), 0.2, 0.3, 1)`. Shadow casting and `trace_sway` are
on; shadow receiving and trace are off. Fade runs from 10 to 20 and sway is unset. The quadtree has parents `{ROOT, 0,
0, 0, 0}`, `split_pixels` 96 and `hysteresis` 0.25.

The geometry key is `instances_v3/box` and the material key is `instances_v3/material`.
