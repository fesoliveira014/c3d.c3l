# Native image decoder

`stb_image.h` is the unmodified stb_image v2.30 header from
[nothings/stb revision 013ac3beddff3dbffafd5177e7972067cd2b5083](https://github.com/nothings/stb/blob/013ac3beddff3dbffafd5177e7972067cd2b5083/stb_image.h).
Its SHA-256 is `594c2fe35d49488b4382dbfaec8f98366defca819d916ac95becf3e75f4200b3`.
The full upstream dual-license notice remains in the header; c3d uses its MIT option.

`stb_image.c` enables only PNG, JPEG and Radiance HDR decoding from memory.
The C3 package manifest compiles this translation unit using c3c's selected C
compiler. A working C compiler is required. The current package includes the
translation unit even when the `C3D_STB_IMAGE` feature indicator is absent.

The private declarations in `c3d::asset::image` are the only C3 entry points.
Decoded native memory is copied into the requested C3 allocator and freed with
`stbi_image_free`. File reads use a separately freed heap allocation so the
caller's temporary allocator retains its normal lifetime.

# Test fixtures

`test/fixtures/rgba.png` is a 2×2 RGBA image, in top-row-first order:
red `(255, 0, 0, 255)`, green `(0, 255, 0, 128)`, blue `(0, 0, 255, 64)`,
and white `(255, 255, 255, 0)`.
`test/fixtures/radiance.hdr` is a 2×1 RGBE image representing
`(2, 1, 0.5)` and `(0.25, 0.5, 1)`.
`test/fixtures/truncated.png` is the first twelve bytes of `rgba.png`,
an intentionally malformed input for file-loader fault coverage.
Both were generated with Python's standard library:

```python
from pathlib import Path
import struct
import zlib

fixtures = Path("test/fixtures")

def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

pixels = bytes([
    255, 0, 0, 255, 0, 255, 0, 128,
    0, 0, 255, 64, 255, 255, 255, 0,
])
(fixtures / "rgba.png").write_bytes(
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 6, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(b"\0" + pixels[:8] + b"\0" + pixels[8:]))
    + chunk(b"IEND", b""))
(fixtures / "radiance.hdr").write_bytes(
    b"#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 2\n"
    + bytes([128, 64, 32, 130, 32, 64, 128, 129]))
```

`test/fixtures/gray.jpg` contains two grayscale pixels with value 128. It was
created once with ImageMagick 6 using:

```bash
convert -size 2x1 xc:'gray(50%)' -colorspace Gray -quality 100 test/fixtures/gray.jpg
```

These are committed test inputs; neither Python fixture generation nor
ImageMagick runs during builds or tests.

# Cube and compressed fixtures

`examples/assets/cube/` contains 256×256 RGBA faces named `positive_x.png`,
`negative_x.png`, `positive_y.png`, `negative_y.png`, `positive_z.png` and
`negative_z.png`. Their base colors are red, green, blue, yellow, magenta and
cyan in that order. Each face has an opaque white 8×8 marker where both
coordinates are in `[16, 24)` and an opaque black marker in `[232, 240)`.
They use the same zero-filter PNG writer above. The example's supplied 4×4 base
faces use those six colors; each supplied 2×2 tail uses the next face's color,
wrapping from cyan to red.

`test/fixtures/cube/face0.png` through `face5.png` are 2×2 RGBA images. Each
face's four pixels are `(face*40, 20, 255-face*40, 255)`, where face is zero-based
in +X, −X, +Y, −Y, +Z, −Z order. `rect.png` is 2×1 opaque red and `large.png`
is 3×3 opaque red, for square/equal-dimension rejection. All use the PNG chunk
writer above with a zero filter byte at each row start.

The six matching Radiance files use:

```python
header = b"#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 2\n"
for face in range(6):
    payload = bytes([32 * (face + 1), 64, 32, 130]) * 4
    (fixtures / f"face{face}.hdr").write_bytes(header + payload)
```

Here `fixtures` is `Path("test/fixtures/cube")`; decoded red is
`(face + 1) * 0.5`. The mixed PNG/JPEG test uses a 2×2 gray image generated once
with ImageMagick 6:

```bash
convert -size 2x2 xc:'gray(50%)' -colorspace Gray -quality 100 test/fixtures/cube/gray.jpg
```

`examples/assets/bc1_mips.bin` is an exact 2744-byte BC1_RGBA_SRGB chain for
64×64 through 1×1. Every block in one level selects its repeated RGB565 endpoint:

```python
from pathlib import Path
import struct

sizes = [2048, 512, 128, 32, 8, 8, 8]
colors = [0xf800, 0x07e0, 0x001f, 0xffe0, 0xf81f, 0x07ff, 0xffff]
payload = b"".join(
    struct.pack("<HHI", color, color, 0) * (size // 8)
    for size, color in zip(sizes, colors)
)
Path("examples/assets/bc1_mips.bin").write_bytes(payload)
```

Levels are red, green, blue, yellow, magenta, cyan and white at offsets
0, 2048, 2560, 2688, 2720, 2728 and 2736. The 2×2 and 1×1 tails still contain
one full eight-byte block. These commands describe one-time fixture authoring;
no compressor, transcoder or image encoder runs during the build.
