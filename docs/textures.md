# Textures and images

Basic supports one color map; [Standard materials](materials.md#standard-maps)
support base color, metallic/roughness, normal, occlusion and emissive maps.

A texture asset owns either mip-zero pixels or supplied mip/layer data. A material
slot selects a 2D texture, sampler, UV set and UV transform. The renderer owns
uploaded images and either builds mips or uploads the supplied levels unchanged.

## Load a color map

Import `c3d`, `c3d::asset`, `c3d::asset::image` and `c3d::material`.
Given a live `AssetStore assets`:

```c3
TextureId texture = image::load_texture(
    assets: &assets,
    path: "albedo.png",
    srgb: true,
    key: "example/albedo",
)!;
MaterialId material_id = assets.add_material(material::basic({
    .color = { 1, 1, 1, 1 },
    .map = material::texture_slot(texture),
}))!;
```

PNG and JPEG decode to four eight-bit channels with the top row first. JPEG's
missing alpha becomes 255. Choose `srgb: true` for color maps and `false` for
linear data such as masks. The storage format becomes `RGBA8_SRGB` or
`RGBA8_UNORM`; selecting sRGB does not rewrite the decoded bytes. No loader flips
rows or changes global decoder settings.

Basic shading multiplies its color by the sampled map. A material with no map
keeps its color-only behavior. `texture_slot(texture)` selects UV0, the builtin
trilinear repeat sampler, and an identity transform.

## Standard color and data maps

Load base-color and emissive images with `srgb: true`; load metallic/roughness,
normal and occlusion images with `srgb: false`. Base RGBA multiplies the base
factor, G/B multiply roughness/metallic, RGB encodes tangent-space XYZ normals,
R controls ambient occlusion, and emissive RGB multiplies emission. Alpha remains
linear even in sRGB formats. A packed R/G/B image can serve occlusion and
metallic/roughness through two independent slots sharing one texture asset.

Each slot starts absent with identity coordinates in `STANDARD_PARAMS_DEFAULT`;
normal scale and occlusion strength both start at 1. Use the named default before
assigning maps. Normal scale is finite and signed; occlusion strength is [0, 1].
Missing or stale ids preserve scalar factors and the geometry normal. Normal maps
require all XYZ channels; there is no RG-only Z reconstruction or MikkTSpace
guarantee. See [tangent frames](materials.md#tangent-frames) for supplied-tangent
authority, derivative fallback and unsupported nontriangle/wireframe cases.

The mapped `pbr` example loads four committed fixtures relative to its source file,
so it does not depend on the launch directory. Both geometry variants and all
referenced textures are prepared before interaction. Its private map editor can
change each slot without modifying shared UV streams; scalar and mapped presets
make the difference visible. See [the example controls](materials.md#interactive-example)
and [fixture provenance](../csrc/README.md#standard-material-fixtures).

## Decode memory and retain ownership

Use `decode_image` for embedded or already-loaded PNG, JPEG or Radiance HDR
bytes. `load_image(allocator, path)` returns the same owned `Image` from a file:

```c3
image::Image decoded = image::decode_image(mem, encoded_bytes)!;
defer image::destroy_image(&decoded);

TextureId texture = assets.add_texture(
    material::texture_2d_desc(decoded.width, decoded.height, decoded.format),
    decoded.pixels,
)!;
```

`Image` stores its allocator and owns one pixel allocation. `add_texture` copies
pixels into the store, so destroying the decoded image or ending its temporary
pool does not invalidate the texture. For a color PNG/JPEG, select
`RGBA8_SRGB` in the texture description when the bytes represent sRGB color.

To avoid that second copy, decode with `assets.allocator` and transfer the slice:

```c3
image::Image decoded = image::decode_image(assets.allocator, encoded_bytes)!;
defer image::destroy_image(&decoded);

TextureId texture = assets.add_texture_owned(
    material::texture_2d_desc(decoded.width, decoded.height, decoded.format),
    decoded.pixels,
)!;
decoded.pixels = {};
```

Clear the image's slice only after insertion succeeds. On failure it still owns
its allocation. `load_texture` and `load_hdr` use this transfer path internally;
keys follow the store's existing uniqueness policy and are not replaced.

## Write a PNG

`image::write_png(path, width, height, pixels)` encodes tightly packed RGBA8 rows, top row first,
as a PNG file and writes the bytes unchanged (no colour-space chunk), so pass sRGB-encoded bytes
for colour, such as a `read_render_target` copy of an `RGBA8_SRGB` target. A zero extent or a
buffer that is not width x height x 4 bytes faults `INVALID_ARGUMENT`; a file that cannot be
written faults `ASSET_IO_ERROR`. The encoder is C3 over the standard library's deflate and needs
no C source.

## HDR data and mip filtering

```c3
TextureId environment_pixels = image::load_hdr(&assets, "studio.hdr")!;
```

`load_hdr` accepts Radiance HDR and stores `RGBA32_FLOAT`, retaining values above
one. Its pixel slice contains tightly packed four-channel floats. It rejects
PNG/JPEG rather than implicitly converting their range. Conversely,
`load_texture` rejects HDR. Register the resulting TextureId through
`light::texture_environment` and `assets.add_environment` for
[image-based lighting or an independent sky](environments.md). Texture loading
does not perform display tonemapping.

Two-dimensional uploads support `RGBA8_UNORM`, `RGBA8_SRGB`, `RGBA16_FLOAT`,
`RGBA32_FLOAT` and `R16_UINT`. `texture_2d_desc` requests a complete mip chain by
default. Mips filter sRGB RGB channels in linear light, alpha linearly, and
floating-point channels without clamping their range. Odd edges contribute to the
filtered result. Disable `desc.generate_mips` for mip zero alone. `R16_UINT` takes
no generated mips: `add_texture` rejects the request with
`c3d::INVALID_ARGUMENT`. Uncompressed cube textures use the same formats and
filter each face independently. Supplied levels, including compressed ones, use
the copying API below and are never regenerated.

Builtin sampler ids are `asset::SAMPLER_NEAREST`,
`asset::SAMPLER_LINEAR_REPEAT`, `asset::SAMPLER_LINEAR_CLAMP` and
`asset::SAMPLER_ANISOTROPIC`. The renderer clamps requested anisotropy to device
limits. Sampler choice lives on the material slot, so several materials can use
the same texture with different filtering. Builtin texture and sampler ids are reserved
for the store lifetime; removal applies to custom assets. Their CPU pixels may still be
released after preparation.

A zero or stale map reference uses that slot's scalar or unperturbed-normal
fallback; a zero or stale sampler reference selects builtin trilinear repeat.
A live cube reference in any Basic or Standard material slot reports `c3d::UNSUPPORTED`; cube views use a different sampled-image heap.
So does an `R16_UINT` texture, which only an integer fetch can read.
Render-target references, non-cube arrays and volumes remain unsupported.

## Sixteen-bit single-channel data

`R16_UINT` holds one unsigned 16-bit integer per texel, such as a height map.
Load one from a PNG or JPEG:

```c3
TextureId heights = image::load_texture_r16(&assets, "heights.png")!;
```

`load_texture_r16` stores a single-mip, linear texture with the top row first and
the texels in native byte order; `decode_image_r16` returns the same data as an
`Image` without inserting it. A 16-bit PNG keeps all 16 bits. An 8-bit PNG or JPEG
widens exactly, `v × 257`, so 255 becomes 65535, and color reduces to luminance.
Radiance input is rejected with `c3d::ASSET_FORMAT_ERROR`, since its decoder
would pass 8-bit values as heights. For RAW heights, pass native-order `ushort`
texels to `add_texture` with an `R16_UINT` description and `generate_mips`
disabled.

Shaders read the texture only through gpu.c3l's integer fetch, never through a
sampler, so filtering is manual. `texture_fetch.glsl` includes it:

```glsl
uint height = gpu_fetch_uint(material.slots[0].texture_index, texel, 0);
```

A custom material may hold it in any slot except slot 0 of a masked material,
which the depth stage and traced coverage sample for alpha. A dispatch reads it
through a `read_texture` entry. A Basic, Standard, Physical or Toon map, a Toon
gradient map, and slot 0 of a masked custom material report `c3d::UNSUPPORTED`
when the material is uploaded or drawn. `R16_UINT` is not a storage, render
target, volume or environment source format.

Heights follow `offset + scale × texel / 65535`, beside the 8-bit
`texel / 255`. A physics height field reads an `R16_UINT` texture with the same
convention: its node's position and `local.scale.y` supply the offset and scale.

## Load six cube faces

```c3
String[material::CUBE_FACE_COUNT] faces = {
    "positive_x.png", "negative_x.png",
    "positive_y.png", "negative_y.png",
    "positive_z.png", "negative_z.png",
};
TextureId cube = image::load_cube(
    assets: &assets,
    paths: faces,
    srgb: true,
    key: "example/cube",
)!;
renderer.upload(cube)!;
```

`CubeFace` names this order: `POSITIVE_X`, `NEGATIVE_X`, `POSITIVE_Y`,
`NEGATIVE_Y`, `POSITIVE_Z`, `NEGATIVE_Z`. Each path must be nonempty. Every face
must be square, equally sized, and decode to the same format. PNG and JPEG may
be mixed because both normalize to byte RGBA. Six Radiance HDR files produce
`RGBA32_FLOAT` regardless of `srgb`; mixing HDR and byte faces is a format error.
Failed loading or insertion releases all partial face allocations.

Faces remain top-row-first with no rotations, flips or inferred filename
conventions. Supply their native cube orientation. The preview uses this mapping,
where `s = 2u - 1`, `t = 2v - 1`, and image coordinates increase right/down:

| Face | Sampling direction |
| --- | --- |
| +X | `(1, -t, -s)` |
| -X | `(-1, -t, s)` |
| +Y | `(s, 1, t)` |
| -Y | `(s, -1, -t)` |
| +Z | `(s, -t, 1)` |
| -Z | `(-s, -t, -1)` |

`texture_cube_desc(size, format)` describes six square layers and generated mips.
Its mip-zero bytes contain complete faces in that order. The renderer creates one
cube-compatible image and one native sampled cube view. The cube preview samples
that view by direction; Basic materials remain 2D. Register the cube as an
[environment source](environments.md) to use it for scene lighting or a sky.
Environment processing borrows the native cube and bypasses equirectangular
conversion.

## Supply mip levels

`add_texture_mips` copies a complete array of `TextureMipData` records and every
payload into the store. Supply records in mip-major order, then layer order:

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

The deliberately green 1×1 level stays green. Supplied uncompressed levels are
copied without filtering or conversion. A cube supplies six records for mip zero,
then six for mip one, and so on, using `texture_cube_desc` with generation disabled.
Every allocated mip/layer must occur exactly once, with a complete tightly packed
payload. `mip_levels` may describe a shorter chain than the full extent permits;
it must be positive and cannot exceed that full count.

The store's source kind is `SUPPLIED_MIPS`; ordinary `add_texture`,
`add_texture_owned` and image loaders select `MIP_ZERO`. Supplied storage is one
owned allocation: the record array is its prefix, followed by the byte payloads.
The stored records and their `bytes` slices are interior borrows. Never free byte
slices individually, replace their pointers/lengths, or reorder records. The
input records and arrays may be changed or released after insertion succeeds.
There is no ownership-transfer overload for supplied mip data.

### Compressed 2D textures

The same supplied API accepts `BC1_RGBA_UNORM`, `BC1_RGBA_SRGB`, `BC3_UNORM`,
`BC3_SRGB`, `BC4_UNORM`, `BC5_UNORM`, `BC6H_UFLOAT`, `BC7_UNORM` and `BC7_SRGB`.
Compressed textures are sampled 2D images with one layer. Set
`generate_mips = false` and provide every allocated level, including complete
blocks at small tails: a 1×1 BC1 level still occupies eight bytes, and BC7 uses
sixteen. Odd extents round up to complete 4×4 blocks.

Bytes stay compressed in both the asset store and upload staging. No decoder,
transcoder or mip generator runs on them; [container loaders](#load-dds-and-ktx-containers)
slice files without changing a byte. Unsupported
device format support propagates the backend fault, including
`gpu::UNSUPPORTED_FEATURE`; there is no automatic uncompressed fallback.
Compressed cubes, cube arrays, non-cube arrays and volumes are unsupported.

## Load DDS and KTX containers

Import `c3d::asset::image`. `load_texture_container` reads a DDS, KTX 1.1 or KTX 2.0 file and inserts its levels
unchanged; `add_texture_container` does the same for bytes already in memory, such as an `$embed`:

```c3
TextureId albedo = image::load_texture_container(
    assets:      &assets,
    path:        "albedo_bc7.ktx2",
    color_space: SRGB,
    key:         "example/albedo",
)!;
renderer.upload(albedo)!;
```

The container sets the format, extent and level count. Every level is copied byte for byte into one store
allocation, the same `SUPPLIED_MIPS` source that `add_texture_mips` makes; nothing is decoded, re-encoded, flipped or
regenerated. A KTX file that asks for generated mips (a level count of 0) of an uncompressed format other than
`R16_UINT` loads as a `MIP_ZERO` texture with `generate_mips` set. `load_texture_container` frees the file buffer
before it returns, and a fault leaves the store unchanged.

`color_space` is `FROM_FILE` (the default), `SRGB` or `LINEAR`. `FROM_FILE` keeps the container's format; legacy DDS
headers carry no color space and load as UNORM. `SRGB` and `LINEAR` pick the sRGB or UNORM twin of RGBA8, BC1, BC3
and BC7 without touching the bytes; an explicit choice overrides the file. `LINEAR` leaves the other formats as they
are; `SRGB` on them faults `c3d::INVALID_ARGUMENT`.

To inspect a container first, parse it into a borrowed view:

```c3
@pool() {
    image::TextureContainerView container = image::parse_texture_container(tmem, bytes)!;
    io::printfn("%s, %d levels", container.desc.format, container.level_count);
};
```

The view's level slices point into `bytes`. The exception is KTX1 `R16_UINT` with an odd width, whose padded rows are
copied tight into the `scratch` allocator. The view is invalid once `bytes` or `scratch` is freed. The store helpers
parse inside their own `@pool`, so the store's allocator must not be `tmem`.

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

Each container holds one 2D image with one layer. Uncompressed KTX1 formats need the listed `glType` and `glFormat`,
compressed ones 0 for both. The legacy DDS FourCCs, `ATI1` and `ATI2` included, are those DirectXTex reads
([`g_LegacyDDSMap`](https://github.com/microsoft/DirectXTex/blob/20f7316f1b55dcab3479636015e643c9559fa193/DirectXTex/DirectXTexDDS.cpp#L61-L167)).
Legacy `DXT1` loads as `BC1_RGBA_UNORM`, which decodes a BC1 file without alpha to the same RGB. BC1 without alpha in KTX (`0x83F0`, `0x8C4C`, vkFormat 131 and 132) loads as the `BC1_RGBA` twin when no
three-color block uses index 3, the only texels the two forms decode differently; otherwise it is unsupported.

Rows are never flipped. DDS rows are taken as stored. A KTX file loads when `KTXorientation` is absent or says
top-left (`S=r,T=d` in KTX1, `rd` in KTX2): both specifications put the first stored texel at the texture-coordinate
origin, and c3d samples the first stored row at v = 0. Tools that wrote GL-style bottom-up rows without the key load
upside down under glTF UVs; re-export them top row first.

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

Container loaders split the faults that image decoders report together:

- `c3d::ASSET_IO_ERROR`: the file cannot be read.
- `c3d::ASSET_FORMAT_ERROR`: empty input, an unknown magic, a truncated header, index or payload, a level whose
  offset, length or alignment is wrong, overlapping KTX2 levels, bytes after the last KTX2 level, a level count the
  extent cannot have, or fields that contradict each other (KTX1 `glType` and `glFormat`, KTX2 `typeSize`,
  `uncompressedByteLength` and the data format descriptor's transfer function).
- `c3d::UNSUPPORTED`: a well-formed container outside the supported set.
- `c3d::INVALID_ARGUMENT`: `SRGB` for a format without an sRGB twin, or a key the store rejects.
- `c3d::CAPACITY_EXCEEDED`: the texture pool is full.

DDS and KTX1 readers ignore advisory fields (DDS flags, pitch and caps other than the cube and volume bits; KTX1
`glTypeSize` and `glBaseInternalFormat`) and bytes after the last level. KTX2 is read strictly. Device support for a
format is still checked at upload, which reports the backend fault, such as `gpu::UNSUPPORTED_FEATURE`. Fixture
provenance: [texture container fixtures](../csrc/README.md#texture-container-fixtures).

## Select and transform UVs

```c3
TextureSlot* slot = &assets.material(material_id).data.basic.map;
slot.sampler = asset::SAMPLER_ANISOTROPIC;
slot.uv_set = 1;
slot.transform = {
    .offset = { 0.25f, 0 },
    .scale = { 4, 4 },
    .rotation = 0.5f,
};
assets.mark_material_dirty(material_id);
```

UV set zero selects `Geometry.uv0`, and one selects `Geometry.uv1`; supply the
chosen stream on the geometry. Transforms scale first, rotate about the UV
origin in radians, then translate. They do not modify shared geometry. Mark the
material dirty after changing its slot or color. Each Standard slot applies its
own coordinates independently. A normal-map lookup transform changes a derivative
frame but does not rotate an explicitly supplied tangent basis. Use `texture_slot`
for identity defaults:
a manually zero-initialized transform has zero scale, not identity.

For a cutout, start with `material::MATERIAL_COMMON_DEFAULT`, set
`common.alpha_mode = MASK` and pass `common` as the second argument to
`material::basic` or `material::standard`. The fragment's sampled alpha multiplied
by the material's color alpha is compared with `common.alpha_cutoff`, which defaults to 0.5.
Discarded fragments leave the geometry behind visible. This path supports
opaque and masked materials; alpha blending is not implemented.

## Upload, edit and release CPU sources

After creating a renderer associated with the store, outside an open frame:

```c3
renderer.upload(texture)!;
assets.release_texture_cpu(texture);
```

Successful explicit upload completes the upload work without presenting a frame.
Inside an open frame, upload records work for that frame's submission instead.
`renderer.prepare_scene(&scene)!` likewise prepares the scene's resources and
completes uploads. Both work with a renderer created without a surface; this does
not provide off-screen image rendering.

CPU release is explicit. It frees the selected source allocation and clears its
slices while preserving the asset's id, description, revision and source kind.
A current image already uploaded by that renderer remains usable. A second
renderer, a changed backing image, or another
upload requiring absent source bytes reports `c3d::ASSET_DATA_UNAVAILABLE`.
Keep either CPU source when it will be edited or uploaded into another renderer.

While pixels remain available, edit mip-zero data and advance the texture's
revision:

```c3
TextureAsset* source = assets.texture(texture);
source.pixels[0] = 255;
source.pixels[1] = 0;
source.pixels[2] = 255;
assets.mark_texture_dirty(texture);
renderer.upload(texture)!;
```

This example assumes a nonempty RGBA8 texture whose CPU pixels were retained.
The renderer regenerates mips on upload. The material revision need not change
for an edit to any referenced texture. This applies independently to all five
Standard slots, including shared images. Sampler revision changes and replacement
image backing also refresh the resolved bindings without a material edit. If a
texture is removed and its index reused, an old generation stays absent. Replacing
dimensions or format requires complete matching CPU bytes before marking the texture dirty.

For supplied data, edit only the retained bytes, then mark the texture dirty:

```c3
TextureAsset* source = assets.texture(supplied);
source.supplied_mips[1].bytes[0] = 255;
assets.mark_texture_dirty(supplied);
renderer.upload(supplied)!;
```

This edits the uncompressed example's supplied tail. Compressed edits must keep
valid complete blocks. To replace a supplied source's dimensions, format, mip
count or record structure, insert a new asset and update references. Do not edit
or release either source between preparation and submission. Current cube and BC
mirrors remain usable after explicit release, just like ordinary 2D textures.

## Faults and native requirements

Paths must be nonempty. File access failures produce `c3d::ASSET_IO_ERROR`;
malformed, unsupported, or wrong-loader image formats produce
`c3d::ASSET_FORMAT_ERROR`. DDS and KTX containers separate malformed from unsupported files
instead; see [container faults](#container-faults). Empty encoded data or data exceeding the native
integer length limit produces `c3d::INVALID_ARGUMENT`. Store insertion can also
produce `c3d::INVALID_ARGUMENT` for a duplicate key or
`c3d::CAPACITY_EXCEEDED` for a full texture pool. GPU upload faults propagate
unchanged; upload input with absent pixels reports
`c3d::ASSET_DATA_UNAVAILABLE`. Cube face shape/type mismatches report
`c3d::ASSET_FORMAT_ERROR`. Supplied insertion rejects zero mip/layer counts,
missing or misordered records, empty payloads and size overflow as
`c3d::INVALID_ARGUMENT`. Upload preparation also validates exact per-layer byte
footprints, accepted shapes and mip count. Malformed cube metadata is
`c3d::INVALID_ARGUMENT`; unsupported texture forms are `c3d::UNSUPPORTED`.
An `R16_UINT` description with generated mips or storage is
`c3d::INVALID_ARGUMENT` at insertion. `c3d::UNSUPPORTED` covers an `R16_UINT`
texture in a built-in material slot, a Toon gradient map or slot 0 of a masked
custom material when the material is uploaded or drawn, an `R16_UINT` volume at
upload, an `R16_UINT` render target, and an `R16_UINT` environment source.

The package vendors stb_image and compiles one C translation unit with c3c's
selected C compiler during ordinary builds. Follow the repository's
[prerequisites and native dependency setup](../README.md#prerequisites).
The current package still requires its declared GPU, SDL3, ImGui, geometry and
physics dependencies. Native package isolation remains deferred; there is no
separate decoder package.

## Run the example

```bash
python3 scripts/build.py --example textured
./examples/build/textured path/to/image.jpg
```

The default PNG is embedded, so running the executable does not depend on its
working directory. The scene is static: an image cube on the left, a masked quad
with an opaque magenta backing on the right, and a repeated checker floor into
the distance. The masked quad shows red and green top corners, blue and white
bottom corners, and the backing through its central hole.

| Control | Effect |
| --- | --- |
| N / L / A | Nearest / trilinear / anisotropic sampling |
| S | Toggle map scale between 1 and 4 |
| R | Add a 45-degree rotation about the UV origin |
| O | Add UV offset (0.25, 0.125) |
| U | Switch UV0 and UV1; UV1 swaps axes and doubles repetition |
| Backspace | Reset filtering, transform and UV selection |
| Left drag / wheel | Orbit / zoom |
| Escape release | Quit |

Map controls apply to all three textured materials and mark each dirty. The
example retains its CPU pixels and enables validation; GPU timings are off.

`examples/assets/texture.png` is project-authored: a 64×64 RGBA image with red,
green, blue and white quadrants. Alpha is zero where both coordinates fall in
`[24, 40)`, and 255 elsewhere. It was generated with Python `struct` and `zlib`:
write an 8-bit RGBA PNG IHDR, prefix each top-first row with filter byte zero,
zlib-compress the rows into IDAT, and CRC each chunk. The chunk writer is shown
in [the decoder fixture provenance](../csrc/README.md#test-fixtures). No image
encoder runs during a build.

## Frame ordering

An explicit texture upload inside an open renderer frame requires a drawable window output,
no open overlay, and must precede views that sample the texture. Finish asset pixel/descriptor
and material edits before preparation; do not edit or release their source data between
preparation and submission. For dormant or windowless operation, use upload or prepare_scene
with no frame open; successful return means the upload completed.

## Shader target

Shaders use Vulkan 1.3 semantics and SPIR-V 1.5. This keeps alpha-mask discard as OpKill without
requiring the optional shaderDemoteToHelperInvocation feature. The texture sampler selects
mips through fragment derivatives; sRGB decoding comes from the texture format.

## Cube and compressed examples

```bash
python3 scripts/build.py --example texture_cube
python3 scripts/build.py --example texture_bc
./examples/build/texture_cube positive_x.png negative_x.png positive_y.png negative_y.png positive_z.png negative_z.png
```

The cube preview selects generated or deliberately supplied mip data with C.
Keys 1–6 select +X, −X, +Y, −Y, +Z, −Z. L switches implicit/explicit LOD, and
+/− change explicit LOD and enable explicit sampling. The terminal prints face,
source, LOD mode and framebuffer dimensions. Resize
below the 256×256 source-face resolution to test implicit minification; compare
actual framebuffer dimensions, not logical window size. Supplied lower mips have
intentionally different colors. Release Escape to quit.

The BC example embeds a 64×64 BC1_RGBA_SRGB image with seven supplied levels.
Their colors are red, green, blue, yellow, magenta, cyan and white. A static
repeated surface extends into the distance so its oblique view selects different
mips. N/L/A select nearest/trilinear/anisotropic filtering; left drag orbits,
wheel zooms, and Escape release quits. It prints format, mip count and the
2744-byte compressed payload size. C switches the material between the hand-built records and the same chain loaded from
`bc1_mips.dds` through `add_texture_container`; both show the same mips. A device without support reports its backend
fault rather than displaying a converted replacement.

Both examples retain CPU sources and use full validation. Their committed
fixtures are project-authored; see [fixture provenance](../csrc/README.md#cube-and-compressed-fixtures).
