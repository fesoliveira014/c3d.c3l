# InstancedMesh v3 compatibility inputs

These immutable inputs were emitted by the InstancedMesh v3 codec at
`9e38d26a`, before the box-range metric joined the authoring. The serial sources
were the ones on that commit. Two runs wrote identical binary files. `SHA256SUMS`
records the exact file bytes.

| Input | Bytes |
| --- | ---: |
| instances-v3.bin | 822 |
| instances-v3.jsonc | 4398 |

The owner is the root node `quadtree_instances` at `(3,-1,5)` with layers 5. Its
batch has capacity six and five live instances. Instance `i` sits at
`(i,0,-i)` with tint `(0.1(i+1),0.2,0.3,1)`. Shadow casting and `trace_sway` are
on; shadow receiving and trace are off. Fade runs from 10 to 20 and sway is unset.
The quadtree has parents `{ROOT,0,0,0,0}`, `split_pixels` 96 and `hysteresis` 0.25.

Both use geometry key `instances_v3/box` and material key `instances_v3/material`.
The read tests preload those assets and embed the old files directly. They never
regenerate the inputs during a test.
