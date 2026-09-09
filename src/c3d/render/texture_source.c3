module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import gpu;

const usz BC_BLOCK_EXTENT @local = 4;

<*
 Pack complete supplied mip layers without filtering or conversion.
 @param levels : "Complete slices ordered mip-major, then layer."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
 @return? gpu::INVALID_ARGUMENT
*>
fn TextureMipChain? create_supplied_texture_mips(
    Allocator allocator,
    material::TextureDesc desc,
    TextureMipData[] levels,
) {
    if (!desc.width || !desc.height || !desc.mip_levels || desc.generate_mips) return c3d::INVALID_ARGUMENT~;
    if (desc.mip_levels > texture_mip_count(desc.width, desc.height)) return c3d::INVALID_ARGUMENT~;
    if (desc.depth) return c3d::UNSUPPORTED~;
    if (desc.is_cube) {
        if (desc.layers != material::CUBE_FACE_COUNT || desc.width != desc.height) return c3d::INVALID_ARGUMENT~;
        if (texture_is_compressed(desc.format)) return c3d::UNSUPPORTED~;
    } else if (desc.layers != 1) {
        return c3d::UNSUPPORTED~;
    }
    if (!levels.len) return c3d::ASSET_DATA_UNAVAILABLE~;
    if (levels.len != (usz)desc.mip_levels * desc.layers) return c3d::INVALID_ARGUMENT~;

    gpu::TextureDesc description = {
        .width = desc.width,
        .height = desc.height,
        .mip_levels = desc.mip_levels,
        .array_layers = desc.layers,
        .format = texture_format(desc.format),
    };
    gpu::TextureDesc unit_description = {
        .width = 1,
        .height = 1,
        .mip_levels = 1,
        .array_layers = 1,
        .format = description.format,
    };
    usz unit_bytes = gpu::texture_mip_bytes(&unit_description, 0)!;
    usz unit_extent = texture_is_compressed(desc.format) ? BC_BLOCK_EXTENT : 1;
    usz row_units = ((usz)desc.width - 1) / unit_extent + 1;
    usz block_rows = ((usz)desc.height - 1) / unit_extent + 1;
    // The backend footprint helper multiplies without overflow checks.
    if (row_units > (usz)sz::max / block_rows / unit_bytes / desc.layers) return c3d::INVALID_ARGUMENT~;

    TextureMipChain chain = {
        .allocator = allocator,
        .mip_count = desc.mip_levels,
        .layer_count = desc.layers,
    };
    usz total_bytes;
    for (uint mip = 0; mip < desc.mip_levels; mip++) {
        usz layer_bytes = gpu::texture_mip_bytes(&description, mip)!;
        if (layer_bytes > ((usz)sz::max - total_bytes) / desc.layers) return c3d::INVALID_ARGUMENT~;
        chain.offsets[mip] = total_bytes;
        for (uint layer = 0; layer < desc.layers; layer++) {
            TextureMipData level = levels[(usz)mip * desc.layers + layer];
            if (level.mip != mip || level.layer != layer || level.bytes.len != layer_bytes) {
                return c3d::INVALID_ARGUMENT~;
            }
        }
        total_bytes += layer_bytes * desc.layers;
    }

    chain.pixels = alloc::new_array(allocator, char, (sz)total_bytes);
    usz offset;
    foreach (level : levels) {
        mem::copy(chain.pixels.ptr + offset, level.bytes.ptr, level.bytes.len);
        offset += level.bytes.len;
    }

    return chain;
}

fn bool texture_is_compressed(PixelFormat format) @private {
    switch (format) {
        case RGBA8_UNORM:
        case RGBA8_SRGB:
        case RGBA16_FLOAT:
        case RGBA32_FLOAT:
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

fn gpu::Format texture_format(PixelFormat format) @private {
    switch (format) {
        case RGBA8_UNORM: return gpu::Format.RGBA8_UNORM;
        case RGBA8_SRGB: return gpu::Format.RGBA8_SRGB;
        case RGBA16_FLOAT: return gpu::Format.RGBA16_FLOAT;
        case RGBA32_FLOAT: return gpu::Format.RGBA32_FLOAT;
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
