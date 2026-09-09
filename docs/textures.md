# Textures and images

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

## HDR data and mip filtering

```c3
TextureId environment_pixels = image::load_hdr(&assets, "studio.hdr")!;
```

`load_hdr` accepts Radiance HDR and stores `RGBA32_FLOAT`, retaining values above
one. Its pixel slice contains tightly packed four-channel floats. It rejects
PNG/JPEG rather than implicitly converting their range. Conversely,
`load_texture` rejects HDR. Decoding HDR does not add an environment renderer or
a display tonemapping pipeline.

Two-dimensional uploads support `RGBA8_UNORM`, `RGBA8_SRGB`, `RGBA16_FLOAT` and
`RGBA32_FLOAT`. `texture_2d_desc` requests a complete mip chain by default. Mips
filter sRGB RGB channels in linear light, alpha linearly, and floating-point
channels without clamping their range. Odd edges contribute to the filtered
result. Disable `desc.generate_mips` for mip zero alone. Uncompressed cube textures
use the same formats and filter each face independently. Supplied levels, including
compressed ones, use the copying API below and are never regenerated.

Builtin sampler ids are `asset::SAMPLER_NEAREST`,
`asset::SAMPLER_LINEAR_REPEAT`, `asset::SAMPLER_LINEAR_CLAMP` and
`asset::SAMPLER_ANISOTROPIC`. The renderer clamps requested anisotropy to device
limits. Sampler choice lives on the material slot, so several materials can use
the same texture with different filtering. Builtin texture and sampler ids are reserved
for the store lifetime; removal applies to custom assets. Their CPU pixels may still be
released after preparation.

A zero or stale map reference uses the color-only fallback; a zero or stale sampler
reference selects builtin trilinear repeat. A live cube reference in `Basic.map`
reports `c3d::UNSUPPORTED`; cube views use a different sampled-image heap.
Render-target references, non-cube arrays and volumes remain unsupported.

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
that view by direction; Basic materials remain 2D. This API does not add a scene
skybox, image-based lighting, or environment prefiltering.

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
transcoder, mip generator, DDS parser or KTX parser runs on them. Unsupported
device format support propagates the backend fault, including
`gpu::UNSUPPORTED_FEATURE`; there is no automatic uncompressed fallback.
Compressed cubes, cube arrays, non-cube arrays and volumes are unsupported.

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
material dirty after changing its slot or color. Use `texture_slot` for identity defaults:
a manually zero-initialized transform has zero scale, not identity.

For a cutout, start with `material::MATERIAL_COMMON_DEFAULT`, set
`common.alpha_mode = MASK` and pass `common` as the second argument to
`material::basic`. The fragment's sampled alpha multiplied by the material's
color alpha is compared with `common.alpha_cutoff`, which defaults to 0.5.
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
for an edit to the referenced texture. Replacing dimensions or format requires
complete matching CPU bytes before marking the texture dirty.

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
`c3d::ASSET_FORMAT_ERROR`. Empty encoded data or data exceeding the native
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

The package vendors stb_image and compiles one C translation unit with c3c's
selected C compiler during ordinary builds. Follow the repository's
[prerequisites and native dependency setup](../README.md#prerequisites).
The current package still requires its declared GPU, SDL3, ImGui, geometry and
physics dependencies. `C3D_STB_IMAGE` is an indicator: omitting it does not remove
the image API or native decoder compilation. Native package isolation remains
deferred; there is no separate decoder package.

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
2744-byte compressed payload size. A device without support reports its backend
fault rather than displaying a converted replacement.

Both examples retain CPU sources and use full validation. Their committed
fixtures are project-authored; see [fixture provenance](../csrc/README.md#cube-and-compressed-fixtures).
