module c3d::material;

import c3d;

<* Faces in one native color cube. *>
const uint CUBE_FACE_COUNT = 6;

<*
 Maximum mip count for an unsigned 32-bit image extent.
*>
const uint TEXTURE_MIP_CAPACITY = 32;

const uint BLOCK_EXTENT @local = 4;

<* Native cube face order for image paths and layers. *>
enum CubeFace {
    POSITIVE_X,
    NEGATIVE_X,
    POSITIVE_Y,
    NEGATIVE_Y,
    POSITIVE_Z,
    NEGATIVE_Z,
}

<*
 CPU pixel layout of a texture asset; mapped to a device format by the renderer.
*>
enum PixelFormat {
    RGBA8_UNORM,
    RGBA8_SRGB,
    RGBA16_FLOAT,
    RGBA32_FLOAT,
    R16_UINT,
    BC1_RGBA_UNORM,
    BC1_RGBA_SRGB,
    BC3_UNORM,
    BC3_SRGB,
    BC4_UNORM,
    BC5_UNORM,
    BC6H_UFLOAT,
    BC7_UNORM,
    BC7_SRGB,
}

<* Interpretation used when filtering texture vectors. *>
enum TextureSemantic {
    COLOR,
    NORMAL_RGB,
    NORMAL_RG,
}

<* Threshold coverage behavior for generated mip levels. *>
enum CoveragePolicy {
    NONE,
    THRESHOLD,
    ALL_PASS,
    ALL_FAIL,
}

<* Committed coverage counts and exact error; absolute_error is rounded. *>
struct TextureCoverageResult {
    uint revision;
    ulong original_passing;
    ulong original_total;
    ulong passing;
    ulong total;
    uint128 error_numerator;
    uint128 error_denominator;
    double absolute_error;
    bool small_level;
    bool plateau;
}

<*
 Dimensions and format of a texture; owns no pixels.
*>
struct TextureDesc {
    uint        width;
    uint        height;
    uint        depth;
    uint        layers;
    PixelFormat format;
    TextureSemantic semantic;
    CoveragePolicy coverage;
    double      alpha_threshold;
    bool        generate_mips;
    uint        mip_levels;
    bool        is_cube;
    bool        storage;
    ZString     debug_name;
}

<*
 Two-dimensional single-layer description with generated mips.
*>
fn TextureDesc texture_2d_desc(
    uint width,
    uint height,
    PixelFormat format,
    ZString debug_name = "",
) {
    return {
        .width         = width,
        .height        = height,
        .layers        = 1,
        .format        = format,
        .generate_mips = true,
        .mip_levels    = 1,
        .debug_name    = debug_name,
    };
}

<*
 Six square faces with generated mips by default.
*>
fn TextureDesc texture_cube_desc(uint size, PixelFormat format, ZString debug_name = "") {
    TextureDesc desc = texture_2d_desc(
        width: size,
        height: size,
        format: format,
        debug_name: debug_name,
    );
    desc.layers = CUBE_FACE_COUNT;
    desc.is_cube = true;

    return desc;
}

<*
 Single-mip three-dimensional description.
*>
fn TextureDesc texture_3d_desc(
    uint width,
    uint height,
    uint depth,
    PixelFormat format,
    ZString debug_name = "",
) {
    return {
        .width      = width,
        .height     = height,
        .depth      = depth,
        .layers     = 1,
        .format     = format,
        .mip_levels = 1,
        .debug_name = debug_name,
    };
}

<*
 Whether texels are stored as 4x4 blocks.
 @pure
*>
fn bool texture_is_compressed(PixelFormat format) {
    switch (format) {
        case RGBA8_UNORM:
        case RGBA8_SRGB:
        case RGBA16_FLOAT:
        case RGBA32_FLOAT:
        case R16_UINT:
            return false;
        case BC1_RGBA_UNORM:
        case BC1_RGBA_SRGB:
        case BC3_UNORM:
        case BC3_SRGB:
        case BC4_UNORM:
        case BC5_UNORM:
        case BC6H_UFLOAT:
        case BC7_UNORM:
        case BC7_SRGB:
            return true;
    }
}

<*
 Bytes of one block, or of one texel for uncompressed formats.
 @pure
*>
fn usz texture_block_bytes(PixelFormat format) {
    switch (format) {
        case R16_UINT: return 2;
        case RGBA8_UNORM:
        case RGBA8_SRGB: return 4;
        case RGBA16_FLOAT:
        case BC1_RGBA_UNORM:
        case BC1_RGBA_SRGB:
        case BC4_UNORM: return 8;
        case RGBA32_FLOAT:
        case BC3_UNORM:
        case BC3_SRGB:
        case BC5_UNORM:
        case BC6H_UFLOAT:
        case BC7_UNORM:
        case BC7_SRGB: return 16;
    }
}

<*
 Count mip levels down to one texel.
 @require width > 0, height > 0
 @pure
*>
fn uint texture_mip_count(uint width, uint height) {
    uint count = 1;
    for (uint extent = width > height ? width : height; extent > 1; extent >>= 1) count++;

    return count;
}

<*
 Extent of one axis at a mip level, never below one.
 @require mip < TEXTURE_MIP_CAPACITY
 @pure
*>
fn uint texture_mip_extent(uint extent, uint mip) {
    uint reduced = extent >> mip;
    return reduced > 0 ? reduced : 1;
}

<*
 Tight bytes of one layer of a mip, counted in whole blocks.
 @return? c3d::INVALID_ARGUMENT
 @require mip < TEXTURE_MIP_CAPACITY
*>
fn usz? texture_mip_bytes(TextureDesc desc, uint mip) {
    usz block_extent = texture_is_compressed(desc.format) ? BLOCK_EXTENT : 1;
    usz row_blocks = ((usz)texture_mip_extent(desc.width, mip) + block_extent - 1) / block_extent;
    usz block_rows = ((usz)texture_mip_extent(desc.height, mip) + block_extent - 1) / block_extent;
    usz slices = texture_mip_extent(desc.depth > 0 ? desc.depth : 1, mip);
    usz block_bytes = texture_block_bytes(desc.format);
    if (row_blocks > (usz)sz::max / block_rows / slices / block_bytes) return c3d::INVALID_ARGUMENT~;

    return row_blocks * block_rows * slices * block_bytes;
}
