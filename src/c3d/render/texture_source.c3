module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import gpu;

<*
 Byte layout of a packed mip chain: one offset per mip, layers consecutive within a mip.
*>
struct TextureMipLayout {
    usz total_bytes;
    uint mip_count;
    uint layer_count;
    usz[material::TEXTURE_MIP_CAPACITY] offsets;
}

<*
 Pack complete supplied mip layers without filtering or conversion.
 @param levels : "Complete slices ordered mip-major, then layer."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
*>
fn TextureMipChain? create_supplied_texture_mips(
    Allocator allocator,
    material::TextureDesc desc,
    TextureMipData[] levels,
) {
    TextureMipLayout layout = supplied_texture_mip_layout(desc, levels)!;
    TextureMipChain chain = {
        .allocator = allocator,
        .mip_count = layout.mip_count,
        .layer_count = layout.layer_count,
        .offsets = layout.offsets,
        .pixels = alloc::new_array(allocator, char, (sz)layout.total_bytes),
    };
    copy_supplied_texture_mips(chain.pixels, levels);
    return chain;
}

<*
 Validate supplied mip layers and compute where each mip lands in one packed staging span.
 @param levels : "Complete slices ordered mip-major, then layer."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
*>
fn TextureMipLayout? supplied_texture_mip_layout(material::TextureDesc desc, TextureMipData[] levels) {
    if (!desc.width || !desc.height || !desc.mip_levels || desc.generate_mips) return c3d::INVALID_ARGUMENT~;
    if (desc.mip_levels > material::texture_mip_count(desc.width, desc.height)) return c3d::INVALID_ARGUMENT~;
    if (desc.depth) return c3d::UNSUPPORTED~;
    if (desc.is_cube) {
        if (desc.layers != material::CUBE_FACE_COUNT || desc.width != desc.height) return c3d::INVALID_ARGUMENT~;
        if (material::texture_is_compressed(desc.format)) return c3d::UNSUPPORTED~;
    } else if (desc.layers != 1) {
        return c3d::UNSUPPORTED~;
    }
    if (!levels.len) return c3d::ASSET_DATA_UNAVAILABLE~;
    if (levels.len != (usz)desc.mip_levels * desc.layers) return c3d::INVALID_ARGUMENT~;

    TextureMipLayout layout = {
        .mip_count = desc.mip_levels,
        .layer_count = desc.layers,
    };
    for (uint mip = 0; mip < desc.mip_levels; mip++) {
        usz layer_bytes = material::texture_mip_bytes(desc, mip)!;
        if (layer_bytes > ((usz)sz::max - layout.total_bytes) / desc.layers) return c3d::INVALID_ARGUMENT~;
        layout.offsets[mip] = layout.total_bytes;
        for (uint layer = 0; layer < desc.layers; layer++) {
            TextureMipData level = levels[(usz)mip * desc.layers + layer];
            if (level.mip != mip || level.layer != layer || level.bytes.len != layer_bytes) {
                return c3d::INVALID_ARGUMENT~;
            }
        }
        layout.total_bytes += layer_bytes * desc.layers;
    }
    return layout;
}

<*
 Copy validated supplied layers into a packed span in layout order.
 @param destination : "At least the layout's total bytes."
 @param levels : "The slices the layout was computed from."
*>
fn void copy_supplied_texture_mips(char[] destination, TextureMipData[] levels) {
    usz offset;
    foreach (level : levels) {
        mem::copy(destination.ptr + offset, level.bytes.ptr, level.bytes.len);
        offset += level.bytes.len;
    }
}

fn gpu::Format texture_format(PixelFormat format) @private {
    switch (format) {
        case RGBA8_UNORM: return gpu::Format.RGBA8_UNORM;
        case RGBA8_SRGB: return gpu::Format.RGBA8_SRGB;
        case RGBA16_FLOAT: return gpu::Format.RGBA16_FLOAT;
        case RGBA32_FLOAT: return gpu::Format.RGBA32_FLOAT;
        case R16_UINT: return gpu::Format.R16_UINT;
        case BC1_RGBA_UNORM: return gpu::Format.BC1_RGBA_UNORM;
        case BC1_RGBA_SRGB: return gpu::Format.BC1_RGBA_SRGB;
        case BC3_UNORM: return gpu::Format.BC3_UNORM;
        case BC3_SRGB: return gpu::Format.BC3_SRGB;
        case BC4_UNORM: return gpu::Format.BC4_UNORM;
        case BC5_UNORM: return gpu::Format.BC5_UNORM;
        case BC6H_UFLOAT: return gpu::Format.BC6H_UFLOAT;
        case BC7_UNORM: return gpu::Format.BC7_UNORM;
        case BC7_SRGB: return gpu::Format.BC7_SRGB;
    }
}
