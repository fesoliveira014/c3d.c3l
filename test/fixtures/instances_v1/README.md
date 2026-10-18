# InstancedMesh v1 compatibility inputs

These immutable inputs were emitted by the actual InstancedMesh v1 codec at
`286066ab0290069a470a5e12748d61af14f9b835`. Compiler: C3 0.8.3, default safe
options. Binary and JSONC outputs were captured from the unmodified tree before
the codec changed; two runs wrote identical binary files. `SHA256SUMS` records
the exact file bytes.

| Input | Bytes | SHA256 |
| --- | ---: | --- |
| instances-v1.bin | 783 | 20a60e80fee62c057856efa58548eb9f7a150039ec8dbcf830e70f8a9249caa6 |
| instances-v1.jsonc | 4158 | b19fbb1bedf70bbf103f1d00ff693422c74548e71d2051b1ce1f47f9e45e1f97 |

The owner is the root node `legacy_instances` at `(3,-1,5)` with layers 5. Its
batch has capacity six and five live instances. Instance `i` sits at
`(i,0,-i)` with tint `(0.1(i+1),0.2,0.3,1)`. Shadow casting is on; shadow
receiving and trace are off. Fade runs from 10 to 20 and sway is unset.

The source batch carried a quadtree (parents `{ROOT,0,0,0,0}`, split 96,
hysteresis 0.25) when it was written. Version 1 has no field for it, so neither
payload mentions it, and a reader must restore the batch without one.

Both use geometry key `instances_v1/box` and material key `instances_v1/material`.
The read tests preload those assets and embed the old files directly. They never
regenerate the oracle during a test.
