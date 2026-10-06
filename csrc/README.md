# Native image decoder

`stb_image.h` is the unmodified stb_image v2.30 header from
[nothings/stb revision 013ac3beddff3dbffafd5177e7972067cd2b5083](https://github.com/nothings/stb/blob/013ac3beddff3dbffafd5177e7972067cd2b5083/stb_image.h).
Its SHA-256 is `594c2fe35d49488b4382dbfaec8f98366defca819d916ac95becf3e75f4200b3`.
The full upstream dual-license notice remains in the header; c3d uses its MIT option.

`stb_image.c` enables only PNG, JPEG and Radiance HDR decoding from memory.
The C3 package manifest compiles this translation unit using c3c's selected C
compiler. A working C compiler is required.

The private declarations in `c3d::asset::image` are the only C3 entry points.
Decoded native memory is copied into the requested C3 allocator and freed with
`stbi_image_free`. File reads use a separately freed heap allocation so the
caller's temporary allocator retains its normal lifetime.

# Native font parser

`stb_truetype.h` is the unmodified stb_truetype v1.26 header from
[nothings/stb revision 013ac3beddff3dbffafd5177e7972067cd2b5083](https://github.com/nothings/stb/blob/013ac3beddff3dbffafd5177e7972067cd2b5083/stb_truetype.h),
the stb_image revision. Its SHA-256 is `a34d8d536ce7c11b9163ab2d524721c1f4df1452cce6595c4f11d3048384f925`.
The full upstream dual-license notice remains in the header; c3d uses its MIT option.

`stb_truetype.c` compiles the implementation with C linkage. Dear ImGui carries its own copy with internal
linkage in both prebuilt libraries, so the `stbtt_` symbols do not clash. The private declarations in
`c3d::asset::truetype` are the only C3 entry points; they mirror `stbtt_fontinfo` (160 bytes) and `stbtt_vertex`
(14 bytes) with layout pins. Shapes and bitmaps are allocated and freed by stb_truetype's default `malloc`.
`c3d::asset` validates the sfnt table directory before stb_truetype reads a file, because stb_truetype does not
bounds-check.

Font fixtures are described in `test/fixtures/fonts/README.md`.

# Test fixtures

`test/fixtures/rgba.png` is a 2×2 RGBA image, in top-row-first order:
red `(255, 0, 0, 255)`, green `(0, 255, 0, 128)`, blue `(0, 0, 255, 64)`,
and white `(255, 255, 255, 0)`.
`test/fixtures/radiance.hdr` is a 2×1 RGBE image representing
`(2, 1, 0.5)` and `(0.25, 0.5, 1)`.
`test/fixtures/truncated.png` is the first twelve bytes of `rgba.png`,
an intentionally malformed input for file-loader fault coverage.
`test/fixtures/gray16.png` is a 2×2 16-bit grayscale image holding
`0, 1, 0x1234, 0xFFFF`, top row first; 1 and `0x1234` are not multiples of
257, so an 8-bit decode cannot produce them.
They were generated with Python's standard library:

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
rows = [struct.pack(">HH", 0, 1), struct.pack(">HH", 0x1234, 0xFFFF)]
(fixtures / "gray16.png").write_bytes(
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 16, 0, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(b"".join(b"\0" + row for row in rows)))
    + chunk(b"IEND", b""))
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

`examples/assets/bc1_mips.dds` holds the same 2744 bytes behind a DX10 header (`BC1_UNORM_SRGB`, 64×64, 7 levels);
the container fixture script below writes it.

# Texture container fixtures

`test/fixtures/texture/` holds DDS, KTX 1.1 and KTX 2.0 files for the container tests. Files directly in that
directory are project-authored and were written once by the script below; no generator runs during builds or tests.
Level bytes come from `payload(seed, length)`, BC1 blocks keep `color0 > color1` unless a file is named otherwise, and
`R16_UINT` texels hold `1000 * mip + index` in row-major order. `ktx1_level_capacity.ktx` and
`ktx2_level_capacity.ktx2` are malformed on purpose: they claim 33 levels. `orientation_4x4.*` holds the same three
RGBA8 levels in each container, with a red, green and blue marker at texel 0 of levels 0, 1 and 2.
`examples/assets/bc1_mips.dds` wraps `bc1_mips.bin` in a DX10 header (DXGI 72). Each project-authored file stays
within 3 KB; they total 7,852 bytes: 4,960 under `test/fixtures/texture/` and 2,892 for the example. The script's
data format descriptors are byte-identical to `ktx create` and `ktx transcode` v4.3.1 output in KTX2-Samples
`471931bbe05c5a5443da3ea7be37f44680664ac6` (`2d_rgba8`, `2d_rgba8_linear`, `2d_bc7`, `2d_bc5`); the BC1_RGB
descriptor matches `2d_bc1` except the transfer byte, linear for vkFormat 131 and sRGB for 132. Run the script from
the repository root:

```python
from pathlib import Path
import struct

fixtures = Path("test/fixtures/texture")
fixtures.mkdir(parents=True, exist_ok=True)


def payload(seed, length):
    return bytes((seed + 7 * k) & 0xFF for k in range(length))


def clean_bc1(seed, blocks):
    # color0 > color1 selects four-color blocks, which BC1 RGB and RGBA decode alike
    return b"".join(struct.pack("<HHI", 0xFFFF - seed - b, seed + b, 0xE4E4E4E4) for b in range(blocks))


def rgba16f_texels(count):
    return b"".join(struct.pack("<4e", *(((t + c) % 16) / 16 for c in range(4))) for t in range(count))


def r16_image(mip, width, height):
    rows = []
    for y in range(height):
        row = b"".join(struct.pack("<H", 1000 * mip + y * width + x) for x in range(width))
        rows.append(row + b"\0" * (-len(row) % 4))
    return b"".join(rows)


def orientation_level(mip):
    size = 4 >> mip
    markers = [(255, 0, 0, 255), (0, 255, 0, 255), (0, 0, 255, 255)]
    texels = []
    for y in range(size):
        for x in range(size):
            if x == 0 and y == 0:
                texels.append(markers[mip])
            else:
                texels.append((16 + 48 * x, 16 + 48 * y, 64 * mip + 32, 255))
    return bytes(channel for texel in texels for channel in texel)


ORIENTATION_LEVELS = [orientation_level(mip) for mip in range(3)]


# DDS: magic, DDS_HEADER (124 bytes), optional DDS_HEADER_DXT10 (20 bytes), levels largest first.
def dds_pixel_format(flags, four_cc=b"\0\0\0\0", bits=0, masks=(0, 0, 0, 0)):
    return struct.pack("<II4sI4I", 32, flags, four_cc, bits, *masks)


def dds(path, width, height, levels, pixel_format, dxgi_format=None, compressed=True):
    flags = 0x1 | 0x2 | 0x4 | 0x1000 | 0x20000 | (0x80000 if compressed else 0x8)
    pitch = len(levels[0]) if compressed else len(levels[0]) // height
    caps = 0x1000 | (0x400008 if len(levels) > 1 else 0)
    header = (b"DDS " + struct.pack("<7I", 124, flags, height, width, pitch, 0, len(levels)) + b"\0" * 44
              + pixel_format + struct.pack("<5I", caps, 0, 0, 0, 0))
    if dxgi_format is not None:
        header += struct.pack("<5I", dxgi_format, 3, 0, 1, 0)
    path.write_bytes(header + b"".join(levels))


DX10 = dds_pixel_format(0x4, b"DX10")
dds(fixtures / "dx10_rgba8_srgb_5x3.dds", 5, 3, [payload(0x10, 60), payload(0x20, 8), payload(0x30, 4)],
    DX10, 29, False)
dds(fixtures / "dx10_bc7_srgb_5x3.dds", 5, 3, [payload(0x40, 32), payload(0x50, 16), payload(0x60, 16)], DX10, 99)
dds(fixtures / "dx10_format16.dds", 2, 2, [clean_bc1(9, 2)], DX10, 28, False)
dds(fixtures / "orientation_4x4.dds", 4, 4, ORIENTATION_LEVELS, DX10, 28, False)
dds(fixtures / "legacy_dxt1_6x6.dds", 6, 6, [clean_bc1(1, 4), clean_bc1(5, 1), clean_bc1(6, 1)],
    dds_pixel_format(0x4, b"DXT1"))
dds(fixtures / "legacy_rgba16f_4x4.dds", 4, 4, [rgba16f_texels(16)],
    dds_pixel_format(0x4, struct.pack("<I", 113)), compressed=False)
dds(fixtures / "legacy_rgba8_2x2.dds", 2, 2, [payload(0x70, 16), payload(0x80, 4)],
    dds_pixel_format(0x41, bits=32, masks=(0xFF, 0xFF00, 0xFF0000, 0xFF000000)), compressed=False)


# KTX 1.1, little-endian: identifier, 13 header words, key/value data, then imageSize and image per level.
def key_values(entries):
    data = b""
    for key, value in entries:
        entry = key.encode() + b"\0" + value.encode() + b"\0"
        data += struct.pack("<I", len(entry)) + entry + b"\0" * (-len(entry) % 4)
    return data


def ktx1(path, gl_type, type_size, gl_format, internal, base, width, height, mip_count, images, entries=()):
    kv = key_values(entries)
    header = (b"\xabKTX 11\xbb\r\n\x1a\n"
              + struct.pack("<13I", 0x04030201, gl_type, type_size, gl_format, internal, base, width, height,
                            0, 0, 1, mip_count, len(kv)))
    body = b"".join(struct.pack("<I", len(image)) + image + b"\0" * (-len(image) % 4) for image in images)
    path.write_bytes(header + kv + body)


RGBA8_GL = (0x1401, 1, 0x1908, 0x8058, 0x1908)
ktx1(fixtures / "ktx1_r16_5x3.ktx", 0x1403, 2, 0x8D94, 0x8234, 0x1903, 5, 3, 3,
     [r16_image(0, 5, 3), r16_image(1, 2, 1), r16_image(2, 1, 1)])
ktx1(fixtures / "ktx1_bc1_srgb_8x8.ktx", 0, 1, 0, 0x8C4D, 0x1908, 8, 8, 4,
     [clean_bc1(11, 4), clean_bc1(15, 1), clean_bc1(16, 1), clean_bc1(17, 1)],
     [("KTXorientation", "S=r,T=d"), ("KTXswizzle", "rgba")])
ktx1(fixtures / "ktx1_rgba8_generate_2x2.ktx", *RGBA8_GL, 2, 2, 0, [payload(0x90, 16)])
ktx1(fixtures / "ktx1_format16.ktx", *RGBA8_GL, 2, 2, 1, [clean_bc1(9, 2)])
ktx1(fixtures / "orientation_4x4.ktx", *RGBA8_GL, 4, 4, 3, ORIENTATION_LEVELS,
     [("KTXorientation", "S=r,T=d")])
# Malformed on purpose: 33 empty levels on the largest extent; only the level-count rule rejects them.
ktx1(fixtures / "ktx1_level_capacity.ktx", *RGBA8_GL, 0xFFFFFFFF, 0xFFFFFFFF, 33, [b""] * 33)


# KTX 2.0, supercompression 0: header, level index, data format descriptor, key/value data, then levels
# smallest first, each aligned to lcm(texel block bytes, 4).
def dfd(model, transfer, block_extent, plane_bytes, samples):
    block_size = 24 + 16 * len(samples)
    words = struct.pack("<II4B4B8B", 0, 2 | block_size << 16, model, 1, transfer, 0,
                        block_extent - 1, block_extent - 1, 0, 0, plane_bytes, 0, 0, 0, 0, 0, 0, 0)
    for bit_offset, bit_length, channel, upper in samples:
        words += struct.pack("<HBBIII", bit_offset, bit_length - 1, channel, 0, 0, upper)
    return struct.pack("<I", 4 + len(words)) + words


def rgba8_dfd(srgb):
    alpha = 15 | (0x10 if srgb else 0)
    return dfd(1, 2 if srgb else 1, 1, 4, [(0, 8, 0, 255), (8, 8, 1, 255), (16, 8, 2, 255), (24, 8, alpha, 255)])


BC7_SRGB_DFD = dfd(134, 2, 4, 16, [(0, 128, 0, 0xFFFFFFFF)])
BC5_DFD = dfd(132, 1, 4, 16, [(0, 64, 0, 0xFFFFFFFF), (64, 64, 1, 0xFFFFFFFF)])
BC1_RGB_DFD = dfd(128, 1, 4, 8, [(0, 64, 0, 0xFFFFFFFF)])


def ktx2(path, vk_format, type_size, width, height, levels, descriptor, alignment, entries=()):
    kv = key_values(entries)
    dfd_offset = 80 + 24 * len(levels)
    kv_offset = dfd_offset + len(descriptor) if kv else 0
    position = dfd_offset + len(descriptor) + len(kv)
    offsets = [0] * len(levels)
    data = b""
    for mip in reversed(range(len(levels))):
        padding = -position % alignment
        data += b"\0" * padding + levels[mip]
        offsets[mip] = position + padding
        position = offsets[mip] + len(levels[mip])
    header = (b"\xabKTX 20\xbb\r\n\x1a\n"
              + struct.pack("<9I", vk_format, type_size, width, height, 0, 0, 1, len(levels), 0)
              + struct.pack("<4I", dfd_offset, len(descriptor), kv_offset, len(kv)) + struct.pack("<2Q", 0, 0))
    index = b"".join(struct.pack("<3Q", offsets[mip], len(level), len(level)) for mip, level in enumerate(levels))
    path.write_bytes(header + index + descriptor + kv + data)


ktx2(fixtures / "ktx2_rgba8_srgb_5x3.ktx2", 43, 1, 5, 3,
     [payload(0x10, 60), payload(0x20, 8), payload(0x30, 4)], rgba8_dfd(True), 4)
ktx2(fixtures / "ktx2_bc7_srgb_5x3.ktx2", 146, 1, 5, 3,
     [payload(0x40, 32), payload(0x50, 16), payload(0x60, 16)], BC7_SRGB_DFD, 16,
     [("KTXorientation", "rd"), ("KTXswizzle", "rgba")])
ktx2(fixtures / "ktx2_bc5_8x4.ktx2", 141, 1, 8, 4, [payload(0xA0, 32), payload(0xB0, 16)], BC5_DFD, 16)
ktx2(fixtures / "ktx2_bc1_rgb_clean_4x4.ktx2", 131, 1, 4, 4, [clean_bc1(21, 1)], BC1_RGB_DFD, 8)
# color0 <= color1 is a three-color block; texel 3 selects index 3, transparent in BC1_RGBA
ktx2(fixtures / "ktx2_bc1_rgb_punch_4x4.ktx2", 131, 1, 4, 4,
     [struct.pack("<HHI", 0x001F, 0xF800, 0x000000C0)], BC1_RGB_DFD, 8)
ktx2(fixtures / "ktx2_format16.ktx2", 37, 1, 2, 2, [clean_bc1(9, 2)], rgba8_dfd(False), 16)
ktx2(fixtures / "orientation_4x4.ktx2", 37, 1, 4, 4, ORIENTATION_LEVELS, rgba8_dfd(False), 4)
ktx2(fixtures / "ktx2_level_capacity.ktx2", 37, 1, 0xFFFFFFFF, 0xFFFFFFFF, [b""] * 33,
     rgba8_dfd(False), 4)

# The example chain of examples/assets/bc1_mips.bin wrapped in a DX10 header as BC1_RGBA_SRGB.
chain = Path("examples/assets/bc1_mips.bin").read_bytes()
sizes = [2048, 512, 128, 32, 8, 8, 8]
starts = [sum(sizes[:mip]) for mip in range(len(sizes))]
dds_levels = [chain[start:start + size] for start, size in zip(starts, sizes)]
dds(Path("examples/assets/bc1_mips.dds"), 64, 64, dds_levels, DX10, 72)

```

Real-tool files sit in one subdirectory per source and are committed unmodified; tests mutate in-memory copies only.
Licenses are listed in [test/fixtures/LICENSES.md](../test/fixtures/LICENSES.md). Offsets in the tests were read from
each file's header.

| Directory | Source, commit | License | Writer | Files |
| --- | --- | --- | --- | --- |
| `imagemagick/` | this project, WSL host (Ubuntu 22.04) | project-authored | ImageMagick 6.9.11-60 Q16 | `dxt1_8x8.dds`, `dxt5_16x8.dds` |
| `ktxtest/` | [sevmeyer/ktxtest](https://github.com/sevmeyer/ktxtest) `e1181e40de001d0d073161f3758d3262f3cd507b`, `ktx/valid/{compression,format,composition}/` | CC0 1.0 | containers ktxjuggle; BC payloads CompressonatorCLI 3.1.307 | `format_bc1_rgba_unorm.ktx`, `format_bc1_rgb_unorm.ktx`, `format_bc3_unorm.ktx`, `format_bc4_unorm.ktx`, `format_bc5_unorm.ktx`, `format_bc7_unorm.ktx`, `endian_big_type_ubyte_r8g8.ktx`, `array_2_elements_2d.ktx` |
| `gltf_sample_assets/` | [KhronosGroup/glTF-Sample-Assets](https://github.com/KhronosGroup/glTF-Sample-Assets) `edc7c9e67c639d230715049ee31f9a96a6babbbe`, `Models/FlightHelmet/glTF-KTX-BasisU/` | CC0 1.0 | `ktx create v4.4.2` (its `KTXwriter` key) | `FlightHelmet_Materials_LensesMat_Normal.ktx2` |
| `bcnencoder/` | [Nominom/BCnEncoder.NET](https://github.com/Nominom/BCnEncoder.NET) `51d3199b3bc374e0bdda3947d9f347cb6235a9a0`, `BCnEncTests/testImages/` | public domain (that directory's `NOTICE`) | not recorded (no header tag) | `test_decompress_bc1a.dds`, `test_decompress_bc1a.ktx`, `decoding_dds_bc5.dds` |
| `openimageio/` | [AcademySoftwareFoundation/OpenImageIO-images](https://github.com/AcademySoftwareFoundation/OpenImageIO-images) `d13e98f92b4e75ae7cd949cc5aa1df219560fb93`, `dds/` and `ktx2/` | Apache-2.0 | `dds_dxgi_rgba8_srgb.dds`, `dds_dxgi_bc7_srgb.dds`: not recorded (no header tag); `dds_npot_bc3_mips.dds`, `dds_npot_rgba8_mips.dds`: GIMP DDS plug-in (header tag); `rgba8_unorm_bc7.ktx2`: `ktx transcode v5.0` (`KTXwriter` key), attributed by the repository's `THIRD-PARTY.md` to KhronosGroup/KTX-Software `16059fa93d834242a0aaed9bb54952d76b143fac` `tests/resources/ktx2`, where no file of that name exists | `dds_dxgi_rgba8_srgb.dds`, `dds_dxgi_bc7_srgb.dds`, `dds_npot_bc3_mips.dds`, `dds_npot_rgba8_mips.dds`, `rgba8_unorm_bc7.ktx2` |
| `ktx2_samples/` | [donmccurdy/KTX2-Samples](https://github.com/donmccurdy/KTX2-Samples) `471931bbe05c5a5443da3ea7be37f44680664ac6`, `ktx2/` | CC BY-SA 4.0 | `ktx create` and `ktx transcode` v4.3.1 (`KTXwriter` keys) | `2d_rgba8.ktx2`, `2d_rgba8_linear.ktx2`, `2d_rgba16_linear.ktx2`, `2d_rgba32_linear.ktx2`, `2d_bc1.ktx2`, `2d_bc3.ktx2`, `2d_bc4.ktx2`, `2d_bc5.ktx2`, `2d_bc7.ktx2` |

Each real-tool file stays within 64 KB (largest 34,448 bytes); they total 142,009 bytes. The DDS writer column
comes from the `dwReserved1` tag at offset 32 (`GIMP-DDS\`, `IMAGEMAGICK`). SHA-256, relative to
`test/fixtures/texture/`:

```text
2e87df1a4db0766ec552e3be0dcb2da3c7c1b9cfbd74eaadf80855ed01e3bf6e  imagemagick/dxt1_8x8.dds
49e2f82ce96f878ef89129f13e0ec6f71415d8b1808e43f58d5cccfe698b610d  imagemagick/dxt5_16x8.dds
ce2b4099dedac9a66546969a247a2d4d5ef00e5ad44d055a158f16dd3474c20a  ktxtest/array_2_elements_2d.ktx
ea6c6df70d04799acd087faf0aca3684c98db8423f4cf10d89e0cc9abb43ee07  ktxtest/endian_big_type_ubyte_r8g8.ktx
08d5d538bfa7bd4643285a615dd5baf6c136adfc211d63bbd996d074a5e85428  ktxtest/format_bc1_rgb_unorm.ktx
6118c7ee97850b11fcf08da3b2d7c4b3d605559a2470e28e77c0bba4048ec6c1  ktxtest/format_bc1_rgba_unorm.ktx
d271a5bab6d8e22fae09b0906635dca435948751f15ac8733cb241387539f60b  ktxtest/format_bc3_unorm.ktx
be09bc04d57209890e25382418ce59609283064d1ebe0d78dac9da4c78313ea9  ktxtest/format_bc4_unorm.ktx
e25ffe304cd21da54973470870f16e7ed46ef905e8a5ea083edc62a0b91e3e7d  ktxtest/format_bc5_unorm.ktx
46562bcb4bd8e4df85cdc9ba3b2935e4fbf32c7f75b000fb24d3a1ce291727cf  ktxtest/format_bc7_unorm.ktx
b240ec01ac1507a1310d765a277055d731ba9cd432cc905715cfba026f6e7fb8  gltf_sample_assets/FlightHelmet_Materials_LensesMat_Normal.ktx2
b73a865bf7c8abcc6262abdb5906312865a3ca6d46329886770e31fb02e52c4c  bcnencoder/decoding_dds_bc5.dds
616c5c4ab167c76e412c0b5590a8dd5b62544f0564c51bc2f9d2b63f09d268f7  bcnencoder/test_decompress_bc1a.dds
ac49918975cd30f5e9977748aa92f7b794d64cf39934d9ba94ccdff9264eac7c  bcnencoder/test_decompress_bc1a.ktx
6350c9ec42ded1919ff228d9bff452264712ee46ff52c7904fa9385e12a18029  openimageio/dds_dxgi_bc7_srgb.dds
0389c6ac9a8703b6b8067f7f568adf73bc023d993b5d5db8d1e0296ecb84fb88  openimageio/dds_dxgi_rgba8_srgb.dds
e91c03a4f18b645b87c811bdaf9f509863cc17c97744ee667dcd97d7fbe12fbe  openimageio/dds_npot_bc3_mips.dds
b3d4627f103eebb50114767d160a245d75f12a3ae6bf91ddd5570eda9c0f82e5  openimageio/dds_npot_rgba8_mips.dds
50c6be6bfdc9bd8f9f4b3e36c706c8fa4d44e986b3e697267510a076cc6dbe3d  openimageio/rgba8_unorm_bc7.ktx2
0db6a87f438a041c82e66d1f28253300d02c1fbdbe19482c572a8bc05a280f02  ktx2_samples/2d_bc1.ktx2
d648816901d6b8837196db36532e4d5f18358bdcf9fef46b68b2a1724ffea35e  ktx2_samples/2d_bc3.ktx2
06852ffdb83f8ff795816ebb7c989b5e386452b2df2dc526bfe86af5395eb6c7  ktx2_samples/2d_bc4.ktx2
525541387e7c44f9301be18ca95bae742ec3f5cf9d4b97421cdf23291905eb35  ktx2_samples/2d_bc5.ktx2
2dd67c154866013ee94af54cafc8a2c0f0ba68422088b20534232eed2bd8e9cd  ktx2_samples/2d_bc7.ktx2
e62b6b2f7da518f44963380775be74c4ce3ac09b575c0e7823a50f9eea1b2a27  ktx2_samples/2d_rgba16_linear.ktx2
0362d7db179ccfbfca0e94be8a118e9ad3637b4defa2c62b85dbd8dab357174c  ktx2_samples/2d_rgba32_linear.ktx2
0da48bf53ad1720122514895c1106c95593d27528cf7feb65c4daba9f9111a73  ktx2_samples/2d_rgba8.ktx2
41b8a0d3a481bb26fad0a2fd27507ecbe030b72fb5811f9e4dd18ca5e8b1193f  ktx2_samples/2d_rgba8_linear.ktx2
```

The ImageMagick files were written once with:

```bash
convert -size 8x8 gradient:red-blue -define dds:compression=dxt1 test/fixtures/texture/imagemagick/dxt1_8x8.dds
convert -size 16x8 gradient:red-blue -alpha set -channel A -evaluate set 50% +channel \
    -define dds:compression=dxt5 test/fixtures/texture/imagemagick/dxt5_16x8.dds
```

ImageMagick 6 writes the full mip chain for power-of-two extents only.

# Standard material fixtures

`examples/assets/pbr/` contains four project-authored 64×64 RGBA PNGs.
`base_color.png` is an sRGB checker with opaque and partially transparent squares;
`material_data.png` stores linear occlusion in R, roughness in G and metallic in B.
`normal.png` encodes a periodic tangent-space XYZ normal in linear RGB, and
`emissive.png` is an sRGB orange cross. They are generated once with Python's
standard library using the recipe below; no encoder runs during builds.

```python
import math, struct, zlib
from pathlib import Path

def png(path, pixels, width=64, height=64):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    rows = b''.join(b'\x00' + pixels[y * width * 4:(y + 1) * width * 4] for y in range(height))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
                    + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b''))

def byte(value):
    return max(0, min(255, round(value * 255)))

output = Path('examples/assets/pbr')
output.mkdir(parents=True, exist_ok=True)
images = {name: bytearray() for name in ['base_color', 'material_data', 'normal', 'emissive']}
for y in range(64):
    for x in range(64):
        u, v = (x + 0.5) / 64, (y + 0.5) / 64
        checker = ((x // 8) + (y // 8)) % 2
        images['base_color'].extend((240, 210, 160, 255) if checker else (70, 120, 200, 80))
        ao = 0.2 if x < 32 else 1.0
        roughness = 0.3 if y < 32 else 1.0
        images['material_data'].extend((byte(ao), byte(roughness), 255, 255))
        slope_x = 0.5 * math.cos(4 * math.pi * u) * math.sin(4 * math.pi * v)
        slope_y = 0.5 * math.sin(4 * math.pi * u) * math.cos(4 * math.pi * v)
        length = math.sqrt(slope_x * slope_x + slope_y * slope_y + 1)
        images['normal'].extend((byte((-slope_x / length + 1) / 2), byte((-slope_y / length + 1) / 2),
                                 byte((1 / length + 1) / 2), 255))
        images['emissive'].extend((255, 80, 20, 255) if 28 <= x < 36 or 28 <= y < 36 else (0, 0, 0, 255))
for name, pixels in images.items():
    png(output / (name + '.png'), pixels)
```
