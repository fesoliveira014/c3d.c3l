module c3d::material;

<* Faces in one native color cube. *>
const uint CUBE_FACE_COUNT = 6;

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

<*
 Dimensions and format of a texture; owns no pixels.
*>
struct TextureDesc {
    uint        width;
    uint        height;
    uint        depth;
    uint        layers;
    PixelFormat format;
    bool        generate_mips;
    uint        mip_levels;
    bool        is_cube;
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
