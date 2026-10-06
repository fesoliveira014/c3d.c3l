module c3d::asset::image;

import c3d;

const usz DDS_HEADER_END @local = 128;
const usz DDS_DX10_HEADER_END @local = 148;
const uint DDS_HEADER_SIZE @local = 124;
const uint DDS_PIXEL_FORMAT_SIZE @local = 32;
const usz DDS_SIZE_OFFSET @local = 4;
const usz DDS_HEIGHT_OFFSET @local = 12;
const usz DDS_WIDTH_OFFSET @local = 16;
const usz DDS_DEPTH_OFFSET @local = 24;
const usz DDS_MIP_COUNT_OFFSET @local = 28;
const usz DDS_PIXEL_FORMAT_SIZE_OFFSET @local = 76;
const usz DDS_PIXEL_FORMAT_FLAGS_OFFSET @local = 80;
const usz DDS_FOUR_CC_OFFSET @local = 84;
const usz DDS_BIT_COUNT_OFFSET @local = 88;
const usz DDS_RED_MASK_OFFSET @local = 92;
const usz DDS_GREEN_MASK_OFFSET @local = 96;
const usz DDS_BLUE_MASK_OFFSET @local = 100;
const usz DDS_ALPHA_MASK_OFFSET @local = 104;
const usz DDS_CAPS2_OFFSET @local = 112;
const usz DX10_FORMAT_OFFSET @local = 128;
const usz DX10_DIMENSION_OFFSET @local = 132;
const usz DX10_MISC_FLAG_OFFSET @local = 136;
const usz DX10_ARRAY_SIZE_OFFSET @local = 140;
const usz DX10_MISC_FLAGS2_OFFSET @local = 144;
const usz FOUR_CC_BYTES @local = 4;
const uint DDPF_FOURCC @local = 0x4;
const uint DDPF_RGB @local = 0x40;
const uint DDSCAPS2_CUBEMAP @local = 0x200;
const uint DDSCAPS2_VOLUME @local = 0x200000;
const uint RGBA8_BIT_COUNT @local = 32;
const uint RED_BYTE_MASK @local = 0x000000FF;
const uint GREEN_BYTE_MASK @local = 0x0000FF00;
const uint BLUE_BYTE_MASK @local = 0x00FF0000;
const uint ALPHA_BYTE_MASK @local = 0xFF000000;
const uint D3DFMT_A16B16G16R16F @local = 113;
const uint D3DFMT_A32B32G32R32F @local = 116;
const uint D3D10_RESOURCE_DIMENSION_TEXTURE2D @local = 3;
const uint D3D10_RESOURCE_MISC_TEXTURECUBE @local = 0x4;
const uint DDS_ALPHA_MODE_MASK @local = 0x7;
const uint DDS_ALPHA_MODE_PREMULTIPLIED @local = 2;
const uint DXGI_FORMAT_R32G32B32A32_FLOAT @local = 2;
const uint DXGI_FORMAT_R16G16B16A16_FLOAT @local = 10;
const uint DXGI_FORMAT_R8G8B8A8_UNORM @local = 28;
const uint DXGI_FORMAT_R8G8B8A8_UNORM_SRGB @local = 29;
const uint DXGI_FORMAT_R16_UINT @local = 57;
const uint DXGI_FORMAT_BC1_UNORM @local = 71;
const uint DXGI_FORMAT_BC1_UNORM_SRGB @local = 72;
const uint DXGI_FORMAT_BC3_UNORM @local = 77;
const uint DXGI_FORMAT_BC3_UNORM_SRGB @local = 78;
const uint DXGI_FORMAT_BC4_UNORM @local = 80;
const uint DXGI_FORMAT_BC5_UNORM @local = 83;
const uint DXGI_FORMAT_BC6H_UF16 @local = 95;
const uint DXGI_FORMAT_BC7_UNORM @local = 98;
const uint DXGI_FORMAT_BC7_UNORM_SRGB @local = 99;

fn ContainerLayout? parse_dds_layout(char[] bytes) @private {
    if (bytes.len < DDS_HEADER_END) return c3d::ASSET_FORMAT_ERROR~;
    if (read_u32(bytes, DDS_SIZE_OFFSET) != DDS_HEADER_SIZE) return c3d::ASSET_FORMAT_ERROR~;
    if (read_u32(bytes, DDS_PIXEL_FORMAT_SIZE_OFFSET) != DDS_PIXEL_FORMAT_SIZE) return c3d::ASSET_FORMAT_ERROR~;

    PixelFormat format;
    usz data_offset = DDS_HEADER_END;
    if (four_cc_is(bytes, "DX10")) {
        if (bytes.len < DDS_DX10_HEADER_END) return c3d::ASSET_FORMAT_ERROR~;
        format = dx10_format(bytes)!;
        data_offset = DDS_DX10_HEADER_END;
    } else {
        format = legacy_format(bytes)!;
    }
    if (read_u32(bytes, DDS_CAPS2_OFFSET) & (DDSCAPS2_CUBEMAP | DDSCAPS2_VOLUME)) return c3d::UNSUPPORTED~;
    if (read_u32(bytes, DDS_DEPTH_OFFSET) > 1) return c3d::UNSUPPORTED~;

    uint level_count = read_u32(bytes, DDS_MIP_COUNT_OFFSET);
    if (level_count == 0) level_count = 1;
    return {
        .desc = container_desc(
            width:       read_u32(bytes, DDS_WIDTH_OFFSET),
            height:      read_u32(bytes, DDS_HEIGHT_OFFSET),
            format:      format,
            level_count: level_count,
        ),
        .level_count = level_count,
        .contiguous = true,
        .data_offset = data_offset,
        .row_alignment = 1,
    };
}

fn bool four_cc_is(char[] bytes, String code) @local {
    if ((read_u32(bytes, DDS_PIXEL_FORMAT_FLAGS_OFFSET) & DDPF_FOURCC) == 0) return false;
    return (String)bytes[DDS_FOUR_CC_OFFSET:FOUR_CC_BYTES] == code;
}

fn PixelFormat? dx10_format(char[] bytes) @local {
    if (read_u32(bytes, DX10_DIMENSION_OFFSET) != D3D10_RESOURCE_DIMENSION_TEXTURE2D) return c3d::UNSUPPORTED~;
    if (read_u32(bytes, DX10_ARRAY_SIZE_OFFSET) != 1) return c3d::UNSUPPORTED~;
    if (read_u32(bytes, DX10_MISC_FLAG_OFFSET) & D3D10_RESOURCE_MISC_TEXTURECUBE) return c3d::UNSUPPORTED~;
    uint alpha_mode = read_u32(bytes, DX10_MISC_FLAGS2_OFFSET) & DDS_ALPHA_MODE_MASK;
    if (alpha_mode == DDS_ALPHA_MODE_PREMULTIPLIED) return c3d::UNSUPPORTED~;

    switch (read_u32(bytes, DX10_FORMAT_OFFSET)) {
        case DXGI_FORMAT_R8G8B8A8_UNORM: return RGBA8_UNORM;
        case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB: return RGBA8_SRGB;
        case DXGI_FORMAT_R16G16B16A16_FLOAT: return RGBA16_FLOAT;
        case DXGI_FORMAT_R32G32B32A32_FLOAT: return RGBA32_FLOAT;
        case DXGI_FORMAT_R16_UINT: return R16_UINT;
        case DXGI_FORMAT_BC1_UNORM: return BC1_RGBA_UNORM;
        case DXGI_FORMAT_BC1_UNORM_SRGB: return BC1_RGBA_SRGB;
        case DXGI_FORMAT_BC3_UNORM: return BC3_UNORM;
        case DXGI_FORMAT_BC3_UNORM_SRGB: return BC3_SRGB;
        case DXGI_FORMAT_BC4_UNORM: return BC4_UNORM;
        case DXGI_FORMAT_BC5_UNORM: return BC5_UNORM;
        case DXGI_FORMAT_BC6H_UF16: return BC6H_UFLOAT;
        case DXGI_FORMAT_BC7_UNORM: return BC7_UNORM;
        case DXGI_FORMAT_BC7_UNORM_SRGB: return BC7_SRGB;
        default: return c3d::UNSUPPORTED~;
    }
}

fn PixelFormat? legacy_format(char[] bytes) @local {
    if (four_cc_is(bytes, "DXT1")) return BC1_RGBA_UNORM;
    if (four_cc_is(bytes, "DXT5")) return BC3_UNORM;
    if (four_cc_is(bytes, "BC4U") || four_cc_is(bytes, "ATI1")) return BC4_UNORM;
    if (four_cc_is(bytes, "BC5U") || four_cc_is(bytes, "ATI2")) return BC5_UNORM;

    uint flags = read_u32(bytes, DDS_PIXEL_FORMAT_FLAGS_OFFSET);
    if (flags & DDPF_FOURCC) {
        switch (read_u32(bytes, DDS_FOUR_CC_OFFSET)) {
            case D3DFMT_A16B16G16R16F: return RGBA16_FLOAT;
            case D3DFMT_A32B32G32R32F: return RGBA32_FLOAT;
            default: return c3d::UNSUPPORTED~;
        }
    }
    if ((flags & DDPF_RGB) != 0 && has_rgba8_masks(bytes)) return RGBA8_UNORM;
    return c3d::UNSUPPORTED~;
}

fn bool has_rgba8_masks(char[] bytes) @local {
    return read_u32(bytes, DDS_BIT_COUNT_OFFSET) == RGBA8_BIT_COUNT
        && read_u32(bytes, DDS_RED_MASK_OFFSET) == RED_BYTE_MASK
        && read_u32(bytes, DDS_GREEN_MASK_OFFSET) == GREEN_BYTE_MASK
        && read_u32(bytes, DDS_BLUE_MASK_OFFSET) == BLUE_BYTE_MASK
        && read_u32(bytes, DDS_ALPHA_MASK_OFFSET) == ALPHA_BYTE_MASK;
}
