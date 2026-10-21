# Textures and images

A texture asset holds the CPU pixels of an image, or the mip levels of a supplied chain, in the `AssetStore`. A material
slot selects a texture, a sampler, a UV set and a UV transform. The renderer owns the uploaded images: it builds mip
chains or uploads supplied levels unchanged. Loaders live in `c3d::asset::image`; descriptors, slots and formats live in
`c3d::material`. Compressed containers, supplied mips and the container format tables are in the
[textures reference](textures_reference.md). Region edits, replacement and residency budgets are in
[texture streaming](texture_streaming.md).

## Quick start

Import `c3d`, `c3d::asset`, `c3d::asset::image` and `c3d::material`. Given a live `AssetStore assets`:

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

`texture_slot(texture)` selects UV0, the builtin trilinear repeat sampler and an identity transform. Basic shading
multiplies its color by the sampled map. The renderer uploads the texture the first time a drawn material references it.
Upload earlier with [`renderer.upload(texture)`](#upload-edit-and-release-cpu-sources).

## Concepts

- **Asset and device copy.** A `TextureAsset` owns the CPU source: mip-zero pixels (`MIP_ZERO`), a supplied chain
  (`SUPPLIED_MIPS`) or nothing for an empty storage texture (`EMPTY`). Each renderer keeps its own GPU image, uploaded
  from the source. The source can be released after upload.
- **Rows and color space.** Decoded images and cube faces keep the top row first; no loader flips rows or changes global
  decoder settings. `srgb: true` stores `RGBA8_SRGB` and `false` stores `RGBA8_UNORM` without rewriting the decoded bytes,
  and sRGB decoding comes from the texture format. Mips filter sRGB color in linear light and alpha linearly.
- **Mips.** `texture_2d_desc` requests a full generated chain; odd edges contribute, floating-point channels filter without
  clamping, and each cube face filters independently. Disable `desc.generate_mips` for mip zero alone, or supply every level
  ([supplied mips](textures_reference.md#supply-mip-levels)); supplied levels are never regenerated.
- **Samplers.** The material slot selects the sampler, so materials can share a texture with different filtering. Builtin
  ids: `asset::SAMPLER_NEAREST`, `SAMPLER_LINEAR_REPEAT`, `SAMPLER_LINEAR_CLAMP`, `SAMPLER_ANISOTROPIC` (clamped to the
  device limit) and `SAMPLER_SHADOW` (a comparison sampler for shadow reads). A comparison sampler in a material slot faults
  `c3d::INVALID_ARGUMENT`. Builtin texture and sampler ids live
  for the store lifetime and cannot be replaced or removed; their CPU pixels can still be released after preparation.

### Pixel formats

| Format | Use |
| --- | --- |
| `RGBA8_UNORM`, `RGBA8_SRGB` | Eight-bit color and data; the PNG and JPEG loaders produce these |
| `RGBA16_FLOAT`, `RGBA32_FLOAT` | Floating-point data; Radiance HDR produces `RGBA32_FLOAT` |
| `R16_UINT` | One unsigned 16-bit integer per texel, such as heights; no generated mips, integer fetch only |
| `BC1_RGBA_*`, `BC3_*`, `BC4_UNORM`, `BC5_UNORM`, `BC6H_UFLOAT`, `BC7_*` | Block-compressed 2D textures, supplied with their mips |

Two-dimensional textures take every format. Cubes are uncompressed, and volumes are single-mip RGBA8. A slot that is
empty, dead or stale uses that slot's
scalar or unperturbed-normal fallback; a dead sampler uses builtin trilinear repeat.

## Load a color map

`load_texture` decodes a PNG or JPEG file into four eight-bit channels. A JPEG's missing alpha becomes 255.

```c3
TextureId color = image::load_texture(&assets, "albedo.png", true)!;   // srgb color map
TextureId mask = image::load_texture(&assets, "mask.png", false)!;     // linear data
```

Choose `srgb: true` for color maps and `false` for linear data such as masks. `load_texture` rejects Radiance HDR
files with `c3d::ASSET_FORMAT_ERROR`.

### Standard material maps

| Slot | `srgb` | Channels |
| --- | --- | --- |
| Base color | `true` | RGBA multiplies the base factor |
| Emissive | `true` | RGB multiplies the emission |
| Metallic and roughness | `false` | G multiplies roughness, B multiplies metallic |
| Occlusion | `false` | R controls ambient occlusion |
| Normal | `false`, with `semantic` | Tangent-space XYZ |

A packed R, G and B image serves occlusion and metallic-roughness through two slots that share one texture asset. Start
from `STANDARD_PARAMS_DEFAULT`: every slot is absent with identity coordinates, and normal scale and occlusion strength
are 1. Normal scale is finite and signed; occlusion strength is in `[0, 1]`. A missing or stale id keeps the scalar
factors and the geometry normal.

### Load a normal map

Pass `TextureSemantic.NORMAL_RGB` or `NORMAL_RG` so generated mips filter and renormalize the decoded vectors:

```c3
TextureId normals = image::load_texture(
    assets: &assets,
    path: "normal.png",
    srgb: false,
    semantic: TextureSemantic.NORMAL_RGB,
)!;
```

`NORMAL_RG` reconstructs positive Z. Both semantics need a linear format; an sRGB format faults
`c3d::INVALID_ARGUMENT` and `R16_UINT` faults `c3d::UNSUPPORTED`. A zero decoded vector becomes neutral +Z. The container
loaders take the same `semantic` argument and leave supplied texels unchanged. For supplied tangents and the derivative
fallback, see [tangent frames](materials_reference.md#tangent-frames).

## Load HDR data

```c3
TextureId environment_pixels = image::load_hdr(&assets, "studio.hdr")!;
```

`load_hdr` accepts Radiance HDR and stores tightly packed four-channel floats (`RGBA32_FLOAT`), keeping values above
one. It rejects PNG and JPEG with
`c3d::ASSET_FORMAT_ERROR`. Loading does not tone map. Register the texture with `light::texture_environment` and
`assets.add_environment` for [image-based lighting or a sky](environments.md).

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

- `CubeFace` names the order: `POSITIVE_X`, `NEGATIVE_X`, `POSITIVE_Y`, `NEGATIVE_Y`, `POSITIVE_Z`, `NEGATIVE_Z`.
- Every path is nonempty. Every face is square, the same size and the same decoded format. PNG and JPEG faces can mix.
  Six HDR files produce `RGBA32_FLOAT` whatever `srgb` says; mixing HDR and byte faces faults
  `c3d::ASSET_FORMAT_ERROR`.
- A failed load or insertion releases every partial face allocation.
- Faces stay top row first. No rotation, flip or filename convention applies, so supply the native cube orientation.
  With `s = 2u - 1` and `t = 2v - 1`, image coordinates increasing right and down, a face samples this direction:

| Face | Direction | Face | Direction |
| --- | --- | --- | --- |
| +X | `(1, -t, -s)` | -X | `(-1, -t, s)` |
| +Y | `(s, 1, t)` | -Y | `(s, -1, -t)` |
| +Z | `(s, -t, 1)` | -Z | `(-s, -t, -1)` |

`texture_cube_desc(size, format)` describes six square layers with generated mips; mip zero holds complete faces in the
order above. A cube is a sampled cube view for environments and previews. Register it as an
[environment source](environments.md) to light a scene or draw a sky; environment processing borrows the native cube and
skips equirectangular conversion. Basic and Standard material slots stay 2D.

## Sixteen-bit single-channel data

`R16_UINT` holds one unsigned 16-bit integer per texel. Load one from a PNG or JPEG:

```c3
TextureId heights = image::load_texture_r16(&assets, "heights.png")!;
```

- The result is a single-mip, linear texture with the top row first and texels in native byte order.
  `decode_image_r16` returns the same data as an `Image` without inserting it.
- A 16-bit PNG keeps all 16 bits. An 8-bit PNG or JPEG widens exactly as `v * 257`, so 255 becomes 65535, and color
  reduces to luminance. Radiance input faults `c3d::ASSET_FORMAT_ERROR`.
- For raw heights, pass native-order `ushort` texels to `add_texture` with an `R16_UINT` description and
  `generate_mips` disabled. An `R16_UINT` description with generated mips or storage faults `c3d::INVALID_ARGUMENT`.
- Heights follow `offset + scale * texel / 65535`, beside the 8-bit `texel / 255`. A physics height field reads an
  `R16_UINT` texture with the same convention: its node's position and `local.scale.y` supply the offset and scale.

Shaders read the texture only through gpu.c3l's integer fetch, never through a sampler, so filtering is manual.
`texture_fetch.glsl` includes it:

```glsl
uint height = gpu_fetch_uint(material.slots[0].texture_index, texel, 0);
```

A custom material can hold an `R16_UINT` texture in any slot except slot 0 of a masked material. A dispatch reads it
through a `read_texture` entry. A Basic, Standard, Physical or Toon map, a Toon gradient map, and slot 0 of a masked
custom material fault `c3d::UNSUPPORTED` when the material uploads or draws. `R16_UINT` is not a storage, render target,
volume or environment source format.

## Decode from memory

`decode_image(allocator, bytes)` decodes embedded or already loaded PNG, JPEG or Radiance HDR bytes into an owned `Image`;
`load_image(allocator, path, file_source = {})` does the same from a file. `add_texture` copies the pixels, so destroying
the image does not invalidate the texture. To skip the copy, decode with `assets.allocator` and transfer the slice:

```c3
image::Image decoded = image::decode_image(assets.allocator, encoded_bytes)!;
defer image::destroy_image(&decoded);

TextureId texture = assets.add_texture_owned(
    material::texture_2d_desc(decoded.width, decoded.height, decoded.format),
    decoded.pixels,
)!;
decoded.pixels = {};
```

Clear the image's slice only after insertion succeeds; on a fault the image still owns its allocation. For a color PNG or
JPEG pass `RGBA8_SRGB` as the format when the bytes represent sRGB color. Keys follow the store's uniqueness policy and are
never replaced. `load_texture`, `load_hdr`, `load_cube`, `load_texture_r16` and `load_texture_container` read through the
store's file source; a null source reads the file system ([file sources](assets.md#file-sources)).

## Write a PNG

`image::write_png(path, width, height, pixels)` encodes tightly packed RGBA8 rows, top row first, and writes the bytes
unchanged with no color-space chunk. Pass sRGB-encoded bytes for color, such as a `read_render_target` copy of an
`RGBA8_SRGB` target ([read a target back](views.md#read-a-target-back)). A zero extent or a buffer that is not
`width * height * 4` bytes faults `c3d::INVALID_ARGUMENT`; an unwritable file faults `c3d::ASSET_IO_ERROR`. The encoder is C3
and needs no native source.

## Load compressed containers

`load_texture_container` reads a DDS, KTX 1.1 or KTX 2.0 file and inserts its levels unchanged. `add_texture_container`
does the same for bytes already in memory, such as an `$embed`:

```c3
TextureId albedo = image::load_texture_container(
    assets:      &assets,
    path:        "albedo_bc7.ktx2",
    color_space: SRGB,
    key:         "example/albedo",
)!;
renderer.upload(albedo)!;
```

The container sets the format, extent and level count, and nothing is decoded, re-encoded, flipped or regenerated. The
store allocator must not be `tmem`. `color_space` is `FROM_FILE` (default), `SRGB` or `LINEAR`. The
[reference](textures_reference.md#load-dds-and-ktx-containers) lists the supported formats, the rejected files and the
faults. A device without support for a format reports the backend fault, such as `gpu::UNSUPPORTED_FEATURE`, at upload;
there is no uncompressed fallback.

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

- UV set 0 selects `Geometry.uv0` and 1 selects `Geometry.uv1`. Supply the chosen stream on the geometry. A set above 1
  faults `c3d::INVALID_ARGUMENT`.
- A transform scales, rotates about the UV origin in radians, then translates. It never modifies shared geometry.
- Each Standard slot applies its own coordinates. A normal-map transform changes a derivative frame but does not rotate
  an explicitly supplied tangent basis.
- A zero-initialized transform has zero scale, not identity. Use `texture_slot` or `UV_TRANSFORM_IDENTITY`.
- Mark the material dirty after changing a slot or color.

For a cutout, start from `material::MATERIAL_COMMON_DEFAULT`, set `common.alpha_mode = MASK` and pass `common` as the
second argument of `material::basic` or `material::standard`. The sampled alpha times the color alpha is compared with
`common.alpha_cutoff` (default 0.5). Discarded fragments leave the geometry behind visible. For blended alpha see
[transparency](transparency.md).

## Generated alpha coverage

Minifying an alpha-tested texture shrinks its cutout unless the mips preserve coverage. `TextureDesc.coverage` defaults to
`NONE`. `THRESHOLD` preserves the fraction of texels that pass `alpha_threshold`; `ALL_PASS` and `ALL_FAIL` describe
constant coverage.

- The threshold is finite and in `(0, 1]`, else `c3d::INVALID_ARGUMENT`. Alpha outside `[0, 1]` faults the same way on
  insertion, replacement and generation after an in-place edit.
- Coverage applies only to uncompressed generated color mips of a 2D texture or a cube with `mip_levels` 1. A supplied
  chain, a compressed format, `R16_UINT`, a volume or a storage texture faults `c3d::UNSUPPORTED`.
- A generated level (per cube face) whose passing fraction is within 0.02 of that face's mip zero keeps its filtered alpha.
  Otherwise its alpha is rescaled about the threshold so the passing count is the nearest achievable. Color channels are
  unchanged.
- Mip zero's passing count is taken while the first level filters. `mark_texture_dirty` advances the revision and
  `restore_texture_cpu` keeps it, so call `mark_texture_dirty` after restoring different pixels.

## Upload, edit and release CPU sources

Outside an open frame, `renderer.upload(texture)` uploads the texture and returns when the work completes. Inside an open
frame it records the upload for that frame's submission, which needs a drawable window output and no open overlay and must
precede the views that sample the texture. `renderer.prepare_scene(&scene)` prepares every resource the scene references
([preparation](preparation.md)). Both work on a renderer created without a surface. Finish asset and material edits before
preparation, and do not edit or release source data between preparation and submission.

```c3
renderer.upload(texture)!;
assets.release_texture_cpu(texture);
```

- **Release** is explicit. It frees the selected source and clears its slices, keeping the id, description, revision and
  source kind. An image this renderer already uploaded stays usable. A second renderer, a changed backing image or another
  upload that needs the absent bytes faults `c3d::ASSET_DATA_UNAVAILABLE`, so keep the source of a texture you will edit or
  upload into another renderer. `restore_texture_cpu(texture, pixels)` gives a released `MIP_ZERO` texture its pixels again
  and takes ownership of them.
- **Edit** mip zero while the pixels remain, then advance the revision. The renderer regenerates generated mips on upload.
  A texture edit needs no material edit, for every Standard slot and shared image; sampler revisions and replacement
  images refresh the resolved bindings the same way. A removed texture whose index is reused leaves old ids absent.
- **Supplied data** is edited in the retained bytes (`TextureAsset.supplied_mips[level].bytes`), then marked dirty. Compressed
  edits keep complete valid blocks.

```c3
TextureAsset* source = assets.texture(texture);
source.pixels[0] = 255;
assets.mark_texture_dirty(texture);
renderer.upload(texture)!;
```

To upload only the changed texels, to change dimensions, format or mip count, or to bound memory, see
[texture streaming](texture_streaming.md).

## Faults

| Fault | Cause |
| --- | --- |
| `c3d::ASSET_IO_ERROR` | A file cannot be read or written |
| `c3d::ASSET_FORMAT_ERROR` | Malformed image data, a loader given the wrong kind (PNG to `load_hdr`, HDR to `load_texture`), mismatched cube faces |
| `c3d::INVALID_ARGUMENT` | Empty data or data over `int::max` bytes, a duplicate key, malformed cube or mip metadata, a bad coverage threshold, sRGB with a normal semantic, `R16_UINT` with generated mips or storage |
| `c3d::UNSUPPORTED` | An unsupported texture form: coverage on a supplied or compressed chain, `R16_UINT` or a cube in a built-in slot, an `R16_UINT` volume, render target or environment source |
| `c3d::CAPACITY_EXCEEDED` | The texture pool is full |
| `c3d::ASSET_DATA_UNAVAILABLE` | An upload or insertion needs pixels that are absent |
| `c3d::INVALID_ID` | A dead texture id at an entry point |

Paths are nonempty (a contract, not a fault). GPU upload faults propagate unchanged. Container, region and replacement
faults are in the
[reference](textures_reference.md#container-faults) and [streaming](texture_streaming.md#replacing-a-texture) pages.

## Limits

- Texture shapes: 2D, cube (six uncompressed layers) and single-mip RGBA8 volumes such as LUTs. Non-cube arrays and
  compressed cubes fault `c3d::UNSUPPORTED` at upload. A live cube in any Basic or Standard slot faults
  `c3d::UNSUPPORTED`.
- No comparison samplers in material slots.
- No texture compression, transcoding or mip generation for block formats; supply every level.
- No separate decoder package. stb_image is vendored in `csrc/` and compiled with the package; see
  [native libraries](development.md#native-libraries).
- Texture loading does not tone map or convert range between HDR and byte formats.

## See also

- [Textures reference](textures_reference.md) for supplied mips, compressed formats and containers.
- [Texture streaming](texture_streaming.md) for region edits, replacement and residency budgets.
- [Materials](materials.md) and [materials reference](materials_reference.md) for slots and tangent frames.
- [Environments](environments.md) for HDR and cube sources.
- [Preparation](preparation.md) for budgeted initial uploads.
- Examples: `textured` (UV and sampler controls), `pbr` (Standard maps), `texture_cube`, `texture_bc` and `streaming`; run with
  `python3 scripts/build.py --example <name>`.
