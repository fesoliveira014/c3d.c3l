# InstancedMesh v2 compatibility inputs

These immutable inputs were emitted by the InstancedMesh v2 codec at
`f055af03f2488186bd080cfdc0632dd83f53cee3`, before `trace_sway` joined the
authoring. Two runs wrote identical binary files. `SHA256SUMS` records the exact
file bytes.

| Input | Bytes |
| --- | ---: |
| instances-v2.bin | 821 |
| instances-v2.jsonc | 4366 |

The owner is the root node `quadtree_instances` at `(3,-1,5)` with layers 5. Its
batch has capacity six and five live instances. Instance `i` sits at
`(i,0,-i)` with tint `(0.1(i+1),0.2,0.3,1)`. Shadow casting is on; shadow
receiving and trace are off. Fade runs from 10 to 20 and sway is unset. The
quadtree has parents `{ROOT,0,0,0,0}`, `split_pixels` 96 and `hysteresis` 0.25.

Both use geometry key `instances_v2/box` and material key `instances_v2/material`.
The read tests preload those assets and embed the old files directly. They never
regenerate the inputs during a test.
