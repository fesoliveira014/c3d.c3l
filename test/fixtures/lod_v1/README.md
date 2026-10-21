# LodGroup v1 inputs

Immutable streams from the LodGroup v1 codec. The serialization tests read them
(`addons/c3d_serial.c3l/test_described/animated_lod_codec_test.c3`). `SHA256SUMS` records the file bytes. The shared
rules for compatibility sets are in [the fixtures README](../README.md#rules).

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `lod-v1-instanced.bin` | 823 | `faa4af049cffe14655069ad943a48aef88ba4d9653e97ebc4f22bb73cfc3ac5c` |
| `lod-v1-instanced.jsonc` | 4022 | `39e63fdaa1a5a6ec06b9fcfbd625279b763c29243671d4ebc506659c1527dcb6` |
| `lod-v1-impostor.bin` | 766 | `bd00034a4dd764b17cbb9f7e6e0967ccc8dd853dbfbc0502279383d7397b594c` |
| `lod-v1-impostor.jsonc` | 3493 | `5b1104ccef0098497fc39e3c0ef1558957e68fa544ddd7cf2b14ce49486cb7b0` |

- The instanced owner has capacity five and one placement at `(1, 2, 3)` with tint `(0.1, 0.2, 0.3, 1)` and an affine
  part with shear `m01 = 0.125` and translation `m03 = 2`. It has two mesh levels, owner translation `(4, 2, -8)` and
  layers 9. Shadow casting is off; shadow receiving and trace are on.
- The impostor owner uses the same mesh alternatives and an impostor atlas: two frames per side, four-pixel cells, a
  radius-four sphere, threshold 0.1 and owner translation `(-4, 1, 6)`. Shadow casting is on; receiving and trace are
  off.

The geometry key is `lod_v1/box` and the material key is `lod_v1/material`. The impostor uses texture key
`lod_v1/atlas`: RGBA8, width 8, height 16, one layer, one mip and 512 bytes of 255.
