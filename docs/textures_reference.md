# Textures reference

Supplied mip chains, compressed formats and the DDS and KTX container loaders of `c3d::asset::image`. The
[textures guide](textures.md) covers loading, color spaces and UVs.

## Supply mip levels

`add_texture_mips` copies a complete array of `TextureMipData` records and every payload into the store. Supply records
in mip-major order, then layer order:

```c3
char[16] base_rgba = {
    255, 0, 0, 255, 255, 0, 0, 255,
    255, 0, 0, 255, 255, 0, 0, 255,
};
char[4] tail_rgba = { 0, 255, 0, 255 };
TextureMipData[2] levels = {
    { .mip = 0, .layer = 0, .bytes = base_rgba[..] },
    { .mip = 1, .layer = 0, .bytes = tail_rgba[..] },
};
TextureDesc desc = material::texture_2d_desc(2, 2, RGBA8_SRGB);
desc.generate_mips = false;
desc.mip_levels = 2;
TextureId supplied = assets.add_texture_mips(desc, levels[..], "example/supplied")!;
renderer.upload(supplied)!;
```

The renderer uploads supplied uncompressed levels without filtering or conversion, so the 1x1 level above stays green.

- A cube supplies six records for mip zero, then six for mip one, and so on, using `texture_cube_desc` with generation
  disabled.
- Every allocated mip and layer occurs exactly once with a complete, tightly packed payload.
- `mip_levels` is positive and can describe a chain shorter than the full one for the extent. Upload rejects a count
  above the full chain and checks the exact per-layer byte footprints.
- `add_texture_mips` faults `c3d::INVALID_ARGUMENT` for zero mip or layer counts, `generate_mips` set, missing or
  misordered records, empty payloads and size overflow.

### Ownership

The store source kind is `SUPPLIED_MIPS`; `add_texture`, `add_texture_owned` and the image loaders produce `MIP_ZERO`.
The store keeps one allocation: the record array is its prefix, followed by the byte payloads. The stored records and their
`bytes` slices are interior borrows. Never free the slices individually, replace their pointers or lengths, or reorder
the records. The input records and arrays can change or be released once insertion succeeds. There is no
ownership-transfer overload for supplied mips.

## Compressed 2D textures

The supplied-mip API accepts `BC1_RGBA_UNORM`, `BC1_RGBA_SRGB`, `BC3_UNORM`, `BC3_SRGB`, `BC4_UNORM`, `BC5_UNORM`,
`BC6H_UFLOAT`, `BC7_UNORM` and `BC7_SRGB`.

- A compressed texture is a sampled 2D image with one layer. Set `generate_mips = false` and provide every allocated
  level.
- Levels hold complete 4x4 blocks. A 1x1 BC1 level still takes eight bytes and BC7 takes sixteen; odd extents round up
  to whole blocks.
- Bytes stay compressed in the store and in upload staging. No decoder, transcoder or mip generator runs on them.
  Container loaders slice files without changing a byte.
- Unsupported device formats propagate the backend fault, such as `gpu::UNSUPPORTED_FEATURE`, at upload. There is no
  uncompressed fallback.
- Compressed cubes, cube arrays, non-cube arrays and volumes are unsupported.

## Load DDS and KTX containers

`load_texture_container(assets, path, color_space, key, semantic)` reads a DDS, KTX 1.1 or KTX 2.0 file.
`add_texture_container(assets, bytes, color_space, key, semantic)` takes bytes already in memory. Both require an
`assets.allocator` other than `tmem`, copy every level byte for byte into one store allocation (the `SUPPLIED_MIPS`
source), and leave the store unchanged on a fault. `load_texture_container` frees the file buffer before it returns.

- The container sets the format, extent and level count.
- A KTX file that asks for generated mips (a level count of 0) of an uncompressed format other than `R16_UINT` loads as a
  `MIP_ZERO` texture with `generate_mips` set.
- `color_space` is `FROM_FILE` (default), `SRGB` or `LINEAR`. `FROM_FILE` keeps the container's format; legacy DDS headers
  carry no color space and load as UNORM. `SRGB` and `LINEAR` pick the sRGB or UNORM twin of RGBA8, BC1, BC3 and BC7 without
  touching the bytes, and an explicit choice overrides the file. `LINEAR` leaves the other formats as they are; `SRGB` on
  them faults `c3d::INVALID_ARGUMENT`.
- `semantic` marks normal data; supplied texels stay unchanged.

To inspect a container first, parse it into a borrowed view:

```c3
@pool() {
    image::TextureContainerView container = image::parse_texture_container(tmem, bytes)!;
    io::printfn("%s, %d levels", container.desc.format, container.level_count);
};
```

The view's level slices point into `bytes`. The exception is a KTX1 `R16_UINT` level with an odd width, whose padded rows
are copied tight into the `scratch` allocator. The view is invalid once `bytes` or `scratch` is freed.

### Rows and orientation

Rows are never flipped. DDS rows are taken as stored. A KTX file loads when `KTXorientation` is absent or says top-left
(`S=r,T=d` in KTX1, `rd` in KTX2): both specifications put the first stored texel at the texture-coordinate origin, and c3d
samples the first stored row at v = 0. Tools that wrote GL-style bottom-up rows without the key load upside down under
glTF UVs; re-export them top row first.

### Supported formats

| `PixelFormat` | DDS legacy | DXGI | KTX1 `glInternalFormat` (`glType` / `glFormat`) | KTX2 vkFormat |
| --- | --- | --- | --- | --- |
| RGBA8_UNORM | `DDPF_RGB`, 32 bit, masks R `0xFF` G `0xFF00` B `0xFF0000` A `0xFF000000` | 28 | `GL_RGBA8` 0x8058 (`GL_UNSIGNED_BYTE` 0x1401 / `GL_RGBA` 0x1908) | 37 |
| RGBA8_SRGB | none | 29 | `GL_SRGB8_ALPHA8` 0x8C43 (0x1401 / 0x1908) | 43 |
| RGBA16_FLOAT | FourCC 113 | 10 | `GL_RGBA16F` 0x881A (`GL_HALF_FLOAT` 0x140B / 0x1908) | 97 |
| RGBA32_FLOAT | FourCC 116 | 2 | `GL_RGBA32F` 0x8814 (`GL_FLOAT` 0x1406 / 0x1908) | 109 |
| R16_UINT | none | 57 | `GL_R16UI` 0x8234 (`GL_UNSIGNED_SHORT` 0x1403 / `GL_RED_INTEGER` 0x8D94) | 74 |
| BC1_RGBA_UNORM | `DXT1` | 71 | 0x83F1; 0x83F0 after the scan | 133; 131 after the scan |
| BC1_RGBA_SRGB | none | 72 | 0x8C4D; 0x8C4C after the scan | 134; 132 after the scan |
| BC3_UNORM | `DXT5` | 77 | 0x83F3 | 137 |
| BC3_SRGB | none | 78 | 0x8C4F | 138 |
| BC4_UNORM | `ATI1`, `BC4U` | 80 | 0x8DBB | 139 |
| BC5_UNORM | `ATI2`, `BC5U` | 83 | 0x8DBD | 141 |
| BC6H_UFLOAT | none | 95 | 0x8E8F | 143 |
| BC7_UNORM | none | 98 | 0x8E8C | 145 |
| BC7_SRGB | none | 99 | 0x8E8D | 146 |

- Each container holds one 2D image with one layer.
- Uncompressed KTX1 formats need the listed `glType` and `glFormat`; compressed ones need 0 for both.
- The legacy DDS FourCCs, `ATI1` and `ATI2` included, are those DirectXTex reads
  ([`g_LegacyDDSMap`](https://github.com/microsoft/DirectXTex/blob/20f7316f1b55dcab3479636015e643c9559fa193/DirectXTex/DirectXTexDDS.cpp#L61-L167)).
- Legacy `DXT1` loads as `BC1_RGBA_UNORM`, which decodes a BC1 file without alpha to the same RGB. BC1 without alpha in KTX
  (`0x83F0`, `0x8C4C`, vkFormat 131 and 132) loads as the `BC1_RGBA` twin when no three-color block uses index 3, the only
  texels the two forms decode differently. Otherwise it is unsupported.

### Rejected variants

| Container | Variant | Fault | Offline route |
| --- | --- | --- | --- |
| DDS | `DXT3` (BC2) | `UNSUPPORTED` | `texconv -f BC3_UNORM` |
| DDS | `DXT2`, `DXT4` (premultiplied BC2, BC3) | `UNSUPPORTED` | `texconv -alpha -f BC3_UNORM` |
| DDS | BGRA or BGRX masks; DXGI B8G8R8A8, B8G8R8X8 (87, 88, 91, 93) | `UNSUPPORTED` | `texconv -f R8G8B8A8_UNORM` (or `R8G8B8A8_UNORM_SRGB`) |
| DDS | X8B8G8R8 (no alpha mask) | `UNSUPPORTED` | `texconv -f R8G8B8A8_UNORM` |
| DDS | luminance, alpha-only, YUV, bump, 16- or 24-bit RGB, any other FourCC (`BC4S`, `BC5S`, 36) | `UNSUPPORTED` | `texconv -f` one of the supported DXGI formats |
| DDS DX10 | typeless formats (27, 70, 73, 76, 79, 82, 94, 97) | `UNSUPPORTED` | `texconv -tu -f <format>_UNORM` (or `_UNORM_SRGB`); `-tu` treats TYPELESS as UNORM ([texconv](https://github.com/microsoft/DirectXTex/wiki/Texconv)) |
| DDS DX10 | BC2 (74, 75), BC4 and BC5 SNORM (81, 84), BC6H SF16 (96), any other DXGI format | `UNSUPPORTED` | `texconv -f BC3_UNORM`, `BC4_UNORM`, `BC5_UNORM` or `BC6H_UF16` |
| DDS DX10 | premultiplied alpha mode | `UNSUPPORTED` | `texconv -alpha` |
| DDS | cube, volume, array, 1D | `UNSUPPORTED` | export each 2D image; load cube faces with `load_cube` |
| KTX1 | big-endian | `UNSUPPORTED` | `ktx convert` (legacy `ktx2ktx2`), then load the KTX2 file |
| KTX1 | `glInternalFormat` outside the table (unsized `GL_RGBA`, `GL_RGB8`, DXT3, signed RGTC, signed BC6H) | `UNSUPPORTED` | re-export in a supported format |
| KTX1, KTX2 | 1D, 3D, arrays, cubes | `UNSUPPORTED` | export each 2D image |
| KTX1, KTX2 | generated mips requested for a block format or `R16_UINT` | `UNSUPPORTED` (`ASSET_FORMAT_ERROR` for KTX2 block formats, which the specification forbids) | write every level |
| KTX1, KTX2 | `KTXorientation` other than top-left | `UNSUPPORTED` | re-export top row first: `ktx create` from the source images (its default origin is top-left) or `texconv -vflip` for DDS |
| KTX1, KTX2 | `KTXswizzle` other than `rgba` | `UNSUPPORTED` | re-create with `ktx create --input-swizzle`, which moves the channels, instead of `--swizzle` metadata |
| KTX1, KTX2 | BC1 without alpha with a three-color block that uses index 3 | `UNSUPPORTED` | re-encode as BC1 with alpha, for example `texconv -f BC1_UNORM` (writes DDS) |
| KTX2 | BasisLZ or UASTC payloads, Zstandard or ZLIB supercompression | `UNSUPPORTED` | `ktx transcode --target bc7` (or `bc1`, `bc3`, `bc4`, `bc5`, `rgba8`); other supercompressed files: re-create without `--zstd` or `--zlib` |
| KTX2 | `VK_FORMAT_UNDEFINED` or a vkFormat outside the table | `UNSUPPORTED` | re-export in a supported format, for example `ktx create --format R8G8B8A8_SRGB` |
| KTX2 | premultiplied DFD flag | `UNSUPPORTED` | re-export with straight alpha |

### Container faults

Container loaders separate malformed files from unsupported ones:

- `c3d::ASSET_IO_ERROR`: the file cannot be read.
- `c3d::ASSET_FORMAT_ERROR`: empty input, an unknown magic, a truncated header, index or payload, a level whose offset,
  length or alignment is wrong, overlapping KTX2 levels, bytes after the last KTX2 level, a level count the extent cannot
  have, or fields that contradict each other (KTX1 `glType` and `glFormat`, KTX2 `typeSize`, `uncompressedByteLength` and
  the data format descriptor's transfer function).
- `c3d::UNSUPPORTED`: a well-formed container outside the supported set, or a normal semantic on `R16_UINT`.
- `c3d::INVALID_ARGUMENT`: `SRGB` for a format without an sRGB twin, a normal semantic on an sRGB format, or a key the
  store rejects.
- `c3d::CAPACITY_EXCEEDED`: the texture pool is full.

DDS and KTX1 readers ignore advisory fields (DDS flags, pitch and caps other than the cube and volume bits; KTX1
`glTypeSize` and `glBaseInternalFormat`) and bytes after the last level. KTX2 is read strictly. Device support for a format
is checked at upload.

## See also

- [Textures](textures.md) for loaders, color spaces and CPU sources.
- [Texture streaming](texture_streaming.md) for region edits, replacement and residency.
