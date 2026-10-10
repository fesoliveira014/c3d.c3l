# LodGroup v1 compatibility inputs

These immutable inputs were emitted by the actual LodGroup v1 codec at
`387d69dabc6fd023a13d8182a678d1231ec34dc1`. Compiler: C3 0.8.3, default safe
options. Binary and JSONC outputs were captured without modifying the historical
writer or its codec registration. `SHA256SUMS` records the exact file bytes.

| Input | Bytes | SHA256 |
| --- | ---: | --- |
| lod-v1-instanced.bin | 823 | faa4af049cffe14655069ad943a48aef88ba4d9653e97ebc4f22bb73cfc3ac5c |
| lod-v1-instanced.jsonc | 4022 | 39e63fdaa1a5a6ec06b9fcfbd625279b763c29243671d4ebc506659c1527dcb6 |
| lod-v1-impostor.bin | 766 | bd00034a4dd764b17cbb9f7e6e0967ccc8dd853dbfbc0502279383d7397b594c |
| lod-v1-impostor.jsonc | 3493 | 5b1104ccef0098497fc39e3c0ef1558957e68fa544ddd7cf2b14ce49486cb7b0 |

The fixture producer must run against the unchanged historical checkout at
`387d69dabc6fd023a13d8182a678d1231ec34dc1`, with its dependency pins and C3 0.8.3
default safe options. It checks that the registered LodGroup codec is version 1.
It uses the real binary and JSONC subtree writers without changing registrations.

The instanced owner has capacity five and one placement at `(1,2,3)`, tint
`(0.1,0.2,0.3,1)`, an affine part with shear `m01=0.125` and translation `m03=2`,
two mesh levels, owner translation `(4,2,-8)` and layers 9. Shadow casting is off;
shadow receiving and trace are on.

The single owner uses the same mesh alternatives and an impostor atlas, two
frames per side, four-pixel cells, a radius-four sphere, threshold 0.1 and owner
translation `(-4,1,6)`. Shadow casting is on; receiving and trace are off.

Both use geometry key `lod_v1/box` and material key `lod_v1/material`. The impostor
uses texture key `lod_v1/atlas`: RGBA8, width 8, height 16, one layer, one mip and
512 bytes of 255. The current read tests preload those assets and embed the old
files directly. They never regenerate the oracle during a test.

Copy `producer.c3` and `project.json` to `test/lod_v1_freeze/` in that historical
checkout. The project stays outside the root test sequence. Initialize that
checkout's submodules and pin-matched native artifacts, then run:

```text
c3c build lod_v1_freeze --path C:/tmp/c3d-lod-v1-freeze/test/lod_v1_freeze
C:/tmp/c3d-lod-v1-freeze/test/lod_v1_freeze/build/lod_v1_freeze.exe C:/tmp/c3d-issue-351-lod/test/fixtures/lod_v1
```

The producer prints each output's SHA256 and byte count. The four immutable
outputs are `lod-v1-instanced.bin`, `lod-v1-instanced.jsonc`,
`lod-v1-impostor.bin` and `lod-v1-impostor.jsonc`.
