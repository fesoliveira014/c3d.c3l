module c3d::asset::image;

import c3d;
import c3d::asset;
import c3d::material;
import std::io::file;

const int IMAGE_CHANNELS @local = 4;

<*
 Decoded RGBA pixels owned by one allocator.
*>
struct Image {
    Allocator allocator;
    uint width;
    uint height;
    PixelFormat format;
    char[] pixels;
}

extern fn char* load_from_memory(
    char* bytes,
    int length,
    int* width,
    int* height,
    int* channels,
    int desired_channels,
) @cname("stbi_load_from_memory") @local;

extern fn float* loadf_from_memory(
    char* bytes,
    int length,
    int* width,
    int* height,
    int* channels,
    int desired_channels,
) @cname("stbi_loadf_from_memory") @local;

extern fn int is_hdr_from_memory(char* bytes, int length) @cname("stbi_is_hdr_from_memory") @local;
extern fn void image_free(void* pixels) @cname("stbi_image_free") @local;

<*
 Decode encoded image bytes without changing row order.
 @param bytes : "Borrowed PNG, JPEG or Radiance HDR data."
 @return? c3d::INVALID_ARGUMENT, c3d::ASSET_FORMAT_ERROR
*>
fn Image? decode_image(Allocator allocator, char[] bytes) {
    if (!bytes.len || bytes.len > int::max) return c3d::INVALID_ARGUMENT~;

    int width;
    int height;
    int channels;
    bool hdr = is_hdr_from_memory(bytes.ptr, (int)bytes.len) != 0;
    void* decoded;
    if (hdr) {
        decoded = loadf_from_memory(
            bytes: bytes.ptr,
            length: (int)bytes.len,
            width: &width,
            height: &height,
            channels: &channels,
            desired_channels: IMAGE_CHANNELS,
        );
    } else {
        decoded = load_from_memory(
            bytes: bytes.ptr,
            length: (int)bytes.len,
            width: &width,
            height: &height,
            channels: &channels,
            desired_channels: IMAGE_CHANNELS,
        );
    }

    if (!decoded) return c3d::ASSET_FORMAT_ERROR~;
    defer image_free(decoded);

    usz byte_count = (usz)width * (usz)height * (usz)IMAGE_CHANNELS * (hdr ? float::size : char::size);
    char[] pixels = alloc::new_array(allocator, char, (sz)byte_count);
    mem::copy(pixels.ptr, decoded, (sz)byte_count);

    return {
        .allocator = allocator,
        .width = (uint)width,
        .height = (uint)height,
        .format = hdr ? RGBA32_FLOAT : RGBA8_UNORM,
        .pixels = pixels,
    };
}

<*
 Read and decode an image into owned RGBA pixels.
 @return? c3d::ASSET_IO_ERROR, c3d::INVALID_ARGUMENT, c3d::ASSET_FORMAT_ERROR
 @require path.len > 0
*>
fn Image? load_image(Allocator allocator, String path) {
    char[] bytes;
    if (try loaded = file::load(mem, path)) {
        bytes = loaded;
    } else {
        return c3d::ASSET_IO_ERROR~;
    }
    defer free(bytes.ptr);

    return decode_image(allocator, bytes);
}

<*
 Release decoded pixels and clear their owner.
 @param [&inout] image : "Live image; cleared after release."
*>
fn void destroy_image(Image* image) {
    alloc::free(image.allocator, image.pixels.ptr);
    *image = {};
}

<*
 Load an eight-bit image into the store's texture pool.
 @param [&inout] assets : "Owns transferred pixels on successful insertion."
 @param srgb : "Interpret RGB as sRGB color."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ARGUMENT
 @return? c3d::CAPACITY_EXCEEDED
 @require path.len > 0
*>
fn TextureId? load_texture(
    AssetStore* assets,
    String path,
    bool srgb,
    String key = "",
) {
    Image decoded = load_image(assets.allocator, path)!;
    defer destroy_image(&decoded);

    if (decoded.format != RGBA8_UNORM) return c3d::ASSET_FORMAT_ERROR~;

    material::TextureDesc desc = material::texture_2d_desc(
        width: decoded.width,
        height: decoded.height,
        format: srgb ? RGBA8_SRGB : RGBA8_UNORM,
        debug_name: "image_texture",
    );
    TextureId texture = assets.add_texture_owned(desc, decoded.pixels, key)!;
    decoded.pixels = {};

    return texture;
}

<*
 Load a Radiance image into an RGBA32_FLOAT texture.
 @param [&inout] assets : "Owns transferred pixels on successful insertion."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ARGUMENT
 @return? c3d::CAPACITY_EXCEEDED
 @require path.len > 0
*>
fn TextureId? load_hdr(AssetStore* assets, String path, String key = "") {
    Image decoded = load_image(assets.allocator, path)!;
    defer destroy_image(&decoded);

    if (decoded.format != RGBA32_FLOAT) return c3d::ASSET_FORMAT_ERROR~;

    material::TextureDesc desc = material::texture_2d_desc(
        width: decoded.width,
        height: decoded.height,
        format: RGBA32_FLOAT,
        debug_name: "hdr_texture",
    );
    TextureId texture = assets.add_texture_owned(desc, decoded.pixels, key)!;
    decoded.pixels = {};

    return texture;
}

<*
 Load six square faces into one cube texture asset.
 @param [&inout] assets : "Owns the combined face pixels on success."
 @param paths : "Nonempty +X, -X, +Y, -Y, +Z, -Z paths."
 @param srgb : "Interpret byte faces as sRGB; HDR remains linear."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require paths[0].len > 0, paths[1].len > 0, paths[2].len > 0
 @require paths[3].len > 0, paths[4].len > 0, paths[5].len > 0
*>
fn TextureId? load_cube(
    AssetStore* assets,
    String[material::CUBE_FACE_COUNT] paths,
    bool srgb,
    String key = "",
) {
    Image first = load_image(assets.allocator, paths[0])!;
    defer destroy_image(&first);

    if (first.width != first.height) return c3d::ASSET_FORMAT_ERROR~;
    if (first.pixels.len > (usz)sz::max / material::CUBE_FACE_COUNT) return c3d::INVALID_ARGUMENT~;

    char[] pixels = alloc::new_array(assets.allocator, char, (sz)(first.pixels.len * material::CUBE_FACE_COUNT));
    defer catch alloc::free(assets.allocator, pixels.ptr);

    mem::copy(pixels.ptr, first.pixels.ptr, first.pixels.len);
    for (uint face = 1; face < material::CUBE_FACE_COUNT; face++) {
        Image decoded = load_image(assets.allocator, paths[face])!;
        defer destroy_image(&decoded);

        if (decoded.width != first.width || decoded.height != first.height || decoded.format != first.format) {
            return c3d::ASSET_FORMAT_ERROR~;
        }
        mem::copy(pixels.ptr + face * first.pixels.len, decoded.pixels.ptr, first.pixels.len);
    }

    PixelFormat format = first.format == RGBA32_FLOAT ? RGBA32_FLOAT : (srgb ? RGBA8_SRGB : RGBA8_UNORM);
    material::TextureDesc desc = material::texture_cube_desc(first.width, format, "cube_texture");
    return assets.add_texture_owned(desc, pixels, key);
}
