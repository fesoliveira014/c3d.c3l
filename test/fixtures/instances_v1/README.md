# InstancedMesh v1 inputs

Immutable streams from the InstancedMesh v1 codec. The serialization tests read them
(`addons/c3d_serial.c3l/test_described/core_batches_test.c3`). `SHA256SUMS` records the file bytes. The shared rules for
compatibility sets are in [the fixtures README](../README.md#rules).

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `instances-v1.bin` | 783 | `20a60e80fee62c057856efa58548eb9f7a150039ec8dbcf830e70f8a9249caa6` |
| `instances-v1.jsonc` | 4158 | `b19fbb1bedf70bbf103f1d00ff693422c74548e71d2051b1ce1f47f9e45e1f97` |

The owner is the root node `legacy_instances` at `(3, -1, 5)` on layers 5. Its batch has capacity six and five live
instances. Instance `i` sits at `(i, 0, -i)` with tint `(0.1(i + 1), 0.2, 0.3, 1)`. Shadow casting is on; shadow
receiving and trace are off. Fade runs from 10 to 20 and sway is unset.

The source batch carried a quadtree (parents `{ROOT, 0, 0, 0, 0}`, split 96, hysteresis 0.25) when it was written.
Version 1 has no field for it, so neither stream mentions it, and a reader restores the batch without one.

The geometry key is `instances_v1/box` and the material key is `instances_v1/material`.
