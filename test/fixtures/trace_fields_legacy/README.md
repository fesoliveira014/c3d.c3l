# Trace field compatibility inputs

These immutable inputs were emitted by the Mesh version 1, InstancedMesh
version 1 and LodGroup version 2 codecs at commit
`9b7843c639250252efd851fbbf88e59b4aa48581`. `SHA256SUMS` records the exact file bytes.

| Input | Component | Payload version |
| --- | --- | ---: |
| mesh-v1.bin, mesh-v1.jsonc | Mesh | 1 |
| instances-v1.bin, instances-v1.jsonc | InstancedMesh | 1 |
| lod-v2.bin, lod-v2.jsonc | LodGroup | 2 |

The mesh has shadow casting off, shadow receiving and trace on, one morph weight
`0.25`, a bounds override and `vertex_motion`, at position `(1,2,3)` on layer mask 5.

The batch has capacity four with two live placements at `(1,2,3)` and `(4,5,6)`,
shadow casting off, receiving and trace on, a bounds override, sway amplitude `0.5`
and fade band 10 to 20, under a node at `(-2,1,0)`.

The LOD group is instanced with capacity three and one placement, shadow casting
and trace off, receiving on, the same sway and fade, under a node at `(0,4,0)`.

All use geometry key `trace_fields/box` and material key `trace_fields/material`.
The read tests preload those assets and embed the old files directly. They never
regenerate the inputs during a test.
